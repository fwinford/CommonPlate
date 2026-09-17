import type { Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Participant, Request as MealRequest } from "../models/db.js";
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

function mockActiveReservationResult(result: unknown) {
  return vi.spyOn(MealRequest, "findOne").mockReturnValue({
    lean: () => ({
      exec: vi.fn().mockResolvedValue(result),
    }),
  } as unknown as ReturnType<typeof MealRequest.findOne>);
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
  return vi.spyOn(MealRequest, "findOne").mockReturnValue({
    lean: () => ({ exec }),
  } as unknown as ReturnType<typeof MealRequest.findOne>);
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
    vi.spyOn(MealRequest, "findOne").mockReturnValue({
      lean: () => ({
        exec: vi.fn().mockRejectedValue(new Error("connection reset")),
      }),
    } as unknown as ReturnType<typeof MealRequest.findOne>);
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    const context = routeContext();

    await getActiveReservation(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(503);
    expect(JSON.stringify(consoleError.mock.calls)).not.toMatch(
      /connection reset/
    );
  });
});
