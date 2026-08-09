import express, { type Request, type Response } from "express";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import mongoose from "mongoose";
import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";
import { Request as MealRequest, Participant } from "../models/db.js";
import {
  PARTICIPANT_AUTHORITY_HEADER,
  PARTICIPANT_AUTHORITY_INVALID_CODE,
  PARTICIPANT_VERIFICATION_REQUIRED_CODE,
} from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import {
  CLAIM_DURATION_MS,
  CLAIM_EXTENSION_MS,
  CLAIM_UNAVAILABLE_MESSAGE,
  claimRequest,
  createDay4MutationRateLimiter,
  extendClaim,
  pauseDay4Mutation,
} from "./claimRoute.js";
import {
  digestClaimToken,
  generateClaimToken,
} from "./claimToken.js";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
import {
  CLAIM_MINIMUM_REMAINING_MS,
  buildEffectiveAvailabilityFilter,
  isEffectivelyAvailable,
} from "./requestAvailability.js";

const requestId = new mongoose.Types.ObjectId("64b000000000000000000001");
const now = new Date("2026-07-30T16:00:00.000Z");
const expiresAt = new Date("2026-07-30T17:00:00.000Z");
const secretText = "unit-test-claim-hmac-secret-material";
const secret = Buffer.from(secretText);

function document(overrides: Record<string, unknown> = {}) {
  return {
    _id: requestId,
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName: "Private Pickup Name",
    pickupWindowText: "ASAP (available for the next 3 hours)",
    windowStart: null,
    windowEnd: null,
    status: "claimed",
    createdAt: new Date("2026-07-30T15:00:00.000Z"),
    expiresAt,
    deleteAt: expiresAt,
    claimedAt: now,
    claimExpiresAt: new Date(now.getTime() + CLAIM_DURATION_MS),
    claimExtendedAt: null,
    claimTokenDigest: "private-digest",
    email: "private@example.edu",
    ...overrides,
  };
}

/**
 * The verified helper every claim case in this file acts as (W3-I1).
 *
 * A real signed credential in the real header, resolved by the real gate
 * against a stubbed Participant row, so these suites prove the helper gate as
 * it runs rather than a stand-in for it.
 */
const helperParticipantId = new mongoose.Types.ObjectId(
  "64c0000000000000000000b2"
);
const helperPrincipal = "helper@nyu.edu";
const participantSecretText = "participant-claim-route-unit-test-secret";
const participantSecret = Buffer.from(participantSecretText);
const participantAuthority = signParticipantAuthority(
  helperParticipantId,
  1,
  participantSecret
);

function stubVerifiedParticipant(email: string = helperPrincipal) {
  return vi.spyOn(Participant, "findOne").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi.fn().mockResolvedValue({ _id: helperParticipantId, email }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findOne>);
}

function routeContext(
  body: unknown = undefined,
  id = requestId.toString(),
  headers: Record<string, string | string[]> = {
    [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
  }
) {
  const req = { params: { id }, body, headers } as unknown as Request;
  const res = {} as Response;
  const status = vi.fn().mockReturnValue(res);
  const json = vi.fn().mockReturnValue(res);
  res.status = status;
  res.json = json;
  return { req, res, status, json };
}

function mockAtomicResult(result: unknown) {
  return vi.spyOn(MealRequest, "findOneAndUpdate").mockReturnValue({
    lean: () => ({
      exec: vi.fn().mockResolvedValue(result),
    }),
  } as unknown as ReturnType<typeof MealRequest.findOneAndUpdate>);
}

function mockAtomicRejection(error: Error) {
  return vi.spyOn(MealRequest, "findOneAndUpdate").mockReturnValue({
    lean: () => ({
      exec: vi.fn().mockRejectedValue(error),
    }),
  } as unknown as ReturnType<typeof MealRequest.findOneAndUpdate>);
}

function mockDiagnosticResult(result: unknown) {
  return vi.spyOn(MealRequest, "findById").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi.fn().mockResolvedValue(result),
      }),
    }),
  } as unknown as ReturnType<typeof MealRequest.findById>);
}

