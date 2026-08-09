import { generateKeyPairSync } from "node:crypto";
import type { Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { digestClaimToken, generateClaimToken } from "./claimToken.js";
import {
  Fulfillment,
  Installation,
  Participant,
  Request as MealRequest,
} from "../models/db.js";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";

/** A real, disposable EC key — the dispatcher's default configuration reader
 * validates that this parses as an EC private key, matching `apnsConfig.test.ts`. */
const { privateKey: apnsAuthKeyPem } = generateKeyPairSync("ec", {
  namedCurve: "prime256v1",
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
  publicKeyEncoding: { type: "spki", format: "pem" },
});

const sendFulfillmentEmail = vi.hoisted(() => vi.fn());
vi.mock("./emailHelpers.js", () => ({ sendFulfillmentEmail }));

import { fulfillRequest } from "./fulfillmentRoute.js";

const requestId = "64b000000000000000000001";

/**
 * The verified helper the reservation is bound to (W3-I1). Fulfillment no
 * longer accepts an address, so this is the only place a helper email can come
 * from, and every case below that expects one expects this.
 */
const helperParticipantId = new mongoose.Types.ObjectId(
  "64c0000000000000000000b2"
);
const boundHelperEmail = "helper@nyu.edu";

function validBody() {
  return {
    claimToken: generateClaimToken(),
    fulfillment: {
      orderNumber: "70154321",
      eta: "15 minutes",
      contactMessage: "Your meal is ready",
    },
  };
}

/**
 * Stubs both reads behind `resolveBoundHelper`, and leaves the diagnostic path
 * that shares `MealRequest.findById` alone by dispatching on the projection:
 * only the bound-helper read asks for `+helperParticipantId`.
 */
function stubBoundHelper({
  participantId = helperParticipantId as mongoose.Types.ObjectId | null,
  email = boundHelperEmail as string | null,
  diagnostic = null as unknown,
}: {
  participantId?: mongoose.Types.ObjectId | null;
  email?: string | null;
  diagnostic?: unknown;
} = {}) {
  vi.spyOn(MealRequest, "findById").mockImplementation(
    (() => ({
      select: (projection: string) => ({
        lean: () => ({
          exec: vi
            .fn()
            .mockResolvedValue(
              projection.includes("helperParticipantId")
                ? { helperParticipantId: participantId }
                : diagnostic
            ),
        }),
      }),
    })) as unknown as typeof MealRequest.findById
  );
  vi.spyOn(Participant, "findById").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi.fn().mockResolvedValue(email === null ? null : { email }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findById>);
}

function routeContext(body: unknown, id = requestId) {
  const req = { params: { id }, body } as unknown as Request;
  const res = {} as Response;
  const status = vi.fn().mockReturnValue(res);
  const json = vi.fn().mockReturnValue(res);
  res.status = status;
  res.json = json;
  return { req, res, status, json };
}

function responseBody(context: ReturnType<typeof routeContext>) {
  return context.json.mock.calls[0][0] as Record<string, any>;
}

beforeEach(() => {
  vi.stubEnv(
    "CLAIM_TOKEN_HMAC_SECRET",
    "unit-test-claim-hmac-secret-material"
  );
  stubBoundHelper();
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
  sendFulfillmentEmail.mockReset();
});

describe("POST /api/request/:id/fulfill validation", () => {
  it("rejects an invalid request id before starting a transaction", async () => {
    const startSession = vi.spyOn(mongoose, "startSession");
    const context = routeContext(validBody(), "not-an-object-id");

    await fulfillRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe("INVALID_REQUEST_ID");
    expect(startSession).not.toHaveBeenCalled();
  });

  it.each([
    undefined,
    {},
    { fulfillment: validBody().fulfillment },
    { claimToken: "not-a-canonical-token", fulfillment: validBody().fulfillment },
  ])("rejects a missing or malformed claim token", async (body) => {
    const startSession = vi.spyOn(mongoose, "startSession");
    const context = routeContext(body);

    await fulfillRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe("INVALID_CLAIM_TOKEN");
    expect(startSession).not.toHaveBeenCalled();
  });

  it.each([
    {
      name: "flat legacy payload",
      mutate: () => ({
        claimToken: generateClaimToken(),
        fulfillerEmail: "helper@example.edu",
        orderNumber: "70154321",
        eta: "15 minutes",
      }),
    },
    {
      name: "unsafe order number",
      mutate: () => ({
        ...validBody(),
        fulfillment: { ...validBody().fulfillment, orderNumber: "7015 4321" },
      }),
    },
    {
      name: "blank ETA",
      mutate: () => ({
        ...validBody(),
        fulfillment: { ...validBody().fulfillment, eta: "   " },
      }),
    },
    {
      name: "removed note field",
      mutate: () => ({
        ...validBody(),
        fulfillment: { ...validBody().fulfillment, note: "legacy note" },
      }),
    },
    {
      name: "helper phone field",
      mutate: () => ({
        ...validBody(),
        fulfillment: { ...validBody().fulfillment, helperPhone: "555-0100" },
      }),
    },
    {
      name: "client-owned placement timestamp",
      mutate: () => ({
        ...validBody(),
        fulfillment: {
          ...validBody().fulfillment,
          placedAt: "2020-01-01T00:00:00.000Z",
        },
      }),
    },
    {
      name: "unexpected top-level field",
      mutate: () => ({ ...validBody(), unexpected: true }),
    },
  ])("rejects $name", async ({ mutate }) => {
    const startSession = vi.spyOn(mongoose, "startSession");
    const context = routeContext(mutate());

    await fulfillRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe(
      "INVALID_FULFILLMENT_PAYLOAD"
    );
    expect(startSession).not.toHaveBeenCalled();
  });

  // A CommonPlate Grubhub order number contains digits only. Every rejection
  // below stops before a session is opened, so nothing about an already-paid
  // real-world order is put at risk by a malformed value.
  it.each([
    ["one letter", "7015432A"],
    ["leading letter", "A70154321"],
    ["all letters", "ORDERNUMBER"],
    ["interior space", "7015 4321"],
    ["surrounding spaces only", "   "],
    ["dash", "7015-4321"],
    ["underscore", "7015_4321"],
    ["decimal point", "7015.4321"],
    ["plus sign", "+70154321"],
    ["minus sign", "-70154321"],
    ["punctuation", "70154321!"],
    ["51 digits", "7".repeat(51)],
    ["empty", ""],
  ])("rejects a %s order number", async (_name, orderNumber) => {
    const startSession = vi.spyOn(mongoose, "startSession");
    const context = routeContext({
      ...validBody(),
      fulfillment: { ...validBody().fulfillment, orderNumber },
    });

    await fulfillRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe(
      "INVALID_FULFILLMENT_PAYLOAD"
    );
    // The envelope shape is unchanged by the tightened rule.
    expect(responseBody(context).error.fields).toBeNull();
    expect(startSession).not.toHaveBeenCalled();
    expect(sendFulfillmentEmail).not.toHaveBeenCalled();
  });

  // Accepted values are asserted through the schema rather than the route so no
  // transaction is required: reaching `startSession` is itself the proof that
  // validation let the value through.
  it.each([
    ["a single digit", "7"],
    ["an ordinary order number", "70154321"],
    ["a leading zero", "070154321"],
    ["several leading zeroes", "00070154321"],
    ["all zeroes", "0000000000"],
    ["50 digits", "7".repeat(50)],
    ["surrounding whitespace that trims away", "  70154321  "],
  ])("accepts %s", async (_name, orderNumber) => {
    const startSession = vi
      .spyOn(mongoose, "startSession")
      .mockRejectedValue(new Error("stop after validation"));
    const context = routeContext({
      ...validBody(),
      fulfillment: { ...validBody().fulfillment, orderNumber },
    });

    await fulfillRequest(context.req, context.res);

    expect(startSession).toHaveBeenCalledOnce();
    expect(responseBody(context).error?.code).not.toBe(
      "INVALID_FULFILLMENT_PAYLOAD"
    );
  });

  it("keeps the payload shape unchanged and the order number a string", async () => {
    const body = validBody();
    expect(Object.keys(body).sort()).toEqual(["claimToken", "fulfillment"]);
    // No `fulfillerEmail`: since W3-I1 the helper is the claim-bound verified
    // participant, so there is no address for this payload to supply and the
    // strict schema refuses one (proved by the "helper email field" case above).
    expect(Object.keys(body.fulfillment).sort()).toEqual([
      "contactMessage",
      "eta",
      "orderNumber",
    ]);
    expect(typeof body.fulfillment.orderNumber).toBe("string");

    // A JSON number is refused outright: the field is a string field, and
    // accepting a number would silently drop a leading zero and reshape a long
    // value the moment it round-tripped.
    const startSession = vi.spyOn(mongoose, "startSession");
    const context = routeContext({
      ...body,
      fulfillment: { ...body.fulfillment, orderNumber: 70154321 },
    });

    await fulfillRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe(
      "INVALID_FULFILLMENT_PAYLOAD"
    );
    expect(startSession).not.toHaveBeenCalled();
  });

  it("reports a standalone MongoDB deployment without downgrading writes", async () => {
    const unavailable = Object.assign(
      new Error(
        "Transaction numbers are only allowed on a replica set member or mongos"
      ),
      { code: 20 }
    );
    const session = {
      withTransaction: vi.fn().mockRejectedValue(unavailable),
      endSession: vi.fn().mockResolvedValue(undefined),
    };
    vi.spyOn(mongoose, "startSession").mockResolvedValue(session as any);
    const context = routeContext(validBody());

    await fulfillRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(503);
    expect(responseBody(context).error.code).toBe(
      "TRANSACTIONS_UNAVAILABLE"
    );
    expect(session.endSession).toHaveBeenCalledOnce();
    expect(sendFulfillmentEmail).not.toHaveBeenCalled();
  });

  it("answers in the structured envelope when no session can be opened", async () => {
    // The session is created inside the handler's try, so this failure must not
    // escape as a rejected promise into the generic error handler, and the
    // `finally` must not call endSession on a session that was never created.
    vi.spyOn(mongoose, "startSession").mockRejectedValue(
      new Error("no primary available")
    );
    const context = routeContext(validBody());

    await expect(
      fulfillRequest(context.req, context.res)
    ).resolves.toBeDefined();

    expect(context.status).toHaveBeenCalledWith(500);
    expect(responseBody(context)).toEqual({
      error: {
        code: "INTERNAL_FAILURE",
        message: "Unable to record this placement right now.",
        fields: null,
      },
    });
    expect(sendFulfillmentEmail).not.toHaveBeenCalled();
  });

  it("answers in the structured envelope when the HMAC secret is unusable", async () => {
    vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", "too-short");
    const startSession = vi.spyOn(mongoose, "startSession");
    const context = routeContext(validBody());

    await expect(
      fulfillRequest(context.req, context.res)
    ).resolves.toBeDefined();

    expect(context.status).toHaveBeenCalledWith(500);
    expect(responseBody(context).error.code).toBe("INTERNAL_FAILURE");
    expect(startSession).not.toHaveBeenCalled();
    expect(sendFulfillmentEmail).not.toHaveBeenCalled();
  });

  it("continues the committed placement response path when session cleanup fails", async () => {
    const placedRequest = {
      _id: new mongoose.Types.ObjectId(requestId),
      vendor: "Campus Market",
      food: "Vegetable rice bowl",
      pickupWindowText: "ASAP",
      status: "placed",
      createdAt: new Date("2026-08-02T12:00:00.000Z"),
      expiresAt: new Date("2026-08-02T17:00:00.000Z"),
    };
    const update = vi.fn().mockReturnValue({ exec: vi.fn().mockResolvedValue({}) });
    const placement = vi.fn().mockReturnValue({
      select: vi.fn().mockReturnValue({
        exec: vi.fn().mockResolvedValue(placedRequest),
      }),
    });
    const ledger = vi.spyOn(Fulfillment, "create").mockResolvedValue([] as never);
    vi.spyOn(MealRequest, "findOneAndUpdate").mockImplementation(placement as never);
    vi.spyOn(MealRequest, "updateOne").mockImplementation(update as never);
    const session = {
      withTransaction: vi.fn().mockImplementation(async (operation) => operation()),
      endSession: vi.fn().mockRejectedValue(new Error("cleanup unavailable")),
    };
    vi.spyOn(mongoose, "startSession").mockResolvedValue(session as any);
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    const context = routeContext(validBody());

    await fulfillRequest(context.req, context.res);

    expect(session.withTransaction).toHaveBeenCalledOnce();
    expect(session.endSession).toHaveBeenCalledOnce();
    expect(placement).toHaveBeenCalledOnce();
    expect(ledger).toHaveBeenCalledOnce();
    expect(context.status).not.toHaveBeenCalled();
    expect(responseBody(context)).toEqual({
      request: expect.objectContaining({ id: requestId, status: "placed" }),
      notification: { status: "sent" },
    });
    expect(consoleError).toHaveBeenCalledWith(
      "[fulfillment] MongoDB session cleanup failed after placement attempt"
    );
    expect(JSON.stringify(consoleError.mock.calls)).not.toContain("helper@example.edu");
    expect(JSON.stringify(consoleError.mock.calls)).not.toContain("70154321");
  });
});

describe("POST /api/request/:id/fulfill reuses the claim-bound helper identity (W3-I1)", () => {
  const claimToken = generateClaimToken();
  const placedAt = new Date("2026-08-01T12:00:00.000Z");

  /**
   * A committed placement whose conditional update and ledger insert both
   * succeed, so the assertions below can read what was actually written.
   */
  function stubCommittedPlacement() {
    const placed = {
      _id: new mongoose.Types.ObjectId(requestId),
      status: "placed",
      vendor: "Palladium",
      food: "Vegetable rice bowl",
      pickupWindowText: "ASAP",
      windowStart: null,
      windowEnd: null,
      createdAt: placedAt,
      expiresAt: new Date(placedAt.getTime() + 3 * 60 * 60 * 1000),
      placedAt,
    };
    const findOneAndUpdate = vi
      .spyOn(MealRequest, "findOneAndUpdate")
      .mockReturnValue({
        select: () => ({ exec: vi.fn().mockResolvedValue(placed) }),
      } as unknown as ReturnType<typeof MealRequest.findOneAndUpdate>);
    vi.spyOn(Fulfillment, "create").mockResolvedValue([{}] as never);
    vi.spyOn(MealRequest, "updateOne").mockReturnValue({
      exec: vi.fn().mockResolvedValue({}),
    } as unknown as ReturnType<typeof MealRequest.updateOne>);
    vi.spyOn(mongoose, "startSession").mockResolvedValue({
      withTransaction: vi.fn(async (work: () => Promise<void>) => {
        await work();
      }),
      endSession: vi.fn().mockResolvedValue(undefined),
    } as never);
    return { findOneAndUpdate, placed };
  }

  it("persists and emails the bound helper's address, which no payload supplied", async () => {
    const { findOneAndUpdate } = stubCommittedPlacement();
    const context = routeContext({ ...validBody(), claimToken });

    await fulfillRequest(context.req, context.res);

    const [filter, update] = findOneAndUpdate.mock.calls[0] as any[];
    expect(update.$set.fulfillerEmail).toBe(boundHelperEmail);
    // The write is pinned to the same binding the address was read from, so a
    // reservation that lapsed and was re-claimed in between cannot have the
    // previous helper's address recorded against the new helper's order.
    expect(filter.helperParticipantId).toEqual(helperParticipantId);
    expect(sendFulfillmentEmail).toHaveBeenCalledWith(
      expect.anything(),
      "70154321",
      "15 minutes",
      "Your meal is ready",
      boundHelperEmail
    );
  });

  it("keeps the helper's identity out of the public placement response", async () => {
    stubCommittedPlacement();
    const context = routeContext({ ...validBody(), claimToken });

    await fulfillRequest(context.req, context.res);

    const body = JSON.stringify(responseBody(context));
    expect(body).not.toContain(boundHelperEmail);
    expect(body).not.toContain(helperParticipantId.toString());
  });

  it("records placement for a pre-I1 claim with no bound helper (legacy compatibility)", async () => {
    // A claim granted before verified helper identity existed carries no
    // `helperParticipantId` at all. Per the accepted pre-I1 compatibility
    // path, this must still be recordable on the existing valid-token
    // authorization alone, not refused.
    stubBoundHelper({ participantId: null });
    const { findOneAndUpdate } = stubCommittedPlacement();
    const context = routeContext({ ...validBody(), claimToken });

    await fulfillRequest(context.req, context.res);

    expect(context.status).not.toHaveBeenCalled();
    const [filter, update] = findOneAndUpdate.mock.calls[0] as any[];
    // Pinned to the exact legacy absence, not to any participant id, so a
    // reservation re-claimed by a verified helper in between cannot be
    // recorded through this path.
    expect(filter.helperParticipantId).toEqual({ $exists: false });
    expect(update.$set.fulfillerEmail).toBeUndefined();
    expect(sendFulfillmentEmail).toHaveBeenCalledWith(
      expect.anything(),
      "70154321",
      "15 minutes",
      "Your meal is ready",
      undefined
    );
  });

  it("refuses when the bound participant row itself is gone", async () => {
    stubBoundHelper({ email: null, diagnostic: null });
    const context = routeContext({ ...validBody(), claimToken });

    await fulfillRequest(context.req, context.res);

    // Falls through the ordinary classifier first: no request document means
    // "not found", which is the truthful answer and not an identity problem.
    expect(context.status).toHaveBeenCalledWith(404);
    expect(responseBody(context).error.code).toBe("REQUEST_NOT_FOUND");
  });

  it.each([
    [
      "already placed",
      409,
      "REQUEST_ALREADY_PLACED",
      { status: "placed" },
    ],
    [
      "not claimed",
      409,
      "REQUEST_NOT_CLAIMED",
      { status: "open" },
    ],
  ])(
    "keeps the existing %s classification for a legacyCompatible claim whose conditional update misses",
    async (_label, status, code, diagnostic) => {
      // Legacy absence no longer short-circuits: the conditional update still
      // runs, pinned to `helperParticipantId: { $exists: false }`, and misses
      // for the same reason an ordinary claim would — the document's actual
      // status does not match `claimed`. The ordinary classifier then answers
      // from the diagnostic, exactly as it would for a verified claim.
      stubBoundHelper({ participantId: null, diagnostic });
      vi.spyOn(MealRequest, "findOneAndUpdate").mockReturnValue({
        select: () => ({ exec: vi.fn().mockResolvedValue(null) }),
      } as unknown as ReturnType<typeof MealRequest.findOneAndUpdate>);
      vi.spyOn(mongoose, "startSession").mockResolvedValue({
        withTransaction: vi.fn(async (work: () => Promise<void>) => {
          await work();
        }),
        endSession: vi.fn().mockResolvedValue(undefined),
      } as never);
      const context = routeContext({ ...validBody(), claimToken });

      await fulfillRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(status);
      expect(responseBody(context).error.code).toBe(code);
    }
  );

  /**
   * The wire shape an app build that predates W3-I1 actually sends.
   *
   * Reproduced from the committed pre-I1 iOS DTOs rather than rebuilt from the
   * current ones, because the whole risk this covers is that the two differ:
   *
   *   struct FulfillmentPayload: Encodable {
   *       let fulfillerEmail: String
   *       let orderNumber: String
   *       let eta: String
   *       let contactMessage: String?
   *   }
   *   struct FulfillRequestPayload: Encodable {
   *       let claimToken: String
   *       let fulfillment: FulfillmentPayload
   *   }
   *
   * `contactMessage` is a synthesized optional, which Swift encodes with
   * `encodeIfPresent` — a nil note omits the key entirely rather than sending
   * `null`, so `contactMessage: null` is a shape this client never produced.
   */
  function preI1Body({ note = "Your meal is ready" as string | null } = {}) {
    const fulfillment: Record<string, unknown> = {
      fulfillerEmail: "someone-else@nyu.edu",
      orderNumber: "70154321",
      eta: "15 minutes",
    };
    if (note !== null) fulfillment.contactMessage = note;
    return { claimToken, fulfillment };
  }

  describe("pre-I1 wire compatibility", () => {
    it("records a grandfathered placement from the real pre-I1 payload", async () => {
      // The population this carve-out exists for: a claim granted before
      // `helperParticipantId` existed, held by the build that sends
      // `fulfillerEmail`. If the schema refused the key, this helper would be
      // holding a real Grubhub order with no way to record it.
      stubBoundHelper({ participantId: null });
      const { findOneAndUpdate } = stubCommittedPlacement();
      const context = routeContext(preI1Body());

      await fulfillRequest(context.req, context.res);

      expect(context.status).not.toHaveBeenCalled();
      const [filter, update] = findOneAndUpdate.mock.calls[0] as any[];
      expect(filter.helperParticipantId).toEqual({ $exists: false });
      // Accepted as wire shape and discarded. It is not identity, so it is not
      // persisted and not offered to the requester as a reply address.
      expect(update.$set.fulfillerEmail).toBeUndefined();
      expect(JSON.stringify(update)).not.toContain("someone-else@nyu.edu");
      expect(sendFulfillmentEmail).toHaveBeenCalledWith(
        expect.anything(),
        "70154321",
        "15 minutes",
        "Your meal is ready",
        undefined
      );
    });

    it("still derives the helper from the binding when a pre-I1 build fulfills a bound claim", async () => {
      // An older build can also hold a claim granted *after* this slice. The
      // submitted address must lose to the binding every time.
      const { findOneAndUpdate } = stubCommittedPlacement();
      const context = routeContext(preI1Body());

      await fulfillRequest(context.req, context.res);

      const [filter, update] = findOneAndUpdate.mock.calls[0] as any[];
      expect(filter.helperParticipantId).toEqual(helperParticipantId);
      expect(update.$set.fulfillerEmail).toBe(boundHelperEmail);
      expect(sendFulfillmentEmail).toHaveBeenCalledWith(
        expect.anything(),
        "70154321",
        "15 minutes",
        "Your meal is ready",
        boundHelperEmail
      );
    });

    it("accepts the pre-I1 payload that omits the optional note", async () => {
      stubBoundHelper({ participantId: null });
      stubCommittedPlacement();
      const context = routeContext(preI1Body({ note: null }));

      await fulfillRequest(context.req, context.res);

      expect(context.status).not.toHaveBeenCalled();
    });

    it.each([
      ["a wrong token", generateClaimToken()],
      ["a malformed token", "not-a-canonical-token"],
    ])(
      "still refuses a pre-I1 payload carrying %s",
      async (_label, submittedToken) => {
        // Tolerating the legacy key changes nothing about authorization: the
        // raw claim token is still the only thing that authorizes a placement.
        stubBoundHelper({
          participantId: null,
          diagnostic: {
            _id: new mongoose.Types.ObjectId(requestId),
            status: "claimed",
            claimExpiresAt: new Date(placedAt.getTime() + 60_000),
            claimTokenDigest: "a".repeat(64),
          },
        });
        vi.spyOn(MealRequest, "findOneAndUpdate").mockReturnValue({
          select: () => ({ exec: vi.fn().mockResolvedValue(null) }),
        } as unknown as ReturnType<typeof MealRequest.findOneAndUpdate>);
        vi.spyOn(mongoose, "startSession").mockResolvedValue({
          withTransaction: vi.fn(async (work: () => Promise<void>) => {
            await work();
          }),
          endSession: vi.fn().mockResolvedValue(undefined),
        } as never);
        const context = routeContext({
          ...preI1Body(),
          claimToken: submittedToken,
        });

        await fulfillRequest(context.req, context.res);

        expect(context.status).toHaveBeenCalled();
        expect(context.status.mock.calls[0][0]).not.toBe(200);
        expect(sendFulfillmentEmail).not.toHaveBeenCalled();
      }
    );
  });
});

describe("POST /api/request/:id/fulfill requester push isolation (Slice 6E)", () => {
  /**
   * Mirrors `POST /api/request helper push isolation` in
   * `createRequestRoute.test.ts`. Push dispatch is started after the response
   * is sent and is never awaited, so these cases prove the response is
   * unaffected, that dispatch was started, and that no push failure can reach
   * the requester — dispatch behavior itself is tested directly against
   * `dispatchRequesterFulfillmentPush`.
   *
   * The real `startRequesterFulfillmentPush` runs here rather than a mock:
   * its totality is precisely what keeps an escaping throw out of
   * `fulfillRequest`'s response path, which would otherwise attempt a second
   * response on a request whose headers are already flushed.
   */
  let pausedBefore: string | undefined;
  let installationFindOne: ReturnType<typeof vi.spyOn>;

  function stubbedPlacementPipeline(
    installationId?: mongoose.Types.ObjectId
  ) {
    const placedRequest = {
      _id: new mongoose.Types.ObjectId(requestId),
      vendor: "Campus Market",
      food: "Vegetable rice bowl",
      pickupWindowText: "ASAP",
      status: "placed",
      createdAt: new Date("2026-08-02T12:00:00.000Z"),
      expiresAt: new Date("2026-08-02T17:00:00.000Z"),
      ...(installationId ? { installationId } : {}),
    };
    vi.spyOn(MealRequest, "findOneAndUpdate").mockReturnValue({
      select: () => ({ exec: async () => placedRequest }),
    } as never);
    vi.spyOn(MealRequest, "updateOne").mockReturnValue({
      exec: async () => ({}),
    } as never);
    vi.spyOn(Fulfillment, "create").mockResolvedValue([] as never);
    vi.spyOn(mongoose, "startSession").mockResolvedValue({
      withTransaction: async (operation: () => Promise<void>) => operation(),
      endSession: async () => {},
    } as any);
    return placedRequest;
  }

  beforeEach(() => {
    // Fulfillment is not gated by `pauseDay4Mutation`, but the dispatcher
    // carries its own public-actions guard, and it must be off for these
    // cases to reach dispatch at all.
    pausedBefore = process.env[PUBLIC_ACTIONS_PAUSED_ENV];
    process.env[PUBLIC_ACTIONS_PAUSED_ENV] = "false";
    // The dispatcher reads real APNs configuration before it ever reaches
    // `Installation.findOne`; a real (disposable) EC key lets it get there
    // without a network dependency.
    vi.stubEnv("APNS_TEAM_ID", "ABCDE12345");
    vi.stubEnv("APNS_KEY_ID", "KEY1234567");
    vi.stubEnv("APNS_BUNDLE_ID", "org.commonplatenyu.CommonPlateios");
    vi.stubEnv("APNS_AUTH_KEY_P8", apnsAuthKeyPem);
    // Nothing may reach a real APNs submission from a route test.
    installationFindOne = vi
      .spyOn(Installation, "findOne")
      .mockReturnValue({
        select: () => ({ lean: () => ({ exec: async () => null }) }),
      } as never) as ReturnType<typeof vi.spyOn>;
    vi.spyOn(console, "log").mockImplementation(() => {});
  });

  afterEach(() => {
    // The file-level `afterEach` above already calls `vi.unstubAllEnvs()`.
    if (pausedBefore === undefined) {
      delete process.env[PUBLIC_ACTIONS_PAUSED_ENV];
    } else {
      process.env[PUBLIC_ACTIONS_PAUSED_ENV] = pausedBefore;
    }
  });

  it("starts requester push after the response, with the committed placed request", async () => {
    const installationId = new mongoose.Types.ObjectId();
    stubbedPlacementPipeline(installationId);
    const context = routeContext(validBody());

    await fulfillRequest(context.req, context.res);

    expect(context.json).toHaveBeenCalledOnce();
    expect(installationFindOne).toHaveBeenCalledWith(
      expect.objectContaining({ _id: installationId })
    );
    // The response was built and sent before dispatch was started.
    expect(context.json.mock.invocationCallOrder[0]).toBeLessThan(
      installationFindOne.mock.invocationCallOrder[0]
    );
  });

  it("starts no push, with no fallback recipient, when the placed request has no association", async () => {
    stubbedPlacementPipeline();
    const context = routeContext(validBody());

    await fulfillRequest(context.req, context.res);

    expect(context.json).toHaveBeenCalledOnce();
    expect(installationFindOne).not.toHaveBeenCalled();
  });

  it("returns 200 without waiting on a dispatch that never settles", async () => {
    const installationId = new mongoose.Types.ObjectId();
    stubbedPlacementPipeline(installationId);
    installationFindOne.mockReturnValue({
      select: () => ({ lean: () => ({ exec: () => new Promise(() => {}) }) }),
    } as never);
    const context = routeContext(validBody());

    const started = Date.now();
    await fulfillRequest(context.req, context.res);

    expect(context.json).toHaveBeenCalledOnce();
    expect(Date.now() - started).toBeLessThan(2_000);
  });

  it("returns 200 and answers once when the dispatcher throws synchronously", async () => {
    const installationId = new mongoose.Types.ObjectId();
    stubbedPlacementPipeline(installationId);
    const rejections: unknown[] = [];
    const onRejection = (reason: unknown) => rejections.push(reason);
    process.on("unhandledRejection", onRejection);
    installationFindOne.mockImplementation(() => {
      throw new Error("selection exploded");
    });
    const context = routeContext(validBody());

    try {
      await fulfillRequest(context.req, context.res);
      await new Promise((resolve) => setTimeout(resolve, 10));
    } finally {
      process.off("unhandledRejection", onRejection);
    }

    expect(context.json).toHaveBeenCalledOnce();
    expect(rejections).toEqual([]);
  });
});
