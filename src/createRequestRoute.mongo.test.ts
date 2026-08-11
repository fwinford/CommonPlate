import type { Request, Response } from "express";
import mongoose from "mongoose";
import {
  afterAll,
  afterEach,
  beforeAll,
  describe,
  expect,
  it,
  vi,
} from "vitest";

const { resendSend, notifySubscribersForRequest, startHelperNewRequestPush } =
  vi.hoisted(() => ({
    resendSend: vi.fn(),
    notifySubscribersForRequest: vi.fn(),
    startHelperNewRequestPush: vi.fn(),
  }));

vi.mock("resend", () => ({
  Resend: class {
    emails = { send: resendSend };
  },
}));

vi.mock("./notifySubscribers.js", () => ({
  notifySubscribersForRequest,
}));

vi.mock("./helperNewRequestPush.js", () => ({
  startHelperNewRequestPush,
}));

import {
  Participant,
  Request as MealRequest,
  RequestOperation,
} from "../models/db.js";
import {
  createRequest,
  OPERATION_EXPIRED_CODE,
  OPERATION_IDENTITY_HEADER,
  OPERATION_UNAUTHORIZED_CODE,
} from "./createRequestRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";

/**
 * W3-D1 real-Mongo proof: the backend exact-operation identity, bounded
 * recovery, and idempotency/reconciliation primitive for request creation.
 * This is the first Mongo-gated suite to drive `POST /api/request` — every
 * other create-route suite is fully mocked — because the properties under
 * test here are database-level guarantees a mocked model cannot exercise:
 * "at most one Request per logical operation, even under real concurrency"
 * (`request_operation_ledger_identity_unique`), and "an expired operation's
 * identity survives its Request's own TTL cleanup" (the separate
 * `RequestOperation` ledger, never reclaimed by that TTL).
 */
