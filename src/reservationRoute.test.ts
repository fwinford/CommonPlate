import type { Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  Participant,
  ParticipantBlock,
  Request as MealRequest,
} from "../models/db.js";
import {
  PARTICIPANT_AUTHORITY_HEADER,
  PARTICIPANT_VERIFICATION_REQUIRED_CODE,
} from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import { getActiveReservation } from "./reservationRoute.js";

const now = new Date("2026-08-01T12:00:00.000Z");
const helperParticipantId = new mongoose.Types.ObjectId(
  "64f0000000000000000000e1"
);
const helperPrincipal = "reservation-unit-helper@nyu.edu";
const participantSecretText = "reservation-route-unit-test-secret";
const participantSecret = Buffer.from(participantSecretText);
const participantAuthority = signParticipantAuthority(
  helperParticipantId,
  1,
  participantSecret
);

function routeContext(
  headers: Record<string, string | string[]> = {
    [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
  }
) {
  const req = { headers } as unknown as Request;
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

function stubVerifiedParticipant() {
  return vi.spyOn(Participant, "findOne").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi
          .fn()
          .mockResolvedValue({ _id: helperParticipantId, email: helperPrincipal }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findOne>);
}

/**
 * The placed-result read requests the private W4-U1.1 suppression marker with
 * `.select("+contactMessageSuppressed")`, so every double here supports both
 * the bare `.lean()` chain (the active-claim read) and the `.select().lean()`
 * chain. Each selection is recorded on the returned spy for assertions.
 */
function queryDouble(exec: ReturnType<typeof vi.fn>) {
  const select = vi.fn();
  const chain = { lean: () => ({ exec }), select };
  select.mockReturnValue(chain);
  return { chain, select };
}

function mockActiveReservationResult(result: unknown) {
  const { chain, select } = queryDouble(vi.fn().mockResolvedValue(result));
  const spy = vi
    .spyOn(MealRequest, "findOne")
    .mockReturnValue(chain as unknown as ReturnType<typeof MealRequest.findOne>);
  return Object.assign(spy, { select });
}

/**
 * `getActiveReservation` issues up to two `MealRequest.findOne` calls in
 * sequence (W3-H2): the active-claim read first, then — only when that
 * resolves null — the placement re-entry read. This models exactly that
 * sequence so a placement case does not have to reuse the active-claim
 * result for both.
 */
function mockSequentialActiveReservationResults(...results: unknown[]) {
  const exec = vi.fn();
  results.forEach((result) => {
    exec.mockResolvedValueOnce(result);
  });
  const { chain, select } = queryDouble(exec);
  const spy = vi
    .spyOn(MealRequest, "findOne")
    .mockReturnValue(chain as unknown as ReturnType<typeof MealRequest.findOne>);
  return Object.assign(spy, { select });
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(now);
  vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
  stubVerifiedParticipant();
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
  vi.unstubAllEnvs();
});

describe("GET /api/participant/active-reservation", () => {
  it("requires a verified participant before any database read", async () => {
    const query = vi.spyOn(MealRequest, "findOne");
    const context = routeContext({});

    await getActiveReservation(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(responseBody(context).error.code).toBe(
      PARTICIPANT_VERIFICATION_REQUIRED_CODE
    );
    expect(query).not.toHaveBeenCalled();
  });

  it("resolves the caller's own active reservation by helperParticipantId, never by any submitted id", async () => {
    const requestId = new mongoose.Types.ObjectId("64f0000000000000000000f2");
    const claimExpiresAt = new Date(now.getTime() + 10 * 60 * 1000);
    const query = mockActiveReservationResult({
      _id: requestId,
      vendor: "Campus Market",
      food: "Vegetable rice bowl",
      pickupWindowText: "ASAP",
      pickupName: "Private Pickup Name",
      windowStart: null,
      windowEnd: null,
      status: "claimed",
      createdAt: new Date(now.getTime() - 5 * 60 * 1000),
      expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
      claimExpiresAt,
      claimExtendedAt: null,
    });
    const context = routeContext();

    await getActiveReservation(context.req, context.res);

    const [filter] = query.mock.calls[0] as any[];
    expect(filter).toEqual({
      helperParticipantId,
      status: "claimed",
      claimExpiresAt: { $gt: now },
    });
    const body = responseBody(context);
    expect(body.reservation.request.id).toBe(String(requestId));
    // W4-R4: pickup name is gone from the request contract, so an active
    // reservation no longer republishes one.
    expect(body.reservation).not.toHaveProperty("pickupName");
    expect(JSON.stringify(body)).not.toMatch(/Private Pickup/);
    expect(body.reservation.claimExpiresAt).toEqual(claimExpiresAt);
    expect(body.reservation.claimExtendedAt).toBeNull();
    // The raw claim token was never persisted, so it can never appear here.
    expect(JSON.stringify(body)).not.toMatch(/claimToken/);
    // An active reservation always takes priority; the placement re-entry
    // read never even runs.
    expect(body.placement).toBeNull();
  });

  describe("W4-U1.3 post-Yes Stop destination signal (C3)", () => {
    const requesterParticipantId = new mongoose.Types.ObjectId(
      "64f0000000000000000000b7"
    );

    function heldReservation(extra: Record<string, unknown>) {
      return {
        _id: new mongoose.Types.ObjectId("64f0000000000000000000f3"),
        vendor: "Palladium",
        food: "Rice bowl",
        pickupWindowText: "ASAP",
        windowStart: null,
        windowEnd: null,
        status: "claimed",
        createdAt: new Date(now.getTime() - 5 * 60 * 1000),
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        claimExpiresAt: new Date(now.getTime() + 10 * 60 * 1000),
        claimExtendedAt: null,
        requesterParticipantId,
        ...extra,
      };
    }

    function stubPairFence(fenced: boolean) {
      return vi.spyOn(ParticipantBlock, "findOne").mockReturnValue({
        lean: () => ({
          exec: vi.fn().mockResolvedValue(fenced ? { _id: "row" } : null),
        }),
      } as unknown as ReturnType<typeof ParticipantBlock.findOne>);
    }

    async function read(document: unknown, fenced: boolean) {
      const query = mockActiveReservationResult(document);
      stubPairFence(fenced);
      const context = routeContext();
      await getActiveReservation(context.req, context.res);
      return { body: responseBody(context), query };
    }

    it("reads the private authority on the live-reservation read only", async () => {
      const { query } = await read(heldReservation({}), false);
      expect(query.select).toHaveBeenCalledWith(
        "+requesterParticipantId +externalOrderAffirmed"
      );
    });

    it("reports only the Stop consequence, affirmatively, when the authority exists and no pair restriction remains", async () => {
      const { body } = await read(
        heldReservation({ externalOrderAffirmed: true }),
        false
      );
      expect(body.reservation.stopReturnsHome).toBe(true);
      expect(body.reservation).not.toHaveProperty("directContactRestricted");
      expect(JSON.stringify(body)).not.toMatch(/affirmed|ParticipantId|block/i);
      expect(body.reservation.request).not.toHaveProperty("stopReturnsHome");
    });

    it("never reports it while a pair restriction remains, so the restricted read is the same with or without the authority", async () => {
      const marked = await read(
        heldReservation({ externalOrderAffirmed: true }),
        true
      );
      vi.restoreAllMocks();
      stubVerifiedParticipant();
      const unmarked = await read(heldReservation({}), true);

      expect(marked.body.reservation).not.toHaveProperty("stopReturnsHome");
      expect(marked.body.reservation.directContactRestricted).toBe(true);
      expect(marked.body).toEqual(unmarked.body);
    });

    it("omits it entirely, never false, for an ordinary reservation", async () => {
      const { body } = await read(heldReservation({}), false);
      expect(Object.keys(body.reservation).sort()).toEqual([
        "claimExpiresAt",
        "claimExtendedAt",
        "request",
      ]);
    });
  });

  it("resolves both null when the verified helper holds neither an active reservation nor a placed request", async () => {
    mockActiveReservationResult(null);
    const context = routeContext();

    await getActiveReservation(context.req, context.res);

    expect(responseBody(context)).toEqual({ reservation: null, placement: null });
  });

  describe("W3-H2 fulfillment re-entry", () => {
    it("reports the most recently placed still-existing request when no active reservation exists", async () => {
      const placedRequestId = new mongoose.Types.ObjectId(
        "64f0000000000000000000f3"
      );
      const query = mockSequentialActiveReservationResults(null, {
        _id: placedRequestId,
        vendor: "Campus Market",
        food: "Vegetable rice bowl",
        pickupWindowText: "ASAP",
        mealSwipes: 3,
        windowStart: null,
        windowEnd: null,
        status: "placed",
        createdAt: new Date(now.getTime() - 30 * 60 * 1000),
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        placedAt: new Date(now.getTime() - 5 * 60 * 1000),
        notificationStatus: "sent",
      });
      const context = routeContext();

      await getActiveReservation(context.req, context.res);

      expect(query).toHaveBeenCalledTimes(2);
      const [placedFilter, , placedOptions] = query.mock.calls[1] as any[];
      expect(placedFilter).toEqual({
        helperParticipantId,
        status: "placed",
        deleteAt: { $gt: now },
      });
      expect(placedOptions).toEqual({ sort: { placedAt: -1 } });

      const body = responseBody(context);
      expect(body.reservation).toBeNull();
      expect(body.placement.request.id).toBe(String(placedRequestId));
      expect(body.placement.request.status).toBe("placed");
      expect(body.placement.notification).toEqual({ status: "sent" });
      // Never a path to reservation authority or another external order:
      // no claim-private field of any kind appears in this read.
      expect(JSON.stringify(body)).not.toMatch(
        /pickupName|claimToken|claimExpiresAt/
      );
    });

    it("reports an unknown notification outcome as null rather than guessing", async () => {
      mockSequentialActiveReservationResults(null, {
        _id: new mongoose.Types.ObjectId("64f0000000000000000000f4"),
        vendor: "Campus Market",
        food: "Vegetable rice bowl",
        pickupWindowText: "ASAP",
        mealSwipes: 2,
        windowStart: null,
        windowEnd: null,
        status: "placed",
        createdAt: new Date(now.getTime() - 30 * 60 * 1000),
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        placedAt: new Date(now.getTime() - 5 * 60 * 1000),
        notificationStatus: "pending",
      });
      const context = routeContext();

      await getActiveReservation(context.req, context.res);

      expect(responseBody(context).placement.notification).toBeNull();
    });

    describe("W4-U1.1 content-free Message-suppression marker", () => {
      const placedFixture = {
        vendor: "Campus Market",
        food: "Vegetable rice bowl",
        pickupWindowText: "ASAP",
        mealSwipes: 2,
        windowStart: null,
        windowEnd: null,
        status: "placed",
        createdAt: new Date(now.getTime() - 30 * 60 * 1000),
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
        placedAt: new Date(now.getTime() - 5 * 60 * 1000),
        notificationStatus: "sent",
      };

      it("requests the private marker only on the participant-scoped placed read", async () => {
        const query = mockSequentialActiveReservationResults(null, {
          _id: new mongoose.Types.ObjectId("64f0000000000000000000f5"),
          ...placedFixture,
        });
        const context = routeContext();

        await getActiveReservation(context.req, context.res);

        // The active-claim read (first) never selects the Message markers — it
        // selects only the requester binding and the post-Yes authority
        // (W4-U1.3), to answer whether direct contact is restricted and where a
        // Stop ends; the placed read selects both content-free Message markers
        // and never the post-Yes authority.
        expect(query.select).toHaveBeenCalledTimes(2);
        expect(query.select).toHaveBeenNthCalledWith(
          1,
          "+requesterParticipantId +externalOrderAffirmed"
        );
        expect(query.select).toHaveBeenNthCalledWith(
          2,
          "+contactMessageSuppressed +contactMessageWithheld"
        );
      });

      it("reports messageSuppressed: true when the durable marker proves suppression at placement", async () => {
        mockSequentialActiveReservationResults(null, {
          _id: new mongoose.Types.ObjectId("64f0000000000000000000f6"),
          ...placedFixture,
          contactMessageSuppressed: true,
        });
        const context = routeContext();

        await getActiveReservation(context.req, context.res);

        const body = responseBody(context);
        expect(body.placement.messageSuppressed).toBe(true);
        expect(body.placement.request.status).toBe("placed");
        expect(body.placement.notification).toEqual({ status: "sent" });
      });

      it("omits the field entirely, never false, when suppression is not established", async () => {
        for (const marker of [undefined, false, null, "true", 1]) {
          vi.restoreAllMocks();
          stubVerifiedParticipant();
          mockSequentialActiveReservationResults(null, {
            _id: new mongoose.Types.ObjectId("64f0000000000000000000f7"),
            ...placedFixture,
            ...(marker === undefined ? {} : { contactMessageSuppressed: marker }),
          });
          const context = routeContext();

          await getActiveReservation(context.req, context.res);

          const body = responseBody(context);
          expect(Object.keys(body.placement).sort()).toEqual([
            "notification",
            "request",
          ]);
          expect(JSON.stringify(body)).not.toMatch(/messageSuppressed|contactMessage/);
        }
      });

      it("never places the marker inside the public request projection", async () => {
        mockSequentialActiveReservationResults(null, {
          _id: new mongoose.Types.ObjectId("64f0000000000000000000f8"),
          ...placedFixture,
          contactMessageSuppressed: true,
        });
        const context = routeContext();

        await getActiveReservation(context.req, context.res);

        const body = responseBody(context);
        expect(body.placement.request).not.toHaveProperty("messageSuppressed");
        expect(body.placement.request).not.toHaveProperty("contactMessageSuppressed");
        expect(body.reservation).toBeNull();
      });
    });

    it("resolves null placement when this participant has never placed a still-existing request", async () => {
      const query = mockSequentialActiveReservationResults(null, null);
      const context = routeContext();

      await getActiveReservation(context.req, context.res);

      expect(query).toHaveBeenCalledTimes(2);
      expect(responseBody(context)).toEqual({
        reservation: null,
        placement: null,
      });
    });
  });

  it("answers 503 without leaking detail when the lookup fails", async () => {
    const { chain } = queryDouble(
      vi.fn().mockRejectedValue(new Error("connection reset"))
    );
    vi.spyOn(MealRequest, "findOne").mockReturnValue(
      chain as unknown as ReturnType<typeof MealRequest.findOne>
    );
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    const context = routeContext();

    await getActiveReservation(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(503);
    expect(JSON.stringify(consoleError.mock.calls)).not.toMatch(
      /connection reset/
    );
  });
});