function responseBody(context: ReturnType<typeof routeContext>) {
  return context.json.mock.calls[0][0] as Record<string, any>;
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(now);
  vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", secretText);
  vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
  vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
  stubVerifiedParticipant();
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
  vi.unstubAllEnvs();
});

describe("POST /api/request/:id/claim", () => {
  it("claims with one conditional atomic update and returns private data only in claim", async () => {
    const claimed = document();
    const atomic = mockAtomicResult(claimed);
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(atomic).toHaveBeenCalledOnce();
    const [filter, update, options] = atomic.mock.calls[0] as any[];
    expect(filter).toEqual({
      _id: requestId.toString(),
      status: { $ne: "placed" },
      // The same start-of-visibility clause the list and alert paths apply, so
      // a scheduled request cannot be claimed before helpers can see it.
      visibleFrom: { $not: { $gt: now } },
      expiresAt: {
        $gt: now,
        $gte: new Date(now.getTime() + 5 * 60 * 1000),
      },
      $or: [
        { status: "open" },
        { status: "claimed", claimExpiresAt: { $lte: now } },
      ],
    });
    expect(options).toEqual({ new: true });
    expect(update[0].$set).toMatchObject({
      status: "claimed",
      claimedAt: now,
      claimExtendedAt: null,
      updatedAt: now,
    });
    // The reservation and the verified helper it belongs to are written by the
    // same conditional mutation, so a claim never exists unbound (W3-I1).
    expect(update[0].$set.helperParticipantId).toEqual(helperParticipantId);
    expect(update[0].$set.claimExpiresAt).toEqual({
      $min: [
        new Date(now.getTime() + CLAIM_DURATION_MS),
        "$expiresAt",
      ],
    });
    expect(update[0].$set.claimTokenDigest).toMatch(/^[a-f0-9]{64}$/);

    const body = responseBody(context);
    expect(body.request).toEqual({
      id: requestId.toString(),
      vendor: "Campus Market",
      food: "Vegetable rice bowl",
      pickupWindowText: "ASAP (available for the next 3 hours)",
      windowStart: null,
      windowEnd: null,
      status: "claimed",
      createdAt: new Date("2026-07-30T15:00:00.000Z"),
      expiresAt,
    });
    expect(body.claim.pickupName).toBe("Private Pickup Name");
    expect(body.claim.claimToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(body.claim.claimExpiresAt).toEqual(claimed.claimExpiresAt);
    expect(update[0].$set.claimTokenDigest).toBe(
      digestClaimToken(body.claim.claimToken, secret)
    );
    expect(JSON.stringify(body.request)).not.toMatch(
      /pickupName|email|deleteAt|claimedAt|claimExtendedAt|claimTokenDigest/
    );
  });

  it("gates claiming on the same rule that gates advertising", async () => {
    // Both sides read the identical clause from the shared helper, so a request
    // can never be advertised in a window where claiming must refuse it.
    const atomic = mockAtomicResult(document());
    const context = routeContext();

    await claimRequest(context.req, context.res);

    const [filter] = atomic.mock.calls[0] as any[];
    expect(filter.expiresAt).toEqual(
      buildEffectiveAvailabilityFilter(now).expiresAt
    );
    expect(filter.$or).toEqual(buildEffectiveAvailabilityFilter(now).$or);

    const exactMinimum = new Date(
      now.getTime() + CLAIM_MINIMUM_REMAINING_MS
    );
    expect(filter.expiresAt.$gte).toEqual(exactMinimum);
    expect(
      isEffectivelyAvailable({ status: "open", expiresAt: exactMinimum }, now)
    ).toBe(true);
    expect(
      isEffectivelyAvailable(
        { status: "open", expiresAt: new Date(exactMinimum.getTime() - 1) },
        now
      )
    ).toBe(false);
  });

  it("returns the locked conflict and no claimant data when an active claim wins first", async () => {
    mockAtomicResult(null);
    mockDiagnosticResult(
      document({
        claimTokenDigest: "f".repeat(64),
      })
    );
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(409);
    expect(responseBody(context)).toEqual({
      error: {
        code: "REQUEST_ALREADY_CLAIMED",
        message: "Someone else just started helping with this request.",
        fields: null,
      },
    });
    expect(JSON.stringify(responseBody(context))).not.toMatch(
      /pickupName|claimToken|Private Pickup/
    );
  });

  it.each([
    {
      name: "not found",
      diagnostic: null,
      status: 404,
      code: "REQUEST_NOT_FOUND",
    },
    {
      name: "already placed",
      diagnostic: document({ status: "placed" }),
      status: 409,
      code: "REQUEST_ALREADY_PLACED",
    },
    {
      name: "expired",
      diagnostic: document({
        status: "open",
        expiresAt: now,
      }),
      status: 410,
      code: "REQUEST_EXPIRED",
    },
    {
      name: "under five minutes",
      diagnostic: document({
        status: "open",
        expiresAt: new Date(now.getTime() + 5 * 60 * 1000 - 1),
      }),
      status: 409,
      code: "REQUEST_INSUFFICIENT_TIME",
    },
    {
      // Classified ahead of expiration, and deliberately its own code: this
      // request has not run out, it has not started. A legacy row with no
      // recorded start is unaffected — it has always been visible.
      name: "not started yet",
      diagnostic: document({
        status: "open",
        visibleFrom: new Date(now.getTime() + 1),
        expiresAt: new Date(now.getTime() + 3 * 60 * 60 * 1000),
      }),
      status: 409,
      code: "REQUEST_NOT_YET_AVAILABLE",
    },
  ])("distinguishes $name after the atomic update loses", async (scenario) => {
    mockAtomicResult(null);
    mockDiagnosticResult(scenario.diagnostic);
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(scenario.status);
    expect(responseBody(context).error).toMatchObject({
      code: scenario.code,
      fields: null,
    });
  });

  it("rejects an invalid ID before token generation or database access", async () => {
    const atomic = vi.spyOn(MealRequest, "findOneAndUpdate");
    const context = routeContext(undefined, "not-an-id");

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe("INVALID_REQUEST_ID");
    expect(atomic).not.toHaveBeenCalled();
  });

  it("fails safely when the HMAC secret is missing", async () => {
    vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", "");
    const atomic = vi.spyOn(MealRequest, "findOneAndUpdate");
    const consoleError = vi
      .spyOn(console, "error")
      .mockImplementation(() => {});
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(500);
    expect(responseBody(context).error.code).toBe("INTERNAL_FAILURE");
    expect(atomic).not.toHaveBeenCalled();
    expect(JSON.stringify(consoleError.mock.calls)).not.toMatch(
      /secret-material|claimTokenDigest/
    );
  });

  it("returns structured INTERNAL_FAILURE when the atomic execution rejects", async () => {
    // A rejected driver operation does not prove no claim was written: MongoDB
    // may have applied the conditional mutation before its acknowledgement was
    // lost. The route deliberately preserves its structured error envelope.
    const atomic = mockAtomicRejection(new Error("acknowledgement lost"));
    const consoleError = vi
      .spyOn(console, "error")
      .mockImplementation(() => {});
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(atomic).toHaveBeenCalledOnce();
    expect(context.status).toHaveBeenCalledWith(500);
    expect(responseBody(context)).toEqual({
      error: {
        code: "INTERNAL_FAILURE",
        message: "Unable to claim this request right now.",
        fields: null,
      },
    });
    expect(consoleError).toHaveBeenCalledOnce();
  });
});

describe("POST /api/request/:id/claim helper gate (W3-I1)", () => {
  /**
   * Browsing stays open to anyone; reserving does not. A reservation takes a
   * real student's meal out of every other helper's reach and commits a person
   * to placing an order, so it is a participant action.
   */
  it("refuses a helper with no participant credential and reserves nothing", async () => {
    const atomic = mockAtomicResult(document());
    const context = routeContext(undefined, requestId.toString(), {});

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(responseBody(context).error.code).toBe(
      PARTICIPANT_VERIFICATION_REQUIRED_CODE
    );
    // Ahead of token generation and the conditional mutation: nothing is
    // reserved, and no claim token is minted for a caller who proved nothing.
    expect(atomic).not.toHaveBeenCalled();
  });

  it("refuses a credential whose participant no longer exists", async () => {
    const atomic = mockAtomicResult(document());
    vi.spyOn(Participant, "findOne").mockReturnValue({
      select: () => ({ lean: () => ({ exec: vi.fn().mockResolvedValue(null) }) }),
    } as unknown as ReturnType<typeof Participant.findOne>);
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(responseBody(context).error.code).toBe(
      PARTICIPANT_AUTHORITY_INVALID_CODE
    );
    expect(atomic).not.toHaveBeenCalled();
  });

  it("refuses a credential signed at a revoked authority version", async () => {
    // The stub answers only for version 1, so a version-2 credential fails the
    // database check even though its signature is genuine. Revocation is the
    // one lever that invalidates a credential already on a device.
    const atomic = mockAtomicResult(document());
    vi.spyOn(Participant, "findOne").mockReturnValue({
      select: () => ({ lean: () => ({ exec: vi.fn().mockResolvedValue(null) }) }),
    } as unknown as ReturnType<typeof Participant.findOne>);
    const context = routeContext(undefined, requestId.toString(), {
      [PARTICIPANT_AUTHORITY_HEADER]: signParticipantAuthority(
        helperParticipantId,
        2,
        participantSecret
      ),
    });

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(401);
    expect(atomic).not.toHaveBeenCalled();
  });

  it("answers 503 and reserves nothing when the gate itself cannot decide", async () => {
    const atomic = mockAtomicResult(document());
    vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, "");
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(503);
    expect(atomic).not.toHaveBeenCalled();
    expect(JSON.stringify(consoleError.mock.calls)).not.toContain(
      participantSecretText
    );
  });

  it("rebinds the reservation to whoever wins a re-claim after expiry", async () => {
    // A lapsed reservation is claimable again, and the new holder is the new
    // bound helper — not whoever held it before.
    const otherParticipantId = new mongoose.Types.ObjectId(
      "64c0000000000000000000c3"
    );
    stubVerifiedParticipant("other-helper@nyu.edu");
    vi.spyOn(Participant, "findOne").mockReturnValue({
      select: () => ({
        lean: () => ({
          exec: vi.fn().mockResolvedValue({
            _id: otherParticipantId,
            email: "other-helper@nyu.edu",
          }),
        }),
      }),
    } as unknown as ReturnType<typeof Participant.findOne>);
    const atomic = mockAtomicResult(document());
    const context = routeContext(undefined, requestId.toString(), {
      [PARTICIPANT_AUTHORITY_HEADER]: signParticipantAuthority(
        otherParticipantId,
        1,
        participantSecret
      ),
    });

    await claimRequest(context.req, context.res);

    const [, update] = atomic.mock.calls[0] as any[];
    expect(update[0].$set.helperParticipantId).toEqual(otherParticipantId);
  });

  it("keeps the participant credential out of the claim response", async () => {
    mockAtomicResult(document());
    const context = routeContext();

    await claimRequest(context.req, context.res);

    expect(JSON.stringify(responseBody(context))).not.toContain(
      participantAuthority
    );
    expect(JSON.stringify(responseBody(context))).not.toContain(
      helperParticipantId.toString()
    );
    // Participant identity is not public request data, so the helper's own
    // address must not appear either.
    expect(JSON.stringify(responseBody(context))).not.toContain(helperPrincipal);
  });
});

