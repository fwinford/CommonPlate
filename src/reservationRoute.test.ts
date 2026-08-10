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
    expect(body.reservation.pickupName).toBe("Private Pickup Name");
    expect(body.reservation.claimExpiresAt).toEqual(claimExpiresAt);
    expect(body.reservation.claimExtendedAt).toBeNull();
    // The raw claim token was never persisted, so it can never appear here.
    expect(JSON.stringify(body)).not.toMatch(/claimToken/);
  });

  it("resolves null when the verified helper holds no active reservation", async () => {
    mockActiveReservationResult(null);
    const context = routeContext();

    await getActiveReservation(context.req, context.res);

    expect(responseBody(context)).toEqual({ reservation: null });
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
