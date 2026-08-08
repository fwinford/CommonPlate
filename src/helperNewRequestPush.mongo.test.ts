import type { Request, Response } from "express";
import mongoose from "mongoose";
import {
  afterAll,
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";
import {
  Installation,
  PushDelivery,
  Request as MealRequest,
  SendLog,
  Subscriber,
  type IRequest,
} from "../models/db.js";
import type { ApnsConfiguration } from "./apnsConfig.js";
import type { ApnsConnection, ApnsOutcome, ApnsSubmission } from "./apnsClient.js";
import {
  HELPER_NEW_REQUEST_PURPOSE,
  dispatchHelperNewRequestPush,
} from "./helperNewRequestPush.js";
import { digestInstallationCredential } from "./installationCredential.js";
import { createInstallationPushHandler } from "./installationPushRoute.js";

const mongoUri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = mongoUri ? describe : describe.skip;

const configuration: ApnsConfiguration = {
  teamId: "ABCDE12345",
  keyId: "KEY1234567",
  bundleId: "org.commonplatenyu.CommonPlateios",
  authKeyPem: "unused: the provider token is injected",
};

const accepted: ApnsOutcome = {
  classification: "accepted",
  status: 200,
  reason: "Accepted",
  apnsId: "apns-accepted",
};
const unregistered: ApnsOutcome = {
  classification: "token-rejected",
  status: 410,
  reason: "Unregistered",
};

function credential(byte: number): string {
  return Buffer.alloc(32, byte).toString("base64url");
}

function apnsToken(byte: number): string {
  return Buffer.alloc(32, byte).toString("hex");
}

function routeContext(body: unknown) {
  const req = { body } as unknown as Request;
  const res = {} as Response;
  let bodyValue: unknown;
  res.status = ((): Response => res) as never;
  res.json = ((value: unknown) => {
    bodyValue = value;
    return res;
  }) as never;
  return {
    req,
    res,
    get body() {
      return bodyValue;
    },
  };
}

async function createOpenRequest(
  overrides: Record<string, unknown> = {}
): Promise<IRequest> {
  const expiresAt = new Date(Date.now() + 5 * 60 * 60 * 1000);
  return MealRequest.create({
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName: "Requester Private Name",
    email: "requester@nyu.edu",
    pickupWindowText: "ASAP (within the next 5 hours)",
    status: "open",
    expiresAt,
    deleteAt: expiresAt,
    ...overrides,
  });
}

async function createInstallation(
  byte: number,
  overrides: Record<string, unknown> = {}
) {
  return Installation.create({
    installationCredentialDigest: digestInstallationCredential(credential(byte)),
    pushEnabled: true,
    apnsToken: apnsToken(byte),
    apnsEnvironment: "development",
    tokenUpdatedAt: new Date(),
    ...overrides,
  });
}

interface RecordingConnections {
  openConnection: (origin: string) => ApnsConnection;
  submissions: ApnsSubmission[];
}

function connections(
  respond: (submission: ApnsSubmission) => ApnsOutcome | Promise<ApnsOutcome> = () =>
    accepted
): RecordingConnections {
  const submissions: ApnsSubmission[] = [];
  return {
    submissions,
    openConnection: () => ({
      async submit(submission) {
        submissions.push(submission);
        return respond(submission);
      },
      close() {},
    }),
  };
}

function dispatch(
  request: IRequest,
  overrides: Record<string, unknown> = {}
) {
  return dispatchHelperNewRequestPush(request, {
    isPaused: () => false,
    readConfiguration: () => configuration,
    providerToken: () => "provider-jwt",
    openConnection: () => ({
      async submit() {
        return accepted;
      },
      close() {},
    }),
    ...overrides,
  });
}

describeMongo("helper new-request push against real MongoDB", () => {
  beforeAll(async () => {
    // Its own database: Mongo test files run concurrently and several suites
    // clear their collections between cases, so a shared database would let
    // one suite delete another's fixtures mid-test.
    await mongoose.connect(mongoUri!, {
      dbName: "commonplate_helper_push_test",
    });
    await Installation.syncIndexes();
    await PushDelivery.syncIndexes();
    await MealRequest.syncIndexes();
    await SendLog.syncIndexes();
  });

  beforeEach(() => {
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});
  });

  afterEach(async () => {
    vi.restoreAllMocks();
    await Promise.all([
      Installation.deleteMany({}),
      PushDelivery.deleteMany({}),
      MealRequest.deleteMany({}),
      SendLog.deleteMany({}),
      Subscriber.deleteMany({}),
    ]);
  });

  afterAll(async () => {
    await mongoose.disconnect();
  });

  describe("eligibility selection", () => {
    it("selects exactly the push-enabled, tokened, non-invalidated installations", async () => {
      const eligible = await createInstallation(1);
      await createInstallation(2, { pushEnabled: false });
      await createInstallation(3, { invalidatedAt: new Date(), pushEnabled: false });
      await Installation.create({
        installationCredentialDigest: digestInstallationCredential(credential(4)),
        pushEnabled: true,
      });
      const request = await createOpenRequest();
      const provider = connections();

      const summary = await dispatch(request, {
        openConnection: provider.openConnection,
      });

      expect(summary.eligible).toBe(1);
      expect(provider.submissions).toHaveLength(1);
      // The token is `select: false` on the schema; it must still arrive.
      expect(provider.submissions[0].deviceToken).toBe(apnsToken(1));
      expect(String(eligible._id)).not.toBe("");
    });

    it("skips a request claimed between creation and dispatch", async () => {
      const request = await createOpenRequest();
      await createInstallation(1);
      await MealRequest.updateOne(
        { _id: request._id },
        {
          $set: {
            status: "claimed",
            claimedAt: new Date(),
            claimExpiresAt: new Date(Date.now() + 30 * 60 * 1000),
          },
        }
      );
      const provider = connections();

      const summary = await dispatch(request, {
        openConnection: provider.openConnection,
      });

      expect(summary.stop).toBe("unavailable");
      expect(provider.submissions).toHaveLength(0);
      expect(await PushDelivery.countDocuments({})).toBe(0);
    });
  });

  describe("deduplication", () => {
    it("rejects a second claim on the same identity triple", async () => {
      const request = await createOpenRequest();
      const installation = await createInstallation(1);
      await PushDelivery.create({
        requestId: request._id,
        installationId: installation._id,
        purpose: HELPER_NEW_REQUEST_PURPOSE,
        status: "claimed",
        deleteAt: new Date(Date.now() + 60_000),
      });

      await expect(
        PushDelivery.create({
          requestId: request._id,
          installationId: installation._id,
          purpose: HELPER_NEW_REQUEST_PURPOSE,
          status: "failed",
          deleteAt: new Date(Date.now() + 60_000),
        })
      ).rejects.toMatchObject({ code: 11000 });
    });

    it("submits once per installation under a concurrent double dispatch", async () => {
      const request = await createOpenRequest();
      await createInstallation(1);
      await createInstallation(2);
      const provider = connections(async () => {
        await new Promise((resolve) => setTimeout(resolve, 5));
        return accepted;
      });

      const [first, second] = await Promise.all([
        dispatch(request, { openConnection: provider.openConnection }),
        dispatch(request, { openConnection: provider.openConnection }),
      ]);

      expect(provider.submissions).toHaveLength(2);
      expect(first.claimed + second.claimed).toBe(2);
      expect(first.duplicate + second.duplicate).toBe(2);
      expect(await PushDelivery.countDocuments({})).toBe(2);
    });

    it("blocks a second intentional submission after a terminal failure", async () => {
      // Unlike SendLog, a row in any state is terminal: V1 has no retry path,
      // so re-submitting would be a duplicate rather than a recovery.
      const request = await createOpenRequest();
      await createInstallation(1);
      const provider = connections(() => ({
        classification: "transient",
        status: 503,
        reason: "ServiceUnavailable",
      }));

      const first = await dispatch(request, {
        openConnection: provider.openConnection,
      });
      const second = await dispatch(request, {
        openConnection: provider.openConnection,
      });

      expect(first.failed).toBe(1);
      expect(second.duplicate).toBe(1);
      expect(provider.submissions).toHaveLength(1);
      const rows = await PushDelivery.find({}).lean();
      expect(rows).toHaveLength(1);
      expect(rows[0].status).toBe("failed");
    });

    it("stores no token, credential, or request content, and carries a TTL deleteAt", async () => {
      const request = await createOpenRequest();
      await createInstallation(1);

      await dispatch(request, { openConnection: connections().openConnection });

      const [row] = await PushDelivery.find({}).lean();
      expect(row.status).toBe("accepted");
      expect(row.apnsId).toBe("apns-accepted");
      expect(row.deleteAt.getTime()).toBe(
        new Date(request.expiresAt!).getTime() + 24 * 60 * 60 * 1000
      );
      const serialized = JSON.stringify(row);
      expect(serialized).not.toContain(apnsToken(1));
      expect(serialized).not.toContain(credential(1));
      expect(serialized).not.toContain("Campus Market");
      expect(serialized).not.toContain("requester@nyu.edu");
      expect(serialized).not.toContain("Requester Private Name");
    });

    it("carries the accepted unique and TTL indexes", async () => {
      const indexes = await PushDelivery.collection.indexes();
      const unique = indexes.find(
        (index) => index.name === "push_delivery_identity_unique"
      );
      const ttl = indexes.find(
        (index) => index.name === "push_delivery_deleteAt_ttl"
      );

      expect(unique?.key).toEqual({
        requestId: 1,
        installationId: 1,
        purpose: 1,
      });
      expect(unique?.unique).toBe(true);
      expect(ttl?.expireAfterSeconds).toBe(0);
    });
  });

  describe("exact-token invalidation", () => {
    it("retires only the installation whose exact token APNs rejected", async () => {
      const request = await createOpenRequest();
      const rejected = await createInstallation(1);
      const untouched = await createInstallation(2);
      const provider = connections((submission) =>
        submission.deviceToken === apnsToken(1) ? unregistered : accepted
      );

      const summary = await dispatch(request, {
        openConnection: provider.openConnection,
      });

      expect(summary.retired).toBe(1);
      const retired = await Installation.findById(rejected._id).lean();
      const other = await Installation.findById(untouched._id).lean();
      expect(retired?.pushEnabled).toBe(false);
      expect(retired?.invalidatedAt).toBeInstanceOf(Date);
      expect(other?.pushEnabled).toBe(true);
      expect(other?.invalidatedAt).toBeFalsy();
    });

    it("cannot retire a replacement token with a stale rejection", async () => {
      const request = await createOpenRequest();
      const installation = await createInstallation(1);
      const provider = connections(async () => {
        // The app re-registers a new token while this submission is in flight.
        await Installation.updateOne(
          { _id: installation._id },
          {
            $set: {
              apnsToken: apnsToken(9),
              tokenUpdatedAt: new Date(),
              updatedAt: new Date(),
            },
          }
        );
        return unregistered;
      });

      const summary = await dispatch(request, {
        openConnection: provider.openConnection,
      });

      expect(summary.rejected).toBe(1);
      // Matching zero documents is the expected outcome for a stale response.
      expect(summary.retired).toBe(0);
      const stored = await Installation.findById(installation._id)
        .select("+apnsToken")
        .lean();
      expect(stored?.pushEnabled).toBe(true);
      expect(stored?.invalidatedAt).toBeFalsy();
      expect(stored?.apnsToken).toBe(apnsToken(9));
    });

    it("does not retire an installation on a non-token configuration failure", async () => {
      const request = await createOpenRequest();
      const installation = await createInstallation(1);
      const provider = connections(() => ({
        classification: "configuration",
        status: 400,
        reason: "DeviceTokenNotForTopic",
      }));

      const summary = await dispatch(request, {
        openConnection: provider.openConnection,
      });

      expect(summary.failed).toBe(1);
      expect(summary.retired).toBe(0);
      const stored = await Installation.findById(installation._id).lean();
      expect(stored?.pushEnabled).toBe(true);
      expect(stored?.invalidatedAt).toBeFalsy();
    });

    it("restores a retired installation through an ordinary push re-synchronization", async () => {
      const request = await createOpenRequest();
      const installation = await createInstallation(1);
      await dispatch(request, {
        openConnection: connections(() => unregistered).openConnection,
      });

      const context = routeContext({
        installationCredential: credential(1),
        enabled: true,
        apnsToken: apnsToken(1),
        environment: "development",
      });
      await createInstallationPushHandler()(context.req, context.res);

      expect(context.body).toEqual({ push: { enabled: true } });
      const restored = await Installation.findById(installation._id).lean();
      expect(restored?.pushEnabled).toBe(true);
      expect(restored?.invalidatedAt).toBeNull();
    });
  });

  describe("isolation from the request and the email channel", () => {
    it("leaves the created request, Subscriber, and SendLog untouched by every outcome", async () => {
      const request = await createOpenRequest();
      await createInstallation(1);
      await createInstallation(2);
      await createInstallation(3);
      const subscriber = await Subscriber.create({
        email: "helper@nyu.edu",
        status: "confirmed",
      });
      const before = await MealRequest.findById(request._id).lean();
      let call = 0;
      const provider = connections(() => {
        call += 1;
        if (call === 1) return unregistered;
        if (call === 2) {
          return { classification: "transient", status: 503, reason: "ServiceUnavailable" };
        }
        return accepted;
      });

      await dispatch(request, { openConnection: provider.openConnection });

      const after = await MealRequest.findById(request._id).lean();
      expect(after).toEqual(before);
      expect(await SendLog.countDocuments({})).toBe(0);
      const storedSubscriber = (await Subscriber.findById(
        subscriber._id
      ).lean()) as unknown as {
        status: string;
        dailyCount: number;
        lastSentAt: Date | null;
      } | null;
      expect(storedSubscriber?.status).toBe("confirmed");
      expect(storedSubscriber?.dailyCount).toBe(0);
      expect(storedSubscriber?.lastSentAt).toBeNull();
    });

    it("writes no delivery record while public actions are paused", async () => {
      const request = await createOpenRequest();
      await createInstallation(1);
      const provider = connections();

      const summary = await dispatch(request, {
        isPaused: () => true,
        openConnection: provider.openConnection,
      });

      expect(summary.stop).toBe("paused");
      expect(await PushDelivery.countDocuments({})).toBe(0);
      expect(provider.submissions).toHaveLength(0);
    });
  });
});
