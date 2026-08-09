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
import {
  CLAIM_EXTENSION_MS,
  claimRequest,
  extendClaim,
} from "./claimRoute.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";

const mongoUri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = mongoUri ? describe : describe.skip;

/**
 * A real verified helper, in the real collection, presenting a real credential
 * (W3-I1). The concurrency claims below are about the claim mutation, so the
 * gate in front of it has to be the production one rather than a stub.
 *
 * Its own address and id, and never deleted between cases: this suite shares
 * the runner's default database with the fulfillment suite, and the unique
 * address index would otherwise let one suite's cleanup break the other's.
 */
const participantSecretText = "claim-mongo-participant-signing-secret-32";
const participantSecret = Buffer.from(participantSecretText);
const helperParticipantId = new mongoose.Types.ObjectId(
  "64d0000000000000000000c1"
);
const helperPrincipal = "claim-mongo-helper@nyu.edu";
const participantAuthority = signParticipantAuthority(
  helperParticipantId,
  1,
  participantSecret
);

async function ensureVerifiedHelper() {
  await Participant.updateOne(
    { _id: helperParticipantId },
    {
      $set: { email: helperPrincipal, verifiedAt: new Date() },
      $setOnInsert: { authorityVersion: 1 },
    },
    { upsert: true }
  ).exec();
}

