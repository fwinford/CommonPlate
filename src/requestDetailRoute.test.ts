import type { NextFunction, Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Participant, RequestParticipation } from "../models/db.js";
import { Request as MealRequest } from "../models/db.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import {
  REQUEST_NOT_YET_AVAILABLE_CODE,
  REQUEST_NOT_YET_AVAILABLE_MESSAGE,
} from "./requestAvailability.js";
import { getPublicRequestDetail } from "./requestDetailRoute.js";

function requestDocument(overrides: Record<string, unknown> = {}) {
  return {
    _id: new mongoose.Types.ObjectId("64b000000000000000000001"),
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName: "Requester Private Name",
    pickupWindowText: "1:00 PM – 2:00 PM",
    // Every request accepted since W3-C1 carries an integer 1-5, on every
    // accepted shape including the legacy web one, so an ordinary fixture
    // always supplies it.
    mealSwipes: 3,
    email: "requester@example.edu",
    requesterPhone: "555-0100",
    requesterPhoneNumber: "555-0101",
    phone: "555-0102",
    windowStart: new Date("2026-07-26T20:00:00.000Z"),
    windowEnd: new Date("2026-07-26T21:00:00.000Z"),
    status: "open",
    createdAt: new Date("2026-07-26T18:00:00.000Z"),
    expiresAt: new Date("2026-07-26T22:00:00.000Z"),
    claimToken: "raw-token",
    claimTokenHash: "hashed-token",
    claimTokenDigest: "digested-token",
    claimExpiresAt: new Date("2026-07-26T19:15:00.000Z"),
    claimedAt: new Date("2026-07-26T19:00:00.000Z"),
    claimExtendedAt: null,
    deleteAt: new Date("2026-07-26T22:00:00.000Z"),
    orderNumber: "private-order-number",
    eta: new Date("2026-07-26T20:30:00.000Z"),
    etaText: "30 minutes",
    placedAt: new Date("2026-07-26T20:15:00.000Z"),
    fulfillerEmail: "helper@example.edu",
    contactMessage: "private message",
    note: "private note",
    notificationStatus: "pending_retry",
    notificationAttemptedAt: new Date("2026-07-26T20:16:00.000Z"),
    __v: 0,
    ...overrides,
  };
}

// Mirrors the route's real query chain. `.select("+requesterParticipantId")`
// (W4-H2) is what makes the caller-relative ownership signal derivable at all,
// so the mock has to model it rather than skipping straight to `.lean()`.
function mockFindById(result: unknown): void {
  vi.spyOn(MealRequest, "findById").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi.fn().mockResolvedValue(result),
      }),
    }),
  } as unknown as ReturnType<typeof MealRequest.findById>);
}

