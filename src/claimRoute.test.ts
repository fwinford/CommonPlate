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
import { Request as MealRequest } from "../models/db.js";
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
    pickupWindowText: "ASAP (within the next hour)",
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

function routeContext(
  body: unknown = undefined,
  id = requestId.toString()
) {
  const req = { params: { id }, body } as unknown as Request;
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
  } as ReturnType<typeof MealRequest.findOneAndUpdate>);
}

function mockDiagnosticResult(result: unknown) {
  return vi.spyOn(MealRequest, "findById").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi.fn().mockResolvedValue(result),
      }),
    }),
  } as ReturnType<typeof MealRequest.findById>);
}

function responseBody(context: ReturnType<typeof routeContext>) {
  return context.json.mock.calls[0][0] as Record<string, any>;
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(now);
  vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", secretText);
  vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
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
      pickupWindowText: "ASAP (within the next hour)",
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