describe("POST /api/request/:id/claim/extend", () => {
  it("extends once with one conditional atomic update and returns only timestamps", async () => {
    const rawToken = generateClaimToken();
    const originalClaimExpiration = new Date(
      now.getTime() + CLAIM_DURATION_MS
    );
    const extended = document({
      claimExpiresAt: new Date(
        originalClaimExpiration.getTime() + CLAIM_EXTENSION_MS
      ),
      claimExtendedAt: now,
    });
    const atomic = mockAtomicResult(extended);
    const context = routeContext({ claimToken: rawToken });

    await extendClaim(context.req, context.res);

    const submittedDigest = digestClaimToken(rawToken, secret);
    expect(atomic).toHaveBeenCalledWith(
      {
        _id: requestId.toString(),
        status: "claimed",
        claimTokenDigest: submittedDigest,
        claimExpiresAt: { $gt: now },
        claimExtendedAt: null,
        $expr: {
          $lte: [
            { $add: ["$claimExpiresAt", CLAIM_EXTENSION_MS] },
            "$expiresAt",
          ],
        },
      },
      [
        {
          $set: {
            claimExpiresAt: {
              $add: ["$claimExpiresAt", CLAIM_EXTENSION_MS],
            },
            claimExtendedAt: now,
            updatedAt: now,
          },
        },
      ],
      { new: true }
    );
    expect(responseBody(context)).toEqual({
      claim: {
        claimExpiresAt: extended.claimExpiresAt,
        claimExtendedAt: now,
      },
    });
    expect(JSON.stringify(responseBody(context))).not.toMatch(
      /claimToken|pickupName|vendor|request/
    );
  });

  it.each([
    {
      name: "request not found",
      diagnostic: (_digest: string) => null,
      status: 404,
      code: "REQUEST_NOT_FOUND",
    },
    {
      name: "placed request",
      diagnostic: (digest: string) =>
        document({ status: "placed", claimTokenDigest: digest }),
      status: 409,
      code: "REQUEST_ALREADY_PLACED",
    },
    {
      name: "expired request",
      diagnostic: (digest: string) =>
        document({
          claimTokenDigest: digest,
          expiresAt: now,
          claimExpiresAt: now,
        }),
      status: 410,
      code: "REQUEST_EXPIRED",
    },
    {
      name: "request without a claim",
      diagnostic: (digest: string) =>
        document({ status: "open", claimTokenDigest: digest }),
      status: 409,
      code: "REQUEST_NOT_CLAIMED",
    },
    {
      name: "wrong token",
      diagnostic: (digest: string) =>
        document({
          claimTokenDigest:
            digest === "0".repeat(64) ? "1".repeat(64) : "0".repeat(64),
        }),
      status: 403,
      code: "INVALID_CLAIM_TOKEN",
    },
    {
      name: "expired claim",
      diagnostic: (digest: string) =>
        document({ claimTokenDigest: digest, claimExpiresAt: now }),
      status: 409,
      code: "CLAIM_EXPIRED",
    },
    {
      name: "second extension",
      diagnostic: (digest: string) =>
        document({ claimTokenDigest: digest, claimExtendedAt: now }),
      status: 409,
      code: "CLAIM_EXTENSION_ALREADY_USED",
    },
    {
      name: "no room for a full extension",
      diagnostic: (digest: string) =>
        document({
          claimTokenDigest: digest,
          claimExpiresAt: new Date(expiresAt.getTime() - CLAIM_EXTENSION_MS + 1),
        }),
      status: 409,
      code: "CLAIM_EXTENSION_INSUFFICIENT_TIME",
    },
  ])("rejects $name after the conditional update loses", async (scenario) => {
    const rawToken = generateClaimToken();
    const digest = digestClaimToken(rawToken, secret);
    mockAtomicResult(null);
    mockDiagnosticResult(scenario.diagnostic(digest));
    const context = routeContext({ claimToken: rawToken });

    await extendClaim(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(scenario.status);
    expect(responseBody(context).error).toMatchObject({
      code: scenario.code,
      fields: null,
    });
  });

  it("reports an expired claim, not an invalid token, when another helper replaced it", async () => {
    // Helper A claims, A's claim lapses, helper B claims and overwrites the
    // digest, then A's extension arrives. A's token is genuinely absent from
    // the record, but the truthful cause is that A's claim expired.
    const helperAToken = generateClaimToken();
    const helperBDigest = digestClaimToken(generateClaimToken(), secret);
    mockAtomicResult(null);
    mockDiagnosticResult(
      document({
        status: "claimed",
        claimTokenDigest: helperBDigest,
        claimExpiresAt: new Date(now.getTime() - 1),
        claimExtendedAt: null,
      })
    );
    const context = routeContext({ claimToken: helperAToken });

    await extendClaim(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(409);
    expect(responseBody(context).error).toMatchObject({
      code: "CLAIM_EXPIRED",
      fields: null,
    });
    expect(JSON.stringify(responseBody(context))).not.toMatch(
      /claimToken|pickupName|[a-f0-9]{64}/
    );
  });

  it("still rejects a wrong token on an active claim", async () => {
    const rawToken = generateClaimToken();
    mockAtomicResult(null);
    mockDiagnosticResult(
      document({
        status: "claimed",
        claimTokenDigest: digestClaimToken(generateClaimToken(), secret),
        claimExpiresAt: new Date(now.getTime() + CLAIM_DURATION_MS),
      })
    );
    const context = routeContext({ claimToken: rawToken });

    await extendClaim(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(403);
    expect(responseBody(context).error).toMatchObject({
      code: "INVALID_CLAIM_TOKEN",
      fields: null,
    });
  });

  it("rejects an invalid request ID before token or database work", async () => {
    const atomic = vi.spyOn(MealRequest, "findOneAndUpdate");
    const context = routeContext(
      { claimToken: generateClaimToken() },
      "not-an-id"
    );

    await extendClaim(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe("INVALID_REQUEST_ID");
    expect(atomic).not.toHaveBeenCalled();
  });

  it.each([
    undefined,
    {},
    { claimToken: "not-base64url" },
    { claimToken: generateClaimToken(), extra: true },
  ])("rejects missing or malformed token body %j", async (body) => {
    const atomic = vi.spyOn(MealRequest, "findOneAndUpdate");
    const context = routeContext(body);

    await extendClaim(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe("INVALID_CLAIM_TOKEN");
    expect(atomic).not.toHaveBeenCalled();
  });
});

describe("Day 4 operational middleware", () => {
  it("refuses paused claims with the Day 4 envelope before the handler", () => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");
    const context = routeContext();
    const next = vi.fn();

    pauseDay4Mutation(context.req, context.res, next);

    expect(context.status).toHaveBeenCalledWith(503);
    expect(responseBody(context)).toEqual({
      error: {
        code: "PUBLIC_ACTIONS_PAUSED",
        message: CLAIM_UNAVAILABLE_MESSAGE,
        fields: null,
      },
    });
    expect(next).not.toHaveBeenCalled();
  });

  it("rate limits with a structured Day 4 error", async () => {
    vi.useRealTimers();
    const testApp = express();
    testApp.post(
      "/limited",
      createDay4MutationRateLimiter(1),
      (_req, res) => res.json({ ok: true })
    );
    const server = createServer(testApp);
    await new Promise<void>((resolve) =>
      server.listen(0, "127.0.0.1", resolve)
    );

    try {
      const { port } = server.address() as AddressInfo;
      const first = await fetch(`http://127.0.0.1:${port}/limited`, {
        method: "POST",
      });
      const second = await fetch(`http://127.0.0.1:${port}/limited`, {
        method: "POST",
      });

      expect(first.status).toBe(200);
      expect(second.status).toBe(429);
      await expect(second.json()).resolves.toEqual({
        error: {
          code: "RATE_LIMITED",
          message: "Too many attempts. Please wait a moment and try again.",
          fields: null,
        },
      });
    } finally {
      await new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve()))
      );
    }
  });
});