function routeContext(
  id = "64b000000000000000000001",
  headers: Record<string, string> = {}
) {
  const req = { params: { id }, headers } as unknown as Request;
  const json = vi.fn();
  const status = vi.fn().mockReturnValue({ json });
  const setHeaders: Record<string, string> = {};
  const setHeader = vi.fn((name: string, value: string) => {
    setHeaders[name] = value;
  });
  const res = { json, status, setHeader } as unknown as Response;
  const next = vi.fn() as unknown as NextFunction;

  return { req, res, next, json, status, setHeader, setHeaders };
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("GET /api/request/:id", () => {
  it("returns the canonical public detail wrapper without private fields", async () => {
    mockFindById(requestDocument());
    const context = routeContext();

    await getPublicRequestDetail(context.req, context.res, context.next);

    expect(context.json).toHaveBeenCalledWith({
      request: {
        id: "64b000000000000000000001",
        vendor: "Campus Market",
        food: "Vegetable rice bowl",
        pickupWindowText: "1:00 PM – 2:00 PM",
        mealSwipes: 3,
        windowStart: new Date("2026-07-26T20:00:00.000Z"),
        windowEnd: new Date("2026-07-26T21:00:00.000Z"),
        status: "open",
        createdAt: new Date("2026-07-26T18:00:00.000Z"),
        expiresAt: new Date("2026-07-26T22:00:00.000Z"),
      },
    });

    const serializedResponse = JSON.parse(
      JSON.stringify(context.json.mock.calls[0][0])
    ) as { request: Record<string, unknown> };
    expect(Object.keys(serializedResponse)).toEqual(["request"]);
    expect(Object.keys(serializedResponse.request)).toEqual([
      "id",
      "vendor",
      "food",
      "pickupWindowText",
      "mealSwipes",
      "windowStart",
      "windowEnd",
      "status",
      "createdAt",
      "expiresAt",
    ]);
    expect(serializedResponse.request).not.toHaveProperty("email");
    expect(serializedResponse.request).not.toHaveProperty("requesterPhone");
    expect(serializedResponse.request).not.toHaveProperty(
      "requesterPhoneNumber"
    );
    expect(serializedResponse.request).not.toHaveProperty("phone");
    expect(serializedResponse.request).not.toHaveProperty("pickupName");
    expect(serializedResponse.request).not.toHaveProperty("claimToken");
    expect(serializedResponse.request).not.toHaveProperty("claimTokenHash");
    expect(serializedResponse.request).not.toHaveProperty("claimTokenDigest");
    expect(serializedResponse.request).not.toHaveProperty("claimExpiresAt");
    expect(serializedResponse.request).not.toHaveProperty("claimedAt");
    expect(serializedResponse.request).not.toHaveProperty("claimExtendedAt");
    expect(serializedResponse.request).not.toHaveProperty("deleteAt");
    expect(serializedResponse.request).not.toHaveProperty("orderNumber");
    expect(serializedResponse.request).not.toHaveProperty("eta");
    expect(serializedResponse.request).not.toHaveProperty("etaText");
    expect(serializedResponse.request).not.toHaveProperty("placedAt");
    expect(serializedResponse.request).not.toHaveProperty("fulfillerEmail");
    expect(serializedResponse.request).not.toHaveProperty("contactMessage");
    expect(serializedResponse.request).not.toHaveProperty("note");
    expect(serializedResponse.request).not.toHaveProperty(
      "notificationStatus"
    );
    expect(serializedResponse.request).not.toHaveProperty(
      "notificationAttemptedAt"
    );
    expect(serializedResponse.request).not.toHaveProperty("_id");
    expect(serializedResponse.request).not.toHaveProperty("__v");
    expect(context.next).not.toHaveBeenCalled();
  });

  it("defensively serializes no meal-swipe key for a malformed pre-C1 stored request with no quantity", async () => {
    // Every shape `POST /api/request` accepts, including the legacy web one,
    // has required an integer 1-5 since W3-C1; a `Request` document with none
    // is not a supported representation of any accepted submission, only a
    // stale/malformed stored row. This proves the projection passes that
    // absence through rather than fabricating a `null` placeholder for it.
    mockFindById(requestDocument({ mealSwipes: undefined }));
    const context = routeContext();

    await getPublicRequestDetail(context.req, context.res, context.next);

    const serializedResponse = JSON.parse(
      JSON.stringify(context.json.mock.calls[0][0])
    ) as { request: Record<string, unknown> };
    expect(serializedResponse.request).not.toHaveProperty("mealSwipes");
  });

  it("preserves the existing not-found response", async () => {
    mockFindById(null);
    const context = routeContext();

    await getPublicRequestDetail(context.req, context.res, context.next);

    expect(context.status).toHaveBeenCalledWith(404);
    expect(
      (context.status.mock.results[0].value as { json: typeof context.json })
        .json
    ).toHaveBeenCalledWith({ error: "Request not found" });
    expect(context.next).not.toHaveBeenCalled();
  });

  it("does not apply list-only status or expiration filtering", async () => {
    mockFindById(
      requestDocument({
        status: "placed",
        expiresAt: new Date("2020-01-01T00:00:00.000Z"),
      })
    );
    const context = routeContext();

    await getPublicRequestDetail(context.req, context.res, context.next);

    expect(context.json).toHaveBeenCalledWith(
      expect.objectContaining({
        request: expect.objectContaining({
          status: "placed",
          expiresAt: new Date("2020-01-01T00:00:00.000Z"),
        }),
      })
    );
    expect(context.status).not.toHaveBeenCalled();
  });

  it("reports a claim-expired request as effectively open", async () => {
    const now = Date.now();
    mockFindById(
      requestDocument({
        status: "claimed",
        expiresAt: new Date(now + 60 * 60 * 1000),
        claimExpiresAt: new Date(now - 60 * 1000),
      })
    );
    const context = routeContext();

    await getPublicRequestDetail(context.req, context.res, context.next);

    expect(context.json).toHaveBeenCalledWith(
      expect.objectContaining({
        request: expect.objectContaining({ status: "open" }),
      })
    );
  });

  it("keeps a claimed request with an unexpired claim as claimed", async () => {
    const now = Date.now();
    mockFindById(
      requestDocument({
        status: "claimed",
        expiresAt: new Date(now + 60 * 60 * 1000),
        claimExpiresAt: new Date(now + 30 * 60 * 1000),
      })
    );
    const context = routeContext();

    await getPublicRequestDetail(context.req, context.res, context.next);

    expect(context.json).toHaveBeenCalledWith(
      expect.objectContaining({
        request: expect.objectContaining({ status: "claimed" }),
      })
    );
  });

  it("keeps an open request whose expiration has passed as open, not effectively available", async () => {
    mockFindById(
      requestDocument({
        status: "open",
        expiresAt: new Date("2020-01-01T00:00:00.000Z"),
      })
    );
    const context = routeContext();

    await getPublicRequestDetail(context.req, context.res, context.next);

    expect(context.json).toHaveBeenCalledWith(
      expect.objectContaining({
        request: expect.objectContaining({ status: "open" }),
      })
    );
  });

  /**
   * The W3-R1 visibility rule applied to the one unauthenticated read that
   * returns a single named request. A future scheduled request is withheld
   * from the list, and knowing its id must not be a way around that.
   */
  describe("a scheduled request before its visibleFrom", () => {
    const visibleFrom = new Date("2026-07-26T20:00:00.000Z");

    // Only `Date` is faked, and only here, so each case can name the exact
    // instant it is asking about while the rest of the file keeps real time.
    beforeEach(() => {
      vi.useFakeTimers({ toFake: ["Date"] });
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    function futureRequest(overrides: Record<string, unknown> = {}) {
      return requestDocument({
        status: "open",
        visibleFrom,
        windowStart: visibleFrom,
        windowEnd: new Date("2026-07-26T23:00:00.000Z"),
        expiresAt: new Date("2026-07-26T23:00:00.000Z"),
        claimExpiresAt: null,
        ...overrides,
      });
    }

    it("returns the distinct not-yet-available outcome one millisecond before the start", async () => {
      vi.setSystemTime(new Date(visibleFrom.getTime() - 1));
      mockFindById(futureRequest());
      const context = routeContext();

      await getPublicRequestDetail(context.req, context.res, context.next);

      expect(context.status).toHaveBeenCalledWith(409);
      const body = (
        context.status.mock.results[0].value as { json: typeof context.json }
      ).json.mock.calls[0][0] as Record<string, unknown>;
      expect(body).toEqual({
        error: {
          code: "REQUEST_NOT_YET_AVAILABLE",
          message: "This request is not available to help with yet.",
          fields: null,
        },
      });
      expect(context.next).not.toHaveBeenCalled();
    });

    it("carries no request content in that refusal", async () => {
      vi.setSystemTime(new Date(visibleFrom.getTime() - 1));
      mockFindById(futureRequest());
      const context = routeContext();

      await getPublicRequestDetail(context.req, context.res, context.next);

      const serialized = JSON.stringify(
        (context.status.mock.results[0].value as { json: typeof context.json })
          .json.mock.calls[0][0]
      );
      // No vendor, no food, no window text, no status, no id, no instants —
      // the outcome says when, and nothing about what.
      for (const secret of [
        "Campus Market",
        "Vegetable rice bowl",
        "1:00 PM",
        "Requester Private Name",
        "open",
        "64b000000000000000000001",
        "2026-07-26",
      ]) {
        expect(serialized).not.toContain(secret);
      }
      // And it is not the response wrapper a served request produces.
      expect(context.json).not.toHaveBeenCalledWith(
        expect.objectContaining({ request: expect.anything() })
      );
    });

    it("stays distinct from the not-found outcome for a request that truly does not exist", async () => {
      vi.setSystemTime(new Date(visibleFrom.getTime() - 1));

      mockFindById(futureRequest());
      const notYet = routeContext();
      await getPublicRequestDetail(notYet.req, notYet.res, notYet.next);

      mockFindById(null);
      const missing = routeContext();
      await getPublicRequestDetail(missing.req, missing.res, missing.next);

      // "Come back later" and "there is no such request" are different facts,
      // and a client must be able to tell them apart from the response alone.
      expect(notYet.status).toHaveBeenCalledWith(409);
      expect(missing.status).toHaveBeenCalledWith(404);

      const notYetBody = (
        notYet.status.mock.results[0].value as { json: typeof notYet.json }
      ).json.mock.calls[0][0];
      const missingBody = (
        missing.status.mock.results[0].value as { json: typeof missing.json }
      ).json.mock.calls[0][0];

      expect(missingBody).toEqual({ error: "Request not found" });
      expect(notYetBody).not.toEqual(missingBody);
    });

    it("serves ordinary detail at exactly the start instant", async () => {
      // The bound is inclusive, matching `isVisibleNow` and the create-time
      // start rule: visible at its start, not one millisecond after it.
      vi.setSystemTime(visibleFrom);
      mockFindById(futureRequest());
      const context = routeContext();

      await getPublicRequestDetail(context.req, context.res, context.next);

      expect(context.status).not.toHaveBeenCalled();
      expect(context.json).toHaveBeenCalledWith(
        expect.objectContaining({
          request: expect.objectContaining({
            vendor: "Campus Market",
            status: "open",
          }),
        })
      );
    });

    it("keeps the legacy compatibility behavior for a row with no visibleFrom", async () => {
      // Requests persisted before the field existed were visible from
      // creation, and nothing migrates them, so they must stay reachable.
      vi.setSystemTime(new Date("2026-07-26T18:30:00.000Z"));
      mockFindById(requestDocument({ visibleFrom: undefined }));
      const context = routeContext();

      await getPublicRequestDetail(context.req, context.res, context.next);

      expect(context.status).not.toHaveBeenCalled();
      expect(context.json).toHaveBeenCalledWith(
        expect.objectContaining({
          request: expect.objectContaining({ vendor: "Campus Market" }),
        })
      );
    });

    it("withholds a future request from notification and deep-link resolution", async () => {
      // `GET /api/request/:id` is what a helper-notification tap and a shared
      // link both resolve against. Whatever produced the id, the answer before
      // the start is the same authoritative nothing.
      vi.setSystemTime(new Date(visibleFrom.getTime() - 60 * 60 * 1000));
      mockFindById(futureRequest());
      const context = routeContext();

      await getPublicRequestDetail(context.req, context.res, context.next);

      expect(context.status).toHaveBeenCalledWith(409);
      expect(context.json).not.toHaveBeenCalledWith(
        expect.objectContaining({ request: expect.anything() })
      );
    });

    it("withholds it whatever its persisted status is, and never reports it as open", async () => {
      vi.setSystemTime(new Date(visibleFrom.getTime() - 1));

      for (const status of ["open", "claimed", "placed"]) {
        mockFindById(futureRequest({ status }));
        const context = routeContext();

        await getPublicRequestDetail(context.req, context.res, context.next);

        expect(context.status).toHaveBeenCalledWith(409);
        expect(context.json).not.toHaveBeenCalledWith(
          expect.objectContaining({
            request: expect.objectContaining({ status: "open" }),
          })
        );
      }
    });

    it("uses the same code and sentence the claim route answers with", async () => {
      // One situation, one answer. A helper who taps through and a helper who
      // presses Claim must not be told two different things.
      vi.setSystemTime(new Date(visibleFrom.getTime() - 1));
      mockFindById(futureRequest());
      const context = routeContext();

      await getPublicRequestDetail(context.req, context.res, context.next);

      const body = (
        context.status.mock.results[0].value as { json: typeof context.json }
      ).json.mock.calls[0][0] as { error: { code: string; message: string } };
      expect(body.error.code).toBe(REQUEST_NOT_YET_AVAILABLE_CODE);
      expect(body.error.message).toBe(REQUEST_NOT_YET_AVAILABLE_MESSAGE);
    });
  });

  it("preserves the existing invalid-id response", async () => {
    const context = routeContext("not-an-object-id");

    await getPublicRequestDetail(context.req, context.res, context.next);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(
      (context.status.mock.results[0].value as { json: typeof context.json })
        .json
    ).toHaveBeenCalledWith({ error: "Invalid request id" });
    expect(context.next).not.toHaveBeenCalled();
  });

  it("preserves error delegation to the repository error handler", async () => {
    const databaseError = new Error("database unavailable");
    vi.spyOn(MealRequest, "findById").mockReturnValue({
      select: () => ({
        lean: () => ({
          exec: vi.fn().mockRejectedValue(databaseError),
        }),
      }),
    } as unknown as ReturnType<typeof MealRequest.findById>);
    const context = routeContext();

    await getPublicRequestDetail(context.req, context.res, context.next);

    expect(context.next).toHaveBeenCalledWith(databaseError);
    expect(context.status).not.toHaveBeenCalled();
    expect(context.json).not.toHaveBeenCalled();
  });

  describe("W3-H2 stale detail Reserve truth", () => {
    const participantSecretText = "request-detail-participation-unit-secret";
    const participantSecret = Buffer.from(participantSecretText);
    const participantId = new mongoose.Types.ObjectId(
      "64f0000000000000000000c7"
    );
    const participantAuthority = signParticipantAuthority(
      participantId,
      1,
      participantSecret
    );

    beforeEach(() => {
      vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
    });

    afterEach(() => {
      vi.unstubAllEnvs();
    });

    function stubVerifiedParticipant() {
      return vi.spyOn(Participant, "findOne").mockReturnValue({
        select: () => ({
          lean: () => ({
            exec: vi.fn().mockResolvedValue({
              _id: participantId,
              email: "already-participated@nyu.edu",
            }),
          }),
        }),
      } as unknown as ReturnType<typeof Participant.findOne>);
    }

    it("degrades to the ordinary public response when no credential is presented, exposing no new field", async () => {
      mockFindById(requestDocument());
      const context = routeContext();

      await getPublicRequestDetail(context.req, context.res, context.next);

      const body = context.json.mock.calls[0][0] as Record<string, unknown>;
      expect(Object.keys(body)).toEqual(["request"]);
    });

    it("adds alreadyParticipated: true when the verified caller already holds a participation record for this exact request", async () => {
      stubVerifiedParticipant();
      vi.spyOn(RequestParticipation, "find").mockReturnValue({
        select: () => ({
          lean: () => ({
            exec: vi.fn().mockResolvedValue([
              { requestId: new mongoose.Types.ObjectId("64b000000000000000000001") },
            ]),
          }),
        }),
      } as unknown as ReturnType<typeof RequestParticipation.find>);
      mockFindById(requestDocument());
      const context = routeContext("64b000000000000000000001", {
        [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
      });

      await getPublicRequestDetail(context.req, context.res, context.next);

      const body = context.json.mock.calls[0][0] as Record<string, unknown>;
      expect(body.alreadyParticipated).toBe(true);
      expect(body.request).toEqual(
        expect.objectContaining({ id: "64b000000000000000000001" })
      );
    });

    it("omits alreadyParticipated for a verified caller who has never participated in this request", async () => {
      stubVerifiedParticipant();
      vi.spyOn(RequestParticipation, "find").mockReturnValue({
        select: () => ({
          lean: () => ({ exec: vi.fn().mockResolvedValue([]) }),
        }),
      } as unknown as ReturnType<typeof RequestParticipation.find>);
      mockFindById(requestDocument());
      const context = routeContext("64b000000000000000000001", {
        [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
      });

      await getPublicRequestDetail(context.req, context.res, context.next);

      const body = context.json.mock.calls[0][0] as Record<string, unknown>;
      expect(body).not.toHaveProperty("alreadyParticipated");
    });

    it("omits alreadyParticipated, never refusing the read, when the presented credential cannot be verified", async () => {
      const query = vi.spyOn(RequestParticipation, "find");
      mockFindById(requestDocument());
      const context = routeContext("64b000000000000000000001", {
        [PARTICIPANT_AUTHORITY_HEADER]: "not-a-real-credential",
      });

      await getPublicRequestDetail(context.req, context.res, context.next);

      const body = context.json.mock.calls[0][0] as Record<string, unknown>;
      expect(body).not.toHaveProperty("alreadyParticipated");
      expect(query).not.toHaveBeenCalled();
    });
  });

  describe("W3-H2 caller-specific cache/privacy headers", () => {
    const participantSecretText = "request-detail-cache-header-unit-secret";
    const participantSecret = Buffer.from(participantSecretText);
    const participantId = new mongoose.Types.ObjectId(
      "64f0000000000000000000d8"
    );
    const participantAuthority = signParticipantAuthority(
      participantId,
      1,
      participantSecret
    );

    beforeEach(() => {
      vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
    });

    afterEach(() => {
      vi.unstubAllEnvs();
    });

    function stubVerifiedParticipant() {
      return vi.spyOn(Participant, "findOne").mockReturnValue({
        select: () => ({
          lean: () => ({
            exec: vi.fn().mockResolvedValue({
              _id: participantId,
              email: "cache-header@nyu.edu",
            }),
          }),
        }),
      } as unknown as ReturnType<typeof Participant.findOne>);
    }

    function expectPrivateNoStore(context: ReturnType<typeof routeContext>) {
      expect(context.setHeaders["Cache-Control"]).toBe("private, no-store");
      expect(context.setHeaders["Vary"]).toBe(PARTICIPANT_AUTHORITY_HEADER);
    }

    it("sets private, no-store and Vary on the ordinary anonymous response", async () => {
      mockFindById(requestDocument());
      const context = routeContext();

      await getPublicRequestDetail(context.req, context.res, context.next);

      expectPrivateNoStore(context);
    });

    it("sets the same headers on a participant-aware alreadyParticipated response", async () => {
      stubVerifiedParticipant();
      vi.spyOn(RequestParticipation, "find").mockReturnValue({
        select: () => ({
          lean: () => ({
            exec: vi.fn().mockResolvedValue([
              { requestId: new mongoose.Types.ObjectId("64b000000000000000000001") },
            ]),
          }),
        }),
      } as unknown as ReturnType<typeof RequestParticipation.find>);
      mockFindById(requestDocument());
      const context = routeContext("64b000000000000000000001", {
        [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
      });

      await getPublicRequestDetail(context.req, context.res, context.next);

      expectPrivateNoStore(context);
    });

    it("sets the same headers when the presented credential is unusable", async () => {
      mockFindById(requestDocument());
      const context = routeContext("64b000000000000000000001", {
        [PARTICIPANT_AUTHORITY_HEADER]: "not-a-real-credential",
      });

      await getPublicRequestDetail(context.req, context.res, context.next);

      expectPrivateNoStore(context);
    });

    it("sets the same headers on the invalid-id refusal", async () => {
      const context = routeContext("not-an-object-id");

      await getPublicRequestDetail(context.req, context.res, context.next);

      expectPrivateNoStore(context);
    });

    it("sets the same headers on the not-found refusal", async () => {
      mockFindById(null);
      const context = routeContext();

      await getPublicRequestDetail(context.req, context.res, context.next);

      expectPrivateNoStore(context);
    });

    it("sets the same headers on the not-yet-available refusal", async () => {
      const visibleFrom = new Date("2026-07-26T20:00:00.000Z");
      vi.useFakeTimers({ toFake: ["Date"] });
      vi.setSystemTime(new Date(visibleFrom.getTime() - 1));
      mockFindById(
        requestDocument({
          status: "open",
          visibleFrom,
          windowStart: visibleFrom,
          windowEnd: new Date("2026-07-26T23:00:00.000Z"),
          expiresAt: new Date("2026-07-26T23:00:00.000Z"),
          claimExpiresAt: null,
        })
      );
      const context = routeContext();

      await getPublicRequestDetail(context.req, context.res, context.next);
      vi.useRealTimers();

      expectPrivateNoStore(context);
    });

    it("sets the same headers before an error is delegated to the shared handler", async () => {
      vi.spyOn(MealRequest, "findById").mockReturnValue({
        select: () => ({
          lean: () => ({
            exec: vi.fn().mockRejectedValue(new Error("database unavailable")),
          }),
        }),
      } as unknown as ReturnType<typeof MealRequest.findById>);
      const context = routeContext();

      await getPublicRequestDetail(context.req, context.res, context.next);

      expectPrivateNoStore(context);
      expect(context.next).toHaveBeenCalled();
    });

    it("P and Q receive isolated responses and neither exposes participant id, email, or participation rows", async () => {
      // P has participated; Q has not. Both must be told only their own
      // truth, and neither response may leak identity/participation
      // internals regardless of which is true.
      const qParticipantId = new mongoose.Types.ObjectId(
        "64f0000000000000000000d9"
      );
      const qAuthority = signParticipantAuthority(
        qParticipantId,
        1,
        participantSecret
      );

      const findOne = vi.spyOn(Participant, "findOne");
      findOne.mockImplementation(((filter: { _id?: unknown }) => ({
        select: () => ({
          lean: () => ({
            exec: vi.fn().mockResolvedValue(
              String(filter?._id) === String(participantId)
                ? { _id: participantId, email: "cache-header@nyu.edu" }
                : { _id: qParticipantId, email: "q-cache-header@nyu.edu" }
            ),
          }),
        }),
      })) as unknown as typeof Participant.findOne);

      vi.spyOn(RequestParticipation, "find").mockImplementation(
        ((filter: { participantId?: unknown }) => ({
          select: () => ({
            lean: () => ({
              exec: vi.fn().mockResolvedValue(
                String(filter?.participantId) === String(participantId)
                  ? [{ requestId: new mongoose.Types.ObjectId("64b000000000000000000001") }]
                  : []
              ),
            }),
          }),
        })) as unknown as typeof RequestParticipation.find
      );
      mockFindById(requestDocument());

      const pContext = routeContext("64b000000000000000000001", {
        [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
      });
      await getPublicRequestDetail(pContext.req, pContext.res, pContext.next);
      const pBody = pContext.json.mock.calls[0][0] as Record<string, unknown>;
      expect(pBody.alreadyParticipated).toBe(true);

      const qContext = routeContext("64b000000000000000000001", {
        [PARTICIPANT_AUTHORITY_HEADER]: qAuthority,
      });
      await getPublicRequestDetail(qContext.req, qContext.res, qContext.next);
      const qBody = qContext.json.mock.calls[0][0] as Record<string, unknown>;
      expect(qBody).not.toHaveProperty("alreadyParticipated");

      const anonymousContext = routeContext("64b000000000000000000001", {});
      await getPublicRequestDetail(
        anonymousContext.req,
        anonymousContext.res,
        anonymousContext.next
      );
      const anonymousBody = anonymousContext.json.mock.calls[0][0] as Record<
        string,
        unknown
      >;
      expect(anonymousBody).not.toHaveProperty("alreadyParticipated");

      for (const body of [pBody, qBody, anonymousBody]) {
        const serialized = JSON.stringify(body);
        expect(serialized).not.toMatch(
          /participantId|email|claimToken|pickupName/
        );
      }
    });
  });
});