function routeContext(id: string, body?: unknown) {
  const req = {
    params: { id },
    body,
    headers: { [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority },
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

describeMongo("real MongoDB claim atomicity", () => {
  beforeAll(async () => {
    vi.stubEnv(
      "CLAIM_TOKEN_HMAC_SECRET",
      "real-mongo-test-secret-material-32-bytes"
    );
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
    await mongoose.connect(mongoUri!);
    await MealRequest.syncIndexes();
    await Participant.createIndexes();
    await ensureVerifiedHelper();
  });

  afterEach(async () => {
    await MealRequest.deleteMany({});
  });

  afterAll(async () => {
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  async function createClaimableRequest() {
    const now = new Date();
    const deadline = new Date(now.getTime() + 60 * 60 * 1000);
    return await MealRequest.create({
      vendor: "Concurrency Cafe",
      food: "Rice bowl",
      pickupName: "Only Winner Sees This",
      pickupWindowText: "ASAP",
      email: "requester@example.edu",
      status: "open",
      expiresAt: deadline,
      deleteAt: deadline,
    });
  }

  it("creates only the deleteAt TTL index", async () => {
    const indexes = await MealRequest.collection.indexes();
    const ttlIndexes = indexes.filter(
      (index) => index.expireAfterSeconds !== undefined
    );

    expect(ttlIndexes).toEqual([
      expect.objectContaining({
        name: "request_deleteAt_ttl",
        key: { deleteAt: 1 },
        expireAfterSeconds: 0,
      }),
    ]);
    expect(indexes).not.toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          key: { expiresAt: 1 },
          expireAfterSeconds: 0,
        }),
      ])
    );
  });

  it("allows exactly one concurrent claim and issues claimant data only once", async () => {
    const request = await createClaimableRequest();
    const attempts = [
      routeContext(String(request._id)),
      routeContext(String(request._id)),
    ];

    await Promise.all(
      attempts.map((attempt) => claimRequest(attempt.req, attempt.res))
    );

    const winners = attempts.filter(
      (attempt) => attempt.statusCode === 200 && attempt.body?.claim
    );
    const losers = attempts.filter(
      (attempt) =>
        attempt.statusCode === 409 &&
        attempt.body?.error?.code === "REQUEST_ALREADY_CLAIMED"
    );
    expect(winners).toHaveLength(1);
    expect(losers).toHaveLength(1);
    expect(winners[0].body.claim.claimToken).toMatch(
      /^[A-Za-z0-9_-]{43}$/
    );
    expect(winners[0].body.claim.pickupName).toBe(
      "Only Winner Sees This"
    );
    expect(JSON.stringify(losers[0].body)).not.toMatch(
      /pickupName|claimToken|Only Winner/
    );

    const stored = await MealRequest.collection.findOne({
      // Raw-driver boundary: mongoose types `_id` as `unknown`, while the
      // driver's filter expects an ObjectId.
      _id: request._id as mongoose.Types.ObjectId,
    });
    expect(stored?.status).toBe("claimed");
    expect(stored?.claimTokenDigest).toMatch(/^[a-f0-9]{64}$/);
    expect(stored?.claimTokenDigest).not.toBe(
      winners[0].body.claim.claimToken
    );
    expect(stored).not.toHaveProperty("claimToken");
  });

  it("allows exactly one of two concurrent extension attempts", async () => {
    const request = await createClaimableRequest();
    const claim = routeContext(String(request._id));
    await claimRequest(claim.req, claim.res);
    expect(claim.statusCode).toBe(200);
    const rawToken = claim.body.claim.claimToken as string;
    const originalExpiration = new Date(
      claim.body.claim.claimExpiresAt
    ).getTime();

    const attempts = [
      routeContext(String(request._id), { claimToken: rawToken }),
      routeContext(String(request._id), { claimToken: rawToken }),
    ];
    await Promise.all(
      attempts.map((attempt) => extendClaim(attempt.req, attempt.res))
    );

    const winners = attempts.filter(
      (attempt) => attempt.statusCode === 200 && attempt.body?.claim
    );
    const losers = attempts.filter(
      (attempt) =>
        attempt.statusCode === 409 &&
        attempt.body?.error?.code === "CLAIM_EXTENSION_ALREADY_USED"
    );
    expect(winners).toHaveLength(1);
    expect(losers).toHaveLength(1);
    expect(
      new Date(winners[0].body.claim.claimExpiresAt).getTime()
    ).toBe(originalExpiration + CLAIM_EXTENSION_MS);
    expect(JSON.stringify(winners[0].body)).not.toMatch(
      /claimToken|pickupName|request/
    );
    expect(JSON.stringify(losers[0].body)).not.toMatch(
      /claimToken|pickupName/
    );
  });

  it("caps a new claim at the original request expiration", async () => {
    const claimInstant = new Date();
    const deadline = new Date(claimInstant.getTime() + 7 * 60 * 1000);
    const request = await MealRequest.create({
      vendor: "Short Window Cafe",
      food: "Soup",
      pickupName: "Short Window Winner",
      pickupWindowText: "ASAP",
      email: "requester@example.edu",
      status: "open",
      expiresAt: deadline,
      deleteAt: deadline,
    });
    const claim = routeContext(String(request._id));

    await claimRequest(claim.req, claim.res);

    expect(claim.statusCode).toBe(200);
    expect(new Date(claim.body.claim.claimExpiresAt)).toEqual(deadline);
  });

  it("atomically replaces an expired claim and resets one-time extension state", async () => {
    const mutationInstant = new Date();
    const deadline = new Date(mutationInstant.getTime() + 60 * 60 * 1000);
    const oldDigest = "a".repeat(64);
    const request = await MealRequest.create({
      vendor: "Replacement Cafe",
      food: "Salad",
      pickupName: "Replacement Winner",
      pickupWindowText: "ASAP",
      email: "requester@example.edu",
      status: "claimed",
      expiresAt: deadline,
      deleteAt: deadline,
      claimedAt: new Date(mutationInstant.getTime() - 30 * 60 * 1000),
      claimExpiresAt: new Date(mutationInstant.getTime() - 1),
      claimExtendedAt: new Date(mutationInstant.getTime() - 20 * 60 * 1000),
      claimTokenDigest: oldDigest,
    });
    const replacement = routeContext(String(request._id));

    await claimRequest(replacement.req, replacement.res);

    expect(replacement.statusCode).toBe(200);
    const stored = await MealRequest.collection.findOne({
      // Raw-driver boundary: mongoose types `_id` as `unknown`, while the
      // driver's filter expects an ObjectId.
      _id: request._id as mongoose.Types.ObjectId,
    });
    expect(stored?.claimExtendedAt).toBeNull();
    expect(stored?.claimTokenDigest).not.toBe(oldDigest);
    expect(stored?.claimedAt.getTime()).toBeGreaterThan(
      mutationInstant.getTime() - 1000
    );
  });
});
