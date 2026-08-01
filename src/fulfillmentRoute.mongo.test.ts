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
import { Fulfillment, Request as MealRequest } from "../models/db.js";
import {
  digestClaimToken,
  generateClaimToken,
  readClaimTokenHmacSecret,
} from "./claimToken.js";

const sendFulfillmentEmail = vi.hoisted(() => vi.fn());
vi.mock("./emailHelpers.js", () => ({ sendFulfillmentEmail }));

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

function routeContext(id: string, body: unknown) {
  const req = { params: { id }, body } as unknown as Request;
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

function fulfillmentBody(rawToken: string) {
  return {
    claimToken: rawToken,
    fulfillment: {
      fulfillerEmail: "Helper@Example.edu",
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
    await mongoose.connect(mongoUri!);
    await MealRequest.syncIndexes();
    await Fulfillment.syncIndexes();
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
    expect(stored?.placedAt.getTime()).toBeGreaterThanOrEqual(before.getTime());
    expect(stored?.placedAt.getTime()).toBeLessThanOrEqual(after.getTime());
    expect(stored?.deleteAt.getTime() - stored?.placedAt.getTime()).toBe(
      PLACED_RETENTION_MS
    );
    expect(stored?.expiresAt).toEqual(originalExpiresAt);
    expect(stored?.orderNumber).toBe("70154321");
    expect(stored?.etaText).toBe("15 minutes");
    expect(stored?.fulfillerEmail).toBe("helper@example.edu");
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
      "helper@example.edu"
    );

    const active = await MealRequest.find(
      buildEffectiveAvailabilityFilter(new Date())
    ).lean();
    expect(active).toHaveLength(0);

    const publicDetail = buildPublicRequestDetailResponse(stored as any);
    expect(publicDetail.request.status).toBe("placed");
    expect(JSON.stringify(publicDetail)).not.toMatch(
      /pickupName|email|orderNumber|etaText|placedAt|contactMessage|notification|claim/i
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
        fulfillerEmail: "Helper@Example.edu",
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
      "helper@example.edu"
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
        fulfillerEmail: "Helper@Example.edu",
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
        fulfillerEmail: "Helper@Example.edu",
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
      "helper@example.edu"
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
    // Normalised by the payload schema, and never the recipient.
    expect(replyTo).toBe("helper@example.edu");
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
});