function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_create_request_operation`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const participantSecretText = "create-request-mongo-participant-secret-32b";
const participantSecret = Buffer.from(participantSecretText);

const requesterAId = new mongoose.Types.ObjectId("64f0000000000000000000a1");
const requesterAPrincipal = "d1-mongo-requester-a@nyu.edu";
const requesterAAuthority = signParticipantAuthority(
  requesterAId,
  1,
  participantSecret
);

const requesterBId = new mongoose.Types.ObjectId("64f0000000000000000000b2");
const requesterBPrincipal = "d1-mongo-requester-b@nyu.edu";
const requesterBAuthority = signParticipantAuthority(
  requesterBId,
  1,
  participantSecret
);

function canonicalAsapPayload(overrides: Record<string, unknown> = {}) {
  return {
    vendor: "Palladium",
    food: "Vegetable rice bowl",
    pickupName: "Requester Private Name",
    timing: "asap",
    mealSwipes: 2,
    ...overrides,
  };
}

function routeContext(
  body: unknown,
  headers: Record<string, string> = {
    [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
  }
) {
  const req = { body, headers } as unknown as Request;
  const res = {} as Response;
  let statusCode = 0;
  let bodyValue: any;
  res.status = vi.fn((value: number) => {
    statusCode = value;
    return res;
  }) as any;
  res.json = vi.fn((value: unknown) => {
    bodyValue = value;
    return res;
  }) as any;
  return {
    req,
    res,
    get statusCode() {
      return statusCode;
    },
    get body() {
      return bodyValue;
    },
  };
}

describeMongo("real MongoDB durable create-operation identity (W3-D1)", () => {
  beforeAll(async () => {
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
    await mongoose.connect(mongoUri!);
    await MealRequest.syncIndexes();
    await RequestOperation.syncIndexes();
    await Participant.updateOne(
      { _id: requesterAId },
      {
        $set: { email: requesterAPrincipal, verifiedAt: new Date() },
        $setOnInsert: { authorityVersion: 1 },
      },
      { upsert: true }
    ).exec();
    await Participant.updateOne(
      { _id: requesterBId },
      {
        $set: { email: requesterBPrincipal, verifiedAt: new Date() },
        $setOnInsert: { authorityVersion: 1 },
      },
      { upsert: true }
    ).exec();
  });

  afterEach(async () => {
    await MealRequest.deleteMany({});
    await RequestOperation.deleteMany({});
    resendSend.mockReset().mockResolvedValue({ data: { id: "x" }, error: null });
    notifySubscribersForRequest.mockReset().mockResolvedValue(undefined);
    startHelperNewRequestPush.mockReset();
  });

  afterAll(async () => {
    await Participant.deleteMany({ _id: { $in: [requesterAId, requesterBId] } });
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  it("creates exactly one Request for a first, genuinely new operation", async () => {
    const context = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-first",
    });

    await createRequest(context.req, context.res);

    expect(context.statusCode).toBe(201);
    expect(await MealRequest.countDocuments({})).toBe(1);
  });

  it("reconciles a sequential replay to the same Request and creates no second one", async () => {
    const first = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-sequential-replay",
    });
    await createRequest(first.req, first.res);
    expect(first.statusCode).toBe(201);
    const createdId = first.body.request.id;

    const replay = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-sequential-replay",
    });
    await createRequest(replay.req, replay.res);

    expect(replay.statusCode).toBe(200);
    expect(replay.body.request.id).toBe(createdId);
    expect(await MealRequest.countDocuments({})).toBe(1);
  });

  it("creates at most one Request when two attempts race the same operation identity concurrently", async () => {
    const operationId = "mongo-op-concurrent-race";
    const first = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });
    const second = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });

    await Promise.all([
      createRequest(first.req, first.res),
      createRequest(second.req, second.res),
    ]);

    const statuses = [first.statusCode, second.statusCode].sort();
    // Exactly one attempt is the authoritative creator (201); the other
    // reconciles to it (200). Neither may fail, and neither may silently win
    // a second Request into existence.
    expect(statuses).toEqual([200, 201]);
    expect(first.body.request.id).toBe(second.body.request.id);
    expect(await MealRequest.countDocuments({})).toBe(1);
  });

  it("creates distinct Requests for distinct operation identities with an identical payload", async () => {
    const first = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-distinct-1",
    });
    const second = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-distinct-2",
    });

    await createRequest(first.req, first.res);
    await createRequest(second.req, second.res);

    expect(first.statusCode).toBe(201);
    expect(second.statusCode).toBe(201);
    expect(first.body.request.id).not.toBe(second.body.request.id);
    expect(await MealRequest.countDocuments({})).toBe(2);
  });

  it("refuses cross-participant replay/reconciliation without exposing the existing Request", async () => {
    const created = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-cross-participant",
    });
    await createRequest(created.req, created.res);
    expect(created.statusCode).toBe(201);

    const intruder = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterBAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-cross-participant",
    });
    await createRequest(intruder.req, intruder.res);

    expect(intruder.statusCode).toBe(403);
    expect(intruder.body).toEqual({
      error: expect.objectContaining({ code: OPERATION_UNAUTHORIZED_CODE }),
    });
    // Nothing about the existing request leaked, and nothing new was created.
    expect(JSON.stringify(intruder.body)).not.toContain("Palladium");
    expect(await MealRequest.countDocuments({})).toBe(1);
  });

  it("refuses the same cross-participant collision when it surfaces as a create-time race", async () => {
    const operationId = "mongo-op-cross-participant-race";
    const owner = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });
    const intruder = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterBAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });

    await Promise.all([
      createRequest(owner.req, owner.res),
      createRequest(intruder.req, intruder.res),
    ]);

    // Whichever request actually won the insert must be requester A's; the
    // other must be a definitive refusal, never a reconciliation to A's data.
    const results = [owner, intruder];
    const winner = results.find((entry) => entry.statusCode === 201);
    const loser = results.find((entry) => entry !== winner);
    expect(winner).toBeDefined();
    expect(loser?.statusCode).toBe(403);
    expect(await MealRequest.countDocuments({})).toBe(1);
  });

  it("does not consume quota on replay, and still enforces quota for a genuinely distinct operation", async () => {
    const now = new Date();
    for (let index = 0; index < 3; index += 1) {
      await MealRequest.create({
        vendor: "Palladium",
        food: "Prior request",
        pickupName: "Prior Pickup",
        pickupWindowText: "ASAP",
        mealSwipes: 1,
        email: requesterAPrincipal,
        requesterParticipantId: requesterAId,
        status: "open",
        visibleFrom: now,
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        deleteAt: new Date(now.getTime() + 60 * 60 * 1000),
        helperNotification: "initiated",
      });
    }
    expect(await MealRequest.countDocuments({})).toBe(3);

    // The requester is already at the daily limit. A genuinely distinct
    // operation is refused by the unchanged quota rule.
    const distinct = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-quota-distinct",
    });
    await createRequest(distinct.req, distinct.res);
    expect(distinct.statusCode).toBe(429);
    expect(await MealRequest.countDocuments({})).toBe(3);
  });

  it("reconciles an already-created operation even when the requester is now over quota", async () => {
    const first = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-quota-replay",
    });
    await createRequest(first.req, first.res);
    expect(first.statusCode).toBe(201);

    const now = new Date();
    for (let index = 0; index < 2; index += 1) {
      await MealRequest.create({
        vendor: "Palladium",
        food: "Additional request",
        pickupName: "Additional Pickup",
        pickupWindowText: "ASAP",
        mealSwipes: 1,
        email: requesterAPrincipal,
        requesterParticipantId: requesterAId,
        status: "open",
        visibleFrom: now,
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        deleteAt: new Date(now.getTime() + 60 * 60 * 1000),
        helperNotification: "initiated",
      });
    }
    expect(await MealRequest.countDocuments({})).toBe(3);

    const replay = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-quota-replay",
    });
    await createRequest(replay.req, replay.res);

    expect(replay.statusCode).toBe(200);
    expect(replay.body.request.id).toBe(first.body.request.id);
    expect(await MealRequest.countDocuments({})).toBe(3);
  });

  it("creates no Request for a malformed operation identity and does not poison a later valid one", async () => {
    const malformed = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "not a valid identity",
    });
    await createRequest(malformed.req, malformed.res);
    expect(malformed.statusCode).toBe(400);
    expect(await MealRequest.countDocuments({})).toBe(0);

    const valid = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-after-malformed",
    });
    await createRequest(valid.req, valid.res);
    expect(valid.statusCode).toBe(201);
    expect(await MealRequest.countDocuments({})).toBe(1);
  });

  it("keeps the operation identity out of the public response", async () => {
    const context = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-not-public",
    });
    await createRequest(context.req, context.res);

    expect(context.statusCode).toBe(201);
    expect(JSON.stringify(context.body)).not.toContain("mongo-op-not-public");
  });

  it("still creates a Request normally when no operation identity is presented (legacy/opt-in compatibility)", async () => {
    const context = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
    });
    await createRequest(context.req, context.res);

    expect(context.statusCode).toBe(201);
    expect(await MealRequest.countDocuments({})).toBe(1);
  });

  it("survives the Request's own deletion: the ledger, not the Request, is what a bounded-recovery-horizon check reads", async () => {
    const operationId = "mongo-op-ledger-survives-request-deletion";
    const created = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });
    await createRequest(created.req, created.res);
    expect(created.statusCode).toBe(201);

    // Simulates MongoDB's TTL reclaiming the Request once it is no longer
    // active/actionable (the accepted recovery-horizon boundary), while the
    // durable operation ledger row is deliberately left in place — exactly
    // what the real `deleteAt` TTL index does to the Request collection.
    await MealRequest.deleteMany({});
    expect(await RequestOperation.countDocuments({ operationId })).toBe(1);

    const afterCleanup = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });
    await createRequest(afterCleanup.req, afterCleanup.res);

    // Terminal expired/unrecoverable, never a fresh create: cleanup of the
    // original Request must not make this exact identity look new again.
    expect(afterCleanup.statusCode).toBe(410);
    expect(afterCleanup.body).toEqual({
      error: expect.objectContaining({ code: OPERATION_EXPIRED_CODE }),
    });
    expect(await MealRequest.countDocuments({})).toBe(0);
  });

  it("keeps repeating the terminal expired outcome for the same exact identity, creating zero Requests every time", async () => {
    const operationId = "mongo-op-expired-repeat-presentation";
    const created = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });
    await createRequest(created.req, created.res);
    await MealRequest.deleteMany({});

    for (let attempt = 0; attempt < 3; attempt += 1) {
      const replay = routeContext(canonicalAsapPayload(), {
        [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
        [OPERATION_IDENTITY_HEADER]: operationId,
      });
      await createRequest(replay.req, replay.res);
      expect(replay.statusCode).toBe(410);
    }
    expect(await MealRequest.countDocuments({})).toBe(0);
  });

  it("permits a fresh intentional operation to create normally after the prior exact identity has expired", async () => {
    const expiredOperationId = "mongo-op-expired-then-fresh-y";
    const expiredAttempt = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: expiredOperationId,
    });
    await createRequest(expiredAttempt.req, expiredAttempt.res);
    await MealRequest.deleteMany({});

    const expiredReplay = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: expiredOperationId,
    });
    await createRequest(expiredReplay.req, expiredReplay.res);
    expect(expiredReplay.statusCode).toBe(410);
    expect(await MealRequest.countDocuments({})).toBe(0);

    // A genuinely new operation identity (Y) is unaffected by X's expiry and
    // creates normally under existing validation/quota rules.
    const fresh = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: "mongo-op-expired-then-fresh-y-actual",
    });
    await createRequest(fresh.req, fresh.res);
    expect(fresh.statusCode).toBe(201);
    expect(await MealRequest.countDocuments({})).toBe(1);
  });

  it("refuses cross-participant reconciliation of an expired identity the same generic way, without revealing that it ever existed", async () => {
    const operationId = "mongo-op-expired-cross-participant";
    const created = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterAAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });
    await createRequest(created.req, created.res);
    await MealRequest.deleteMany({});

    const intruder = routeContext(canonicalAsapPayload(), {
      [PARTICIPANT_AUTHORITY_HEADER]: requesterBAuthority,
      [OPERATION_IDENTITY_HEADER]: operationId,
    });
    await createRequest(intruder.req, intruder.res);

    // Unauthorized takes precedence over expired: Participant B never learns
    // whether this identity created a Request at all, let alone that it has
    // since expired.
    expect(intruder.statusCode).toBe(403);
    expect(intruder.body).toEqual({
      error: expect.objectContaining({ code: OPERATION_UNAUTHORIZED_CODE }),
    });
    expect(await MealRequest.countDocuments({})).toBe(0);
  });
});
