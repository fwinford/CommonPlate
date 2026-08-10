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
  Fulfillment,
  Participant,
  Request as MealRequest,
} from "../models/db.js";
import {
  digestClaimToken,
  generateClaimToken,
  readClaimTokenHmacSecret,
} from "./claimToken.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";

const sendFulfillmentEmail = vi.hoisted(() => vi.fn());
vi.mock("./emailHelpers.js", () => ({ sendFulfillmentEmail }));

import { releaseClaim } from "./claimRoute.js";
import {
  fulfillRequest,
  PLACED_RETENTION_MS,
} from "./fulfillmentRoute.js";
import { buildEffectiveAvailabilityFilter } from "./requestAvailability.js";
import { buildPublicRequestDetailResponse } from "./requestListResponse.js";
import { getStats } from "./statsRoute.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_fulfillment`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

function routeContext(
  id: string,
  body: unknown,
  headers: Record<string, string> = {}
) {
  const req = { params: { id }, body, headers } as unknown as Request;
  const res = {} as Response;
  let statusCode = 200;
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

/**
 * The verified helper every reservation below is bound to (W3-I1). Fulfillment
 * derives the helper address from this binding, so it is the only place the
 * placed request's `fulfillerEmail` and the requester email's Reply-To can come
 * from — nothing in the payload supplies one.
 */
const helperParticipantId = new mongoose.Types.ObjectId(
  "64d0000000000000000000c3"
);
const boundHelperEmail = "fulfillment-mongo-helper@nyu.edu";
const participantSecret = Buffer.from(
  "real-mongo-test-participant-secret-material"
);
/**
 * A real signed credential for the bound helper (W3-H1 continuation), used in
 * place of the raw claim token once a relaunch has discarded it.
 */
const participantAuthority = signParticipantAuthority(
  helperParticipantId,
  1,
  participantSecret
);
const continuationHeaders = {
  [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
};

function fulfillmentBody(rawToken: string) {
  return {
    claimToken: rawToken,
    fulfillment: {
      orderNumber: "70154321",
      eta: "15 minutes",
      contactMessage: "Your meal is ready",
    },
  };
}

/** The W3-H1 continuation wire shape: no raw token, participant header instead. */
function continuationFulfillmentBody() {
  return {
    fulfillment: {
      orderNumber: "70154321",
      eta: "15 minutes",
      contactMessage: "Your meal is ready",
    },
  };
}

async function createClaimedRequest(
  overrides: Record<string, unknown> = {}
) {
  const rawToken = generateClaimToken();
  const now = new Date();
  const expiresAt = new Date(now.getTime() + 60 * 60 * 1000);
  const request = await MealRequest.create({
    vendor: "Transaction Cafe",
    food: "Rice bowl",
    pickupName: "Requester Pickup",
    pickupWindowText: "ASAP",
    email: "requester@example.edu",
    status: "claimed",
    expiresAt,
    deleteAt: expiresAt,
    claimedAt: now,
    claimExpiresAt: new Date(now.getTime() + 15 * 60 * 1000),
    claimExtendedAt: null,
    claimTokenDigest: digestClaimToken(
      rawToken,
      readClaimTokenHmacSecret()
    ),
    helperParticipantId,
    ...overrides,
  });
  return { request, rawToken };
}

describeMongo("transactional fulfillment against a real replica set", () => {
  beforeAll(async () => {
    vi.stubEnv(
      "CLAIM_TOKEN_HMAC_SECRET",
      "real-mongo-test-secret-material-32-bytes"
    );
    vi.stubEnv(
      PARTICIPANT_SIGNING_SECRET_ENV,
      participantSecret.toString("utf8")
    );
    await mongoose.connect(mongoUri!);
    await MealRequest.syncIndexes();
    await Fulfillment.syncIndexes();
    await Participant.createIndexes();
    await Participant.updateOne(
      { _id: helperParticipantId },
      {
        $set: { email: boundHelperEmail, verifiedAt: new Date() },
        $setOnInsert: { authorityVersion: 1 },
      },
      { upsert: true }
    ).exec();
  });

  beforeEach(() => {
    sendFulfillmentEmail.mockReset();
    sendFulfillmentEmail.mockResolvedValue(undefined);
  });

  afterEach(async () => {
    await Promise.all([
      MealRequest.deleteMany({}),
      Fulfillment.deleteMany({}),
    ]);
  });

  afterAll(async () => {
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  it("runs against a transaction-capable replica set", async () => {
    const hello = await mongoose.connection.db!.admin().command({ hello: 1 });
    expect(hello.setName).toBe("commonplateTestReplica");
    expect(hello.isWritablePrimary).toBe(true);
  });

  it("lets the valid claimant place once with authoritative timestamps and private fields", async () => {
    const originalExpiresAt = new Date(Date.now() - 60 * 1000);
    const { request, rawToken } = await createClaimedRequest({
      // Fulfillment authorization deliberately ignores request.expiresAt once
      // a still-active claim exists.
      expiresAt: originalExpiresAt,
      deleteAt: new Date(Date.now() + 60 * 60 * 1000),
    });
    const before = new Date();
    const context = routeContext(
      String(request._id),
      fulfillmentBody(rawToken)
    );

    await fulfillRequest(context.req, context.res);
    const after = new Date();

    expect(context.statusCode).toBe(200);
    expect(context.body.request.status).toBe("placed");
    expect(context.body.notification).toEqual({ status: "sent" });

    const stored = await MealRequest.findById(request._id)
      .select("+claimTokenDigest")
      .lean();
    expect(stored?.status).toBe("placed");
    // `placedAt` and `deleteAt` are optional on the schema but always written
    // by the placement transaction this test just committed.
    expect(stored?.placedAt!.getTime()).toBeGreaterThanOrEqual(before.getTime());
    expect(stored?.placedAt!.getTime()).toBeLessThanOrEqual(after.getTime());
    expect(stored!.deleteAt!.getTime() - stored!.placedAt!.getTime()).toBe(
      PLACED_RETENTION_MS
    );
    expect(stored?.expiresAt).toEqual(originalExpiresAt);
    expect(stored?.orderNumber).toBe("70154321");
    expect(stored?.etaText).toBe("15 minutes");
    expect(stored?.fulfillerEmail).toBe(boundHelperEmail);
    expect(stored?.contactMessage).toBe("Your meal is ready");
    expect(stored?.notificationStatus).toBe("sent");
    expect(stored?.notificationAttemptedAt).toBeInstanceOf(Date);
    expect(stored).not.toHaveProperty("claimedAt");
    expect(stored).not.toHaveProperty("claimExpiresAt");
    expect(stored).not.toHaveProperty("claimExtendedAt");
    expect(stored).not.toHaveProperty("claimTokenDigest");

    const ledger = await Fulfillment.findOne({ requestId: request._id }).lean();
    expect(ledger).toMatchObject({
      orderNumber: "70154321",
      etaText: "15 minutes",
    });
    expect(ledger?.placedAt).toEqual(stored?.placedAt);
    expect(await Fulfillment.countDocuments()).toBe(1);

    expect(sendFulfillmentEmail).toHaveBeenCalledOnce();
    expect(sendFulfillmentEmail).toHaveBeenCalledWith(
      expect.objectContaining({ _id: request._id, status: "placed" }),
      "70154321",
      "15 minutes",
      "Your meal is ready",
      boundHelperEmail
    );

    const active = await MealRequest.find(
      buildEffectiveAvailabilityFilter(new Date())
    ).lean();
    expect(active).toHaveLength(0);

    const publicDetail = buildPublicRequestDetailResponse(
      stored as any,
      new Date()
    );
    expect(publicDetail.request.status).toBe("placed");
    expect(JSON.stringify(publicDetail)).not.toMatch(
      /pickupName|email|orderNumber|etaText|placedAt|contactMessage|notification|claim/i
    );
  });

  // W3-I1 pre-I1 active-claim compatibility: a claim granted before
  // `helperParticipantId` existed carries no binding at all, and the accepted
  // fulfillment-safety contract requires it to remain recordable on the
  // existing valid-token authorization alone rather than becoming refusable.
  it("records placement for a claim with no helperParticipantId binding (pre-I1 compatibility)", async () => {
    const { request, rawToken } = await createClaimedRequest({
      helperParticipantId: undefined,
    });
    const preexisting = await MealRequest.findById(request._id)
      .select("+helperParticipantId")
      .lean();
    expect(preexisting).not.toHaveProperty("helperParticipantId");

    const context = routeContext(
      String(request._id),
      fulfillmentBody(rawToken)
    );

    await fulfillRequest(context.req, context.res);

    expect(context.statusCode).toBe(200);
    expect(context.body.request.status).toBe("placed");
    expect(context.body.notification).toEqual({ status: "sent" });

    const stored = await MealRequest.findById(request._id).lean();
    expect(stored?.status).toBe("placed");
    expect(stored?.orderNumber).toBe("70154321");
    // No verified helper to derive an address from, and the payload carries
    // none either, so the field is left unset rather than fabricated.
    expect(stored?.fulfillerEmail).toBeUndefined();

    expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(
      1
    );
    expect(sendFulfillmentEmail).toHaveBeenCalledWith(
      expect.objectContaining({ _id: request._id }),
      "70154321",
      "15 minutes",
      "Your meal is ready",
      undefined
    );
  });

  // The order number is a digits-only *string*, and stays one through the
  // transaction, the ledger, the response, and the student's email. A leading
  // zero is the value that proves it: any numeric conversion anywhere along
  // that path would drop it and leave the student a number that no longer
  // matches the helper's Grubhub confirmation.
  it("preserves a leading-zero order number as a string end to end", async () => {
    const { request, rawToken } = await createClaimedRequest();
    const context = routeContext(String(request._id), {
      claimToken: rawToken,
      fulfillment: {
        orderNumber: "00070154321",
        eta: "ASAP",
      },
    });

    await fulfillRequest(context.req, context.res);

    expect(context.statusCode).toBe(200);

    const stored = await MealRequest.findById(request._id).lean();
    expect(stored?.orderNumber).toBe("00070154321");
    expect(typeof stored?.orderNumber).toBe("string");

    const ledger = await Fulfillment.findOne({ requestId: request._id }).lean();
    expect(ledger?.orderNumber).toBe("00070154321");
    expect(typeof ledger?.orderNumber).toBe("string");

    expect(sendFulfillmentEmail).toHaveBeenCalledWith(
      expect.objectContaining({ _id: request._id }),
      "00070154321",
      "ASAP",
      undefined,
      boundHelperEmail
    );

    // The response is still the same two-key shape; the order number is private
    // and does not appear in the public projection at all.
    expect(Object.keys(context.body).sort()).toEqual([
      "notification",
      "request",
    ]);
    expect(JSON.stringify(context.body)).not.toContain("00070154321");
  });

  it("refuses a non-numeric order number without touching the request", async () => {
    const { request, rawToken } = await createClaimedRequest();
    const context = routeContext(String(request._id), {
      claimToken: rawToken,
      fulfillment: {
        orderNumber: "7015-4321",
        eta: "ASAP",
      },
    });

    await fulfillRequest(context.req, context.res);

    expect(context.statusCode).toBe(400);
    expect(context.body.error.code).toBe("INVALID_FULFILLMENT_PAYLOAD");

    // Placement semantics are untouched: the claim survives and can still be
    // used for a corrected submission.
    const stored = await MealRequest.findById(request._id).lean();
    expect(stored?.status).toBe("claimed");
    expect(stored?.orderNumber).toBeUndefined();
    expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(0);
    expect(sendFulfillmentEmail).not.toHaveBeenCalled();
  });

  it("leaves no contact message anywhere when the helper omits one", async () => {
    // Seeded with a message so the omission has something stale to clear
    // rather than passing on an already-empty field.
    const { request, rawToken } = await createClaimedRequest({
      contactMessage: "stale message from an earlier attempt",
    });
    const context = routeContext(String(request._id), {
      claimToken: rawToken,
      fulfillment: {
        orderNumber: "70154321",
        eta: "15 minutes",
      },
    });

    await fulfillRequest(context.req, context.res);

    expect(context.statusCode).toBe(200);
    expect(context.body.request.status).toBe("placed");
    expect(context.body.notification).toEqual({ status: "sent" });

    const stored = await MealRequest.findById(request._id).lean();
    expect(stored?.status).toBe("placed");
    expect(stored?.orderNumber).toBe("70154321");
    expect(stored).not.toHaveProperty("contactMessage");

    const ledger = await Fulfillment.findOne({ requestId: request._id }).lean();
    expect(ledger).not.toBeNull();
    expect(ledger).not.toHaveProperty("contactMessage");
    expect(ledger).not.toHaveProperty("note");

    expect(sendFulfillmentEmail).toHaveBeenCalledOnce();
    expect(sendFulfillmentEmail).toHaveBeenCalledWith(
      expect.objectContaining({ _id: request._id }),
      "70154321",
      "15 minutes",
      undefined,
      boundHelperEmail
    );
  });

  it("classifies wrong token, expired claim, already placed, and not found", async () => {
    const wrong = await createClaimedRequest();
    const expired = await createClaimedRequest({
      claimExpiresAt: new Date(Date.now() - 1),
    });
    const placed = await createClaimedRequest({ status: "placed" });
    const scenarios = [
      {
        context: routeContext(
          String(wrong.request._id),
          fulfillmentBody(generateClaimToken())
        ),
        status: 403,
        code: "INVALID_CLAIM_TOKEN",
      },
      {
        context: routeContext(
          String(expired.request._id),
          fulfillmentBody(expired.rawToken)
        ),
        status: 409,
        code: "CLAIM_EXPIRED",
      },
      {
        context: routeContext(
          String(placed.request._id),
          fulfillmentBody(placed.rawToken)
        ),
        status: 409,
        code: "REQUEST_ALREADY_PLACED",
      },
      {
        context: routeContext(
          String(new mongoose.Types.ObjectId()),
          fulfillmentBody(generateClaimToken())
        ),
        status: 404,
        code: "REQUEST_NOT_FOUND",
      },
    ];

    for (const scenario of scenarios) {
      await fulfillRequest(scenario.context.req, scenario.context.res);
      expect(scenario.context.statusCode).toBe(scenario.status);
      expect(scenario.context.body.error.code).toBe(scenario.code);
    }
    expect(await Fulfillment.countDocuments()).toBe(0);
    expect(sendFulfillmentEmail).not.toHaveBeenCalled();
  });

  it("allows one core result from two concurrent fulfillment attempts", async () => {
    const { request, rawToken } = await createClaimedRequest();
    const attempts = [
      routeContext(String(request._id), fulfillmentBody(rawToken)),
      routeContext(String(request._id), fulfillmentBody(rawToken)),
    ];

    await Promise.all(
      attempts.map((attempt) => fulfillRequest(attempt.req, attempt.res))
    );

    const winners = attempts.filter(
      (attempt) =>
        attempt.statusCode === 200 && attempt.body?.request?.status === "placed"
    );
    const losers = attempts.filter(
      (attempt) =>
        attempt.statusCode === 409 &&
        attempt.body?.error?.code === "REQUEST_ALREADY_PLACED"
    );
    expect(winners).toHaveLength(1);
    expect(losers).toHaveLength(1);
    expect(await MealRequest.countDocuments({ status: "placed" })).toBe(1);
    expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(1);
    expect(sendFulfillmentEmail).toHaveBeenCalledOnce();
  });

  it("rolls back the Request transition when the ledger insert fails", async () => {
    const forcedFailureIndex = "test_force_core_failure";
    const existingRequestId = new mongoose.Types.ObjectId();
    await Fulfillment.collection.createIndex(
      { orderNumber: 1 },
      { unique: true, name: forcedFailureIndex }
    );
    try {
      await Fulfillment.create({
        requestId: existingRequestId,
        orderNumber: "70154321",
        etaText: "10 minutes",
      });
      const { request, rawToken } = await createClaimedRequest();
      const context = routeContext(
        String(request._id),
        fulfillmentBody(rawToken)
      );

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(500);
      expect(context.body.error.code).toBe("INTERNAL_FAILURE");
      const stored = await MealRequest.findById(request._id)
        .select("+claimTokenDigest")
        .lean();
      expect(stored?.status).toBe("claimed");
      expect(stored?.claimTokenDigest).toBeDefined();
      expect(stored).not.toHaveProperty("placedAt");
      expect(
        await Fulfillment.countDocuments({ requestId: request._id })
      ).toBe(0);
      expect(sendFulfillmentEmail).not.toHaveBeenCalled();
    } finally {
      await Fulfillment.collection.dropIndex(forcedFailureIndex);
    }
  });

  it("enforces Fulfillment request uniqueness at the database", async () => {
    const requestId = new mongoose.Types.ObjectId();
    await Fulfillment.create({ requestId, orderNumber: "70150001" });

    await expect(
      Fulfillment.create({ requestId, orderNumber: "70150002" })
    ).rejects.toMatchObject({ code: 11000 });
    expect(await Fulfillment.countDocuments({ requestId })).toBe(1);
  });

  it("keeps the all-time stats count after the private Request expires or is removed", async () => {
    const { request, rawToken } = await createClaimedRequest();
    const placement = routeContext(
      String(request._id),
      fulfillmentBody(rawToken)
    );
    await fulfillRequest(placement.req, placement.res);
    expect(placement.statusCode).toBe(200);

    await MealRequest.deleteOne({ _id: request._id });
    const json = vi.fn();
    const next = vi.fn();
    await getStats({} as Request, { json } as unknown as Response, next);

    expect(json).toHaveBeenCalledWith({ totalShared: 1 });
    expect(next).not.toHaveBeenCalled();
  });

  // The post-commit notification is handed the *placed* document, which is what
  // carries the student address the request was created with. The helper's
  // address arrives only as the last argument — the Reply-To — so entering it on
  // the fulfillment form can never redirect the notification to them.
  it("notifies from the placed request and passes the helper address only as reply-to", async () => {
    const { request, rawToken } = await createClaimedRequest();
    const context = routeContext(
      String(request._id),
      fulfillmentBody(rawToken)
    );

    await fulfillRequest(context.req, context.res);

    expect(context.statusCode).toBe(200);
    expect(sendFulfillmentEmail).toHaveBeenCalledTimes(1);
    const [notified, orderNumber, eta, contactMessage, replyTo] =
      sendFulfillmentEmail.mock.calls[0];

    expect(String(notified._id)).toBe(String(request._id));
    expect(notified.status).toBe("placed");
    expect(notified.email).toBe("requester@example.edu");
    expect(notified.pickupName).toBe("Requester Pickup");
    expect(orderNumber).toBe("70154321");
    expect(eta).toBe("15 minutes");
    expect(contactMessage).toBe("Your meal is ready");
    // The claim-bound verified helper, and never the recipient. No payload
    // supplied it, so the Reply-To the requester sees is an address CommonPlate
    // has actually proved control of.
    expect(replyTo).toBe(boundHelperEmail);
    expect(notified.email).not.toBe(replyTo);
    expect(context.body.notification).toEqual({ status: "sent" });
  });

  it("attempts email after commit and keeps placement when provider submission fails", async () => {
    const { request, rawToken } = await createClaimedRequest();
    sendFulfillmentEmail.mockImplementationOnce(async () => {
      const committedRequest = await MealRequest.findById(request._id).lean();
      const committedLedger = await Fulfillment.findOne({
        requestId: request._id,
      }).lean();
      expect(committedRequest?.status).toBe("placed");
      expect(committedRequest?.notificationStatus).toBe("pending");
      expect(committedLedger).not.toBeNull();
      throw new Error("provider unavailable");
    });
    const context = routeContext(
      String(request._id),
      fulfillmentBody(rawToken)
    );

    await fulfillRequest(context.req, context.res);

    expect(context.statusCode).toBe(200);
    expect(context.body.request.status).toBe("placed");
    expect(context.body.notification).toEqual({ status: "failed" });
    const stored = await MealRequest.findById(request._id).lean();
    expect(stored?.status).toBe("placed");
    expect(stored?.notificationStatus).toBe("failed");
    expect(stored?.notificationAttemptedAt).toBeInstanceOf(Date);
    expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(1);
  });

  // Week 3 Day 6 Slice 6E: the requester-fulfillment push dispatcher reads
  // `installationId` off the placed document the transaction returns.
  // `installationId` is `select: false`, so this proves the placement query
  // actually requests it rather than silently carrying `undefined` through.
  it("carries the request's installationId through the placement transaction", async () => {
    const installationId = new mongoose.Types.ObjectId();
    const { request, rawToken } = await createClaimedRequest({ installationId });
    const context = routeContext(String(request._id), fulfillmentBody(rawToken));

    await fulfillRequest(context.req, context.res);

    expect(context.statusCode).toBe(200);
    const stored = await MealRequest.findById(request._id)
      .select("+installationId")
      .lean();
    expect(String(stored?.installationId)).toBe(String(installationId));
    // Never exposed through the public response.
    expect(JSON.stringify(context.body)).not.toContain(String(installationId));
  });

  it("places normally for a request with no installation association", async () => {
    const { request, rawToken } = await createClaimedRequest();
    const context = routeContext(String(request._id), fulfillmentBody(rawToken));

    await fulfillRequest(context.req, context.res);

    expect(context.statusCode).toBe(200);
    expect(context.body.request.status).toBe("placed");
    const stored = await MealRequest.findById(request._id)
      .select("+installationId")
      .lean();
    expect(stored?.installationId).toBeUndefined();
  });

  it("clears the verified helper's one-active-reservation lock on successful placement (W3-H1)", async () => {
    const { request, rawToken } = await createClaimedRequest();
    await Participant.updateOne(
      { _id: helperParticipantId },
      {
        $set: {
          activeReservationRequestId: request._id,
          activeReservationClaimExpiresAt: new Date(
            Date.now() + 60 * 60 * 1000
          ),
        },
      }
    ).exec();
    const context = routeContext(String(request._id), fulfillmentBody(rawToken));

    await fulfillRequest(context.req, context.res);

    expect(context.statusCode).toBe(200);
    const lock = await Participant.findById(helperParticipantId)
      .select("+activeReservationRequestId +activeReservationClaimExpiresAt")
      .lean();
    expect(lock?.activeReservationRequestId).toBeNull();
    expect(lock?.activeReservationClaimExpiresAt).toBeNull();
  });

  it("release-vs-fulfillment race cannot reopen a successful placement (W3-H1)", async () => {
    const { request, rawToken } = await createClaimedRequest();
    const release = routeContext(String(request._id), { claimToken: rawToken });
    const fulfill = routeContext(String(request._id), fulfillmentBody(rawToken));

    await Promise.all([
      releaseClaim(release.req, release.res),
      fulfillRequest(fulfill.req, fulfill.res),
    ]);

    // Both mutations pivot on the same `status: "claimed"` conditional
    // filter, so exactly one of them can have matched; the other lost the
    // race and was refused. Whichever won, the persisted status settles on a
    // terminal outcome the loser cannot undo.
    const releaseWon = release.statusCode === 200;
    const fulfillWon = fulfill.statusCode === 200;
    expect(releaseWon !== fulfillWon).toBe(true);
    const stored = await MealRequest.findById(request._id).lean();
    expect(stored?.status).toBe(releaseWon ? "open" : "placed");
  });

  describe("participant-authority continuation (W3-H1 MUST FIX 1)", () => {
    it("fulfills a restored reservation without the lost raw claim token", async () => {
      const { request } = await createClaimedRequest();
      const context = routeContext(
        String(request._id),
        continuationFulfillmentBody(),
        continuationHeaders
      );

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(200);
      expect(context.body.request.status).toBe("placed");
      const stored = await MealRequest.findById(request._id)
        .select("+claimTokenDigest")
        .lean();
      expect(stored?.status).toBe("placed");
      expect(stored?.orderNumber).toBe("70154321");
      expect(stored?.fulfillerEmail).toBe(boundHelperEmail);
      expect(stored).not.toHaveProperty("claimTokenDigest");
      expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(1);
      expect(sendFulfillmentEmail).toHaveBeenCalledWith(
        expect.objectContaining({ _id: request._id }),
        "70154321",
        "15 minutes",
        "Your meal is ready",
        boundHelperEmail
      );
    });

    it("still authorizes fine with the raw token unchanged (regression)", async () => {
      const { request, rawToken } = await createClaimedRequest();
      const context = routeContext(
        String(request._id),
        fulfillmentBody(rawToken)
      );

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(200);
      const stored = await MealRequest.findById(request._id).lean();
      expect(stored?.status).toBe("placed");
      expect(stored?.fulfillerEmail).toBe(boundHelperEmail);
    });

    it("refuses without any participant credential or raw token", async () => {
      const { request } = await createClaimedRequest();
      const context = routeContext(
        String(request._id),
        continuationFulfillmentBody()
      );

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(401);
      expect(context.body.error.code).toBe("PARTICIPANT_VERIFICATION_REQUIRED");
      const stored = await MealRequest.findById(request._id).lean();
      expect(stored?.status).toBe("claimed");
    });

    it("refuses fulfillment of a differently owned reservation", async () => {
      const otherParticipantId = new mongoose.Types.ObjectId();
      const { request } = await createClaimedRequest({
        helperParticipantId: otherParticipantId,
      });
      const context = routeContext(
        String(request._id),
        continuationFulfillmentBody(),
        continuationHeaders
      );

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(403);
      expect(context.body.error.code).toBe("INVALID_CLAIM_TOKEN");
      const stored = await MealRequest.findById(request._id).lean();
      expect(stored?.status).toBe("claimed");
      expect(sendFulfillmentEmail).not.toHaveBeenCalled();
    });

    it("refuses fulfillment of a released reservation", async () => {
      const released = await MealRequest.create({
        vendor: "Transaction Cafe",
        food: "Rice bowl",
        pickupName: "Requester Pickup",
        pickupWindowText: "ASAP",
        email: "requester@example.edu",
        status: "open",
        expiresAt: new Date(Date.now() + 60 * 60 * 1000),
        deleteAt: new Date(Date.now() + 60 * 60 * 1000),
      });
      const context = routeContext(
        String(released._id),
        continuationFulfillmentBody(),
        continuationHeaders
      );

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(409);
      expect(context.body.error.code).toBe("REQUEST_NOT_CLAIMED");
      expect(sendFulfillmentEmail).not.toHaveBeenCalled();
    });

    it("refuses fulfillment of an expired reservation", async () => {
      const { request } = await createClaimedRequest({
        claimExpiresAt: new Date(Date.now() - 1),
      });
      const context = routeContext(
        String(request._id),
        continuationFulfillmentBody(),
        continuationHeaders
      );

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(409);
      expect(context.body.error.code).toBe("CLAIM_EXPIRED");
      expect(sendFulfillmentEmail).not.toHaveBeenCalled();
    });

    it("refuses fulfillment of an already-placed reservation and cannot double-record it", async () => {
      const { request } = await createClaimedRequest({ status: "placed" });
      const context = routeContext(
        String(request._id),
        continuationFulfillmentBody(),
        continuationHeaders
      );

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(409);
      expect(context.body.error.code).toBe("REQUEST_ALREADY_PLACED");
      expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(0);
      expect(sendFulfillmentEmail).not.toHaveBeenCalled();
    });

    it("participant-authorized fulfillment racing release remains one-winner and cannot reopen placement", async () => {
      const { request } = await createClaimedRequest();
      const release = routeContext(String(request._id), {}, continuationHeaders);
      const fulfill = routeContext(
        String(request._id),
        continuationFulfillmentBody(),
        continuationHeaders
      );

      await Promise.all([
        releaseClaim(release.req, release.res),
        fulfillRequest(fulfill.req, fulfill.res),
      ]);

      const releaseWon = release.statusCode === 200;
      const fulfillWon = fulfill.statusCode === 200;
      expect(releaseWon !== fulfillWon).toBe(true);
      const stored = await MealRequest.findById(request._id).lean();
      expect(stored?.status).toBe(releaseWon ? "open" : "placed");
      expect(await Fulfillment.countDocuments({ requestId: request._id })).toBe(
        fulfillWon ? 1 : 0
      );
    });

    // The transactional rollback and one-active-reservation-lock-clearing
    // safeguards already proved above for the raw-token path are the same
    // production code path for participant-authority continuation — both
    // modes converge on the identical `persistCorePlacement` transaction —
    // so this proves the convergence itself rather than re-proving rollback
    // and lock-clearing from scratch.
    it("clears the verified helper's one-active-reservation lock via participant-authority continuation", async () => {
      const { request } = await createClaimedRequest();
      await Participant.updateOne(
        { _id: helperParticipantId },
        {
          $set: {
            activeReservationRequestId: request._id,
            activeReservationClaimExpiresAt: new Date(
              Date.now() + 60 * 60 * 1000
            ),
          },
        }
      ).exec();
      const context = routeContext(
        String(request._id),
        continuationFulfillmentBody(),
        continuationHeaders
      );

      await fulfillRequest(context.req, context.res);

      expect(context.statusCode).toBe(200);
      const lock = await Participant.findById(helperParticipantId)
        .select("+activeReservationRequestId +activeReservationClaimExpiresAt")
        .lean();
      expect(lock?.activeReservationRequestId).toBeNull();
      expect(lock?.activeReservationClaimExpiresAt).toBeNull();
    });
  });
});
