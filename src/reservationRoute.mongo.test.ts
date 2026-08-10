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
import { Participant, Request as MealRequest } from "../models/db.js";
import { getActiveReservation } from "./reservationRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";

function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  const database = uri.pathname.replace(/^\//, "") || "commonplate";
  uri.pathname = `${database}_reservation`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

const participantSecretText = "reservation-mongo-participant-secret-32b";
const participantSecret = Buffer.from(participantSecretText);
const helperParticipantId = new mongoose.Types.ObjectId(
  "64e0000000000000000000d1"
);
const helperPrincipal = "reservation-mongo-helper@nyu.edu";
const participantAuthority = signParticipantAuthority(
  helperParticipantId,
  1,
  participantSecret
);

function routeContext(authority: string | null = participantAuthority) {
  const req = {
    headers: authority
      ? { [PARTICIPANT_AUTHORITY_HEADER]: authority }
      : {},
  } as unknown as Request;
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

describeMongo("real MongoDB active-reservation continuation (W3-H1)", () => {
  beforeAll(async () => {
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
    await mongoose.connect(mongoUri!);
    await MealRequest.syncIndexes();
    await Participant.createIndexes();
    await Participant.updateOne(
      { _id: helperParticipantId },
      {
        $set: { email: helperPrincipal, verifiedAt: new Date() },
        $setOnInsert: { authorityVersion: 1 },
      },
      { upsert: true }
    ).exec();
  });

  afterEach(async () => {
    await MealRequest.deleteMany({});
  });

  afterAll(async () => {
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  it("resolves nothing for a verified helper with no active reservation", async () => {
    const context = routeContext();

    await getActiveReservation(context.req, context.res);

    expect(context.statusCode).toBe(200);
    expect(context.body).toEqual({ reservation: null });
  });

  it("resolves the active reservation bound to the verified helper, without a raw claim token", async () => {
    const now = new Date();
    const claimExpiresAt = new Date(now.getTime() + 10 * 60 * 1000);
    const request = await MealRequest.create({
      vendor: "Continuation Cafe",
      food: "Noodle bowl",
      pickupName: "Continuation Pickup",
      pickupWindowText: "ASAP",
      email: "requester@example.edu",
      status: "claimed",
      expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
      deleteAt: new Date(now.getTime() + 60 * 60 * 1000),
      claimedAt: now,
      claimExpiresAt,
      claimTokenDigest: "c".repeat(64),
      helperParticipantId,
    });

    const context = routeContext();
    await getActiveReservation(context.req, context.res);

    expect(context.statusCode).toBe(200);
    expect(context.body.reservation.request.id).toBe(String(request._id));
    expect(context.body.reservation.pickupName).toBe("Continuation Pickup");
    expect(new Date(context.body.reservation.claimExpiresAt)).toEqual(
      claimExpiresAt
    );
    expect(context.body.reservation.claimExtendedAt).toBeNull();
    // Never persisted, so it can never be handed back either.
    expect(JSON.stringify(context.body)).not.toMatch(/claimToken/);
  });

  it("resolves nothing once the reservation has expired", async () => {
    const now = new Date();
    await MealRequest.create({
      vendor: "Continuation Cafe",
      food: "Noodle bowl",
      pickupName: "Lapsed Pickup",
      pickupWindowText: "ASAP",
      email: "requester@example.edu",
      status: "claimed",
      expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
      deleteAt: new Date(now.getTime() + 60 * 60 * 1000),
      claimedAt: new Date(now.getTime() - 20 * 60 * 1000),
      claimExpiresAt: new Date(now.getTime() - 60 * 1000),
      claimTokenDigest: "d".repeat(64),
      helperParticipantId,
    });

    const context = routeContext();
    await getActiveReservation(context.req, context.res);

    expect(context.body).toEqual({ reservation: null });
  });

  it("requires participant verification", async () => {
    const context = routeContext(null);

    await getActiveReservation(context.req, context.res);

    expect(context.statusCode).toBe(401);
  });
});
