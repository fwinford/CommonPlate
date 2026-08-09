import type { Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// The route module imports the real email helpers, which construct a Resend
// client at module scope. Every case below injects its own send function, so
// the provider is never reached — this only keeps importing the route from
// requiring a live API key.
vi.mock("./emailHelpers.js", () => ({
  sendParticipantVerificationEmail: vi.fn(),
}));

import {
  MINIMUM_PARTICIPANT_SIGNING_SECRET_BYTES,
  digestVerificationCode,
  verifyParticipantAuthority,
} from "./participantCredentials.js";
import {
  VERIFICATION_CODE_LIFETIME_MS,
  VERIFICATION_MAXIMUM_ATTEMPTS,
  VERIFICATION_RESEND_COOLDOWN_MS,
  type ParticipantVerificationDependencies,
} from "./participantVerification.js";
import {
  createRedeemParticipantVerificationHandler,
  createStartParticipantVerificationHandler,
} from "./participantVerificationRoute.js";
import { Participant, ParticipantVerification } from "../models/db.js";

/**
 * The two verification endpoints, driven against a stubbed persistence layer.
 *
 * The real conditional-mutation semantics — supersede, concurrency,
 * exactly-once redemption, uniqueness — belong to
 * `participantVerification.mongo.test.ts`, which runs them against a real
 * replica set. What is proved here is the route contract: which outcome
 * produces which status and code, what a response is allowed to carry, and
 * that no raw code or secret leaves the process.
 */
const secretText = "p".repeat(MINIMUM_PARTICIPANT_SIGNING_SECRET_BYTES);
const secret = Buffer.from(secretText);
const now = new Date("2026-08-05T15:00:00.000Z");
const principal = "student@nyu.edu";
const code = "424242";
const participantId = new mongoose.Types.ObjectId("64c0000000000000000000a1");

function routeContext(body: unknown) {
  const req = { body, headers: {} } as unknown as Request;
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

let sendVerificationEmail: ParticipantVerificationDependencies["sendVerificationEmail"] &
  ReturnType<typeof vi.fn>;
let consoleError: ReturnType<typeof vi.spyOn>;

function dependencies(): Partial<ParticipantVerificationDependencies> {
  return {
    now: () => now,
    generateCode: () => code,
    readSecret: () => secret,
    sendVerificationEmail,
  };
}

function startHandler() {
  return createStartParticipantVerificationHandler(dependencies());
}

function redeemHandler() {
  return createRedeemParticipantVerificationHandler(dependencies());
}

/** The `findOne(...).select(...).lean().exec()` chain, with one answer. */
function stubChallengeRead(result: unknown) {
  return vi.spyOn(ParticipantVerification, "findOne").mockReturnValue({
    select: () => ({
      lean: () => ({ exec: vi.fn().mockResolvedValue(result) }),
    }),
  } as unknown as ReturnType<typeof ParticipantVerification.findOne>);
}

function stubChallengeWrite() {
  return vi
    .spyOn(ParticipantVerification, "findOneAndUpdate")
    .mockReturnValue({
      select: () => ({ lean: () => ({ exec: vi.fn().mockResolvedValue({}) }) }),
    } as unknown as ReturnType<typeof ParticipantVerification.findOneAndUpdate>);
}

/** The conditional issue losing: it matched no eligible row and its insert
 * collided with the live challenge already there. */
function duplicateKeyError() {
  return Object.assign(new Error("E11000 duplicate key"), { code: 11000 });
}

function stubChallengeFailure(error: unknown) {
  return vi
    .spyOn(ParticipantVerification, "findOneAndUpdate")
    .mockReturnValue({
      select: () => ({
        lean: () => ({ exec: vi.fn().mockRejectedValue(error) }),
      }),
    } as unknown as ReturnType<typeof ParticipantVerification.findOneAndUpdate>);
}

beforeEach(() => {
  sendVerificationEmail = vi.fn().mockResolvedValue(undefined);
  consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("POST /api/participant/verification", () => {
  it("issues a challenge and reports only the challenge's own timings", async () => {
    stubChallengeRead(null);
    const write = stubChallengeWrite();
    const context = routeContext({ email: "  STUDENT@NYU.EDU  " });

    await startHandler()(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(202);
    expect(responseBody(context)).toEqual({
      verification: {
        expiresAt: new Date(
          now.getTime() + VERIFICATION_CODE_LIFETIME_MS
        ).toISOString(),
        resendAvailableAt: new Date(
          now.getTime() + VERIFICATION_RESEND_COOLDOWN_MS
        ).toISOString(),
      },
    });
    // Normalized before anything is written or mailed, and conditioned on the
    // cooldown in the write itself rather than in a read taken before it.
    expect(write.mock.calls[0][0]).toEqual({
      email: principal,
      issuedAt: {
        $lte: new Date(now.getTime() - VERIFICATION_RESEND_COOLDOWN_MS),
      },
    });
    expect(sendVerificationEmail).toHaveBeenCalledWith(principal, code);
  });

  it("persists only the keyed digest of the code, never the code", async () => {
    stubChallengeRead(null);
    const write = stubChallengeWrite();
    const context = routeContext({ email: principal });

    await startHandler()(context.req, context.res);

    const update = write.mock.calls[0][1] as any;
    expect(update.$set.codeDigest).toBe(
      digestVerificationCode(principal, code, secret)
    );
    expect(JSON.stringify(update)).not.toContain(code);
    expect(update.$set.attemptsRemaining).toBe(VERIFICATION_MAXIMUM_ATTEMPTS);
    // A resend must supersede rather than accumulate, so any earlier redemption
    // receipt is cleared by the same write that replaces the digest.
    expect(update.$unset).toEqual({ redeemedAt: "" });
  });

  it("never returns the code, its digest, or the secret to the caller", async () => {
    stubChallengeRead(null);
    stubChallengeWrite();
    const context = routeContext({ email: principal });

    await startHandler()(context.req, context.res);

    const body = JSON.stringify(responseBody(context));
    expect(body).not.toContain(code);
    expect(body).not.toContain(digestVerificationCode(principal, code, secret));
    expect(body).not.toContain(secretText);
  });

  it.each([
    [undefined],
    [{}],
    [{ email: "" }],
    [{ email: "not-an-email" }],
    [{ email: "student@gmail.com" }],
    [{ email: "student@law.nyu.edu" }],
    [{ email: principal, unexpected: true }],
  ])("refuses %j without mailing anything", async (body) => {
    const write = stubChallengeWrite();
    const context = routeContext(body);

    await startHandler()(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe("INVALID_EMAIL");
    expect(write).not.toHaveBeenCalled();
    expect(sendVerificationEmail).not.toHaveBeenCalled();
  });

  it("refuses a resend inside the cooldown and says when it reopens", async () => {
    // The conditional write is what refuses now: an address inside its cooldown
    // does not match the filter, so the upsert attempts an insert and loses on
    // the unique index. The read that follows only supplies the reopening
    // instant for the refusal.
    const issuedAt = new Date(now.getTime() - 10_000);
    stubChallengeFailure(duplicateKeyError());
    stubChallengeRead({ issuedAt });
    const context = routeContext({ email: principal });

    await startHandler()(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(429);
    expect(responseBody(context).error.code).toBe(
      "VERIFICATION_RESEND_TOO_SOON"
    );
    expect(responseBody(context).error.resendAvailableAt).toBe(
      new Date(issuedAt.getTime() + VERIFICATION_RESEND_COOLDOWN_MS).toISOString()
    );
    // The anti-mail-bomb bound: no second message and no replacement code.
    expect(sendVerificationEmail).not.toHaveBeenCalled();
  });

  it("reports a full cooldown when the refused address has no readable challenge", async () => {
    // The winner's row vanished — TTL, cleanup, a rollback — between losing the
    // write and reading it back. A full cooldown is the honest fallback; naming
    // a moment that has already passed would invite an immediate second attempt.
    stubChallengeFailure(duplicateKeyError());
    stubChallengeRead(null);
    const context = routeContext({ email: principal });

    await startHandler()(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(429);
    expect(responseBody(context).error.resendAvailableAt).toBe(
      new Date(now.getTime() + VERIFICATION_RESEND_COOLDOWN_MS).toISOString()
    );
    expect(sendVerificationEmail).not.toHaveBeenCalled();
  });

  it("allows a resend once the cooldown has elapsed", async () => {
    stubChallengeWrite();
    const context = routeContext({ email: principal });

    await startHandler()(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(202);
    expect(sendVerificationEmail).toHaveBeenCalledOnce();
  });

  it("leaves nothing usable behind when the code cannot be mailed", async () => {
    stubChallengeWrite();
    const deleteOne = vi
      .spyOn(ParticipantVerification, "deleteOne")
      .mockReturnValue({
        exec: vi.fn().mockResolvedValue({}),
      } as unknown as ReturnType<typeof ParticipantVerification.deleteOne>);
    sendVerificationEmail.mockRejectedValue(new Error("provider down"));
    const context = routeContext({ email: principal });

    await startHandler()(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(503);
    expect(responseBody(context).error.code).toBe(
      "VERIFICATION_EMAIL_UNAVAILABLE"
    );
    // Pinned to this attempt's own digest *and* its issuing instant, so it can
    // only remove the challenge this attempt wrote — never a newer winner's —
    // and the participant is not left waiting out a cooldown for a code that
    // never arrived.
    expect(deleteOne).toHaveBeenCalledWith({
      email: principal,
      codeDigest: digestVerificationCode(principal, code, secret),
      issuedAt: now,
      redeemedAt: { $exists: false },
    });
  });

  it("answers in the envelope when the challenge write fails", async () => {
    stubChallengeRead(null);
    vi.spyOn(ParticipantVerification, "findOneAndUpdate").mockReturnValue({
      select: () => ({
        lean: () => ({
          exec: vi.fn().mockRejectedValue(new Error("database unavailable")),
        }),
      }),
    } as unknown as ReturnType<typeof ParticipantVerification.findOneAndUpdate>);
    const context = routeContext({ email: principal });

    await startHandler()(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(503);
    expect(responseBody(context).error.code).toBe("VERIFICATION_UNAVAILABLE");
    expect(sendVerificationEmail).not.toHaveBeenCalled();
  });

  it("logs no address, code, or digest", async () => {
    stubChallengeRead(null);
    stubChallengeWrite();
    vi.spyOn(ParticipantVerification, "deleteOne").mockReturnValue({
      exec: vi.fn().mockRejectedValue(new Error("cleanup failed")),
    } as unknown as ReturnType<typeof ParticipantVerification.deleteOne>);
    sendVerificationEmail.mockRejectedValue(new Error("provider down"));
    const context = routeContext({ email: principal });

    await startHandler()(context.req, context.res);

    const logged = JSON.stringify(consoleError.mock.calls);
    expect(logged).not.toContain(code);
    expect(logged).not.toContain(principal);
    expect(logged).not.toContain(secretText);
    expect(logged).not.toContain(
      digestVerificationCode(principal, code, secret)
    );
  });
});

describe("POST /api/participant/verification/redeem", () => {
  function stubRedemption({
    won = true,
    alreadyRedeemed = false,
    attemptsRemaining = null as number | null,
    stale = null as unknown,
  } = {}) {
    vi.spyOn(ParticipantVerification, "findOneAndUpdate").mockImplementation(
      ((filter: Record<string, unknown>) => {
        const isSuccessMutation = "codeDigest" in filter;
        const result = isSuccessMutation
          ? won
            ? {}
            : null
          : attemptsRemaining === null
            ? null
            : { attemptsRemaining };
        return {
          select: () => ({
            lean: () => ({ exec: vi.fn().mockResolvedValue(result) }),
          }),
        };
      }) as unknown as typeof ParticipantVerification.findOneAndUpdate
    );
    vi.spyOn(ParticipantVerification, "exists").mockResolvedValue(
      (alreadyRedeemed ? { _id: participantId } : null) as never
    );
    stubChallengeRead(stale);
    vi.spyOn(Participant, "findOneAndUpdate").mockReturnValue({
      exec: vi
        .fn()
        .mockResolvedValue({ _id: participantId, authorityVersion: 1 }),
    } as unknown as ReturnType<typeof Participant.findOneAndUpdate>);
  }

  it("returns a usable authority and the principal on success", async () => {
    stubRedemption();
    const context = routeContext({ email: "  STUDENT@NYU.EDU ", code });

    await redeemHandler()(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(200);
    const body = responseBody(context);
    expect(body.participant).toEqual({ email: principal });
    expect(verifyParticipantAuthority(body.authority, secret)).toEqual({
      participantId: participantId.toString(),
      authorityVersion: 1,
    });
  });

  it("never echoes the code or the digest back", async () => {
    stubRedemption();
    const context = routeContext({ email: principal, code });

    await redeemHandler()(context.req, context.res);

    const body = JSON.stringify(responseBody(context));
    expect(body).not.toContain(code);
    expect(body).not.toContain(digestVerificationCode(principal, code, secret));
    expect(body).not.toContain(secretText);
  });

  it("answers a duplicate submission of an already-spent code as the success it was", async () => {
    // A double tap, or the loser of a concurrent redemption, must not be told
    // its correct code is invalid.
    stubRedemption({ won: false, alreadyRedeemed: true });
    const context = routeContext({ email: principal, code });

    await redeemHandler()(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(200);
    expect(responseBody(context).participant).toEqual({ email: principal });
  });

  it("spends an attempt for a wrong code and reports it as incorrect", async () => {
    stubRedemption({ won: false, attemptsRemaining: 3 });
    const context = routeContext({ email: principal, code: "999999" });

    await redeemHandler()(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe("VERIFICATION_CODE_INVALID");
  });

  it("retires the challenge once the attempt bound is reached", async () => {
    stubRedemption({ won: false, attemptsRemaining: 0 });
    const context = routeContext({ email: principal, code: "999999" });

    await redeemHandler()(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(429);
    expect(responseBody(context).error.code).toBe(
      "VERIFICATION_ATTEMPTS_EXCEEDED"
    );
  });

  it("reports an expired challenge distinctly from a wrong code", async () => {
    stubRedemption({
      won: false,
      stale: {
        expiresAt: new Date(now.getTime() - 1),
        attemptsRemaining: 5,
      },
    });
    const context = routeContext({ email: principal, code });

    await redeemHandler()(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(410);
    expect(responseBody(context).error.code).toBe("VERIFICATION_CODE_EXPIRED");
  });

  it("reports a code submitted for an address with no challenge", async () => {
    stubRedemption({ won: false, stale: null });
    const context = routeContext({ email: principal, code });

    await redeemHandler()(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(409);
    expect(responseBody(context).error.code).toBe(
      "VERIFICATION_CODE_NOT_REQUESTED"
    );
  });

  it.each([
    [undefined],
    [{}],
    [{ email: principal }],
    [{ code }],
    [{ email: "student@gmail.com", code }],
    [{ email: principal, code, unexpected: true }],
  ])("refuses the malformed submission %j", async (body) => {
    const mutate = vi.spyOn(ParticipantVerification, "findOneAndUpdate");
    const context = routeContext(body);

    await redeemHandler()(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(mutate).not.toHaveBeenCalled();
  });

  it.each(["", "12345", "1234567", "12345a", " 424242"])(
    "answers a malformed code %j from shape alone, spending no attempt",
    async (submitted) => {
      const mutate = vi.spyOn(ParticipantVerification, "findOneAndUpdate");
      const context = routeContext({ email: principal, code: submitted });

      await redeemHandler()(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(400);
      expect(responseBody(context).error.code).toBe(
        "VERIFICATION_CODE_INVALID"
      );
      // The five real attempts belong to real guesses; a value that cannot be
      // a code this service issued must not consume one.
      expect(mutate).not.toHaveBeenCalled();
    }
  );

  it("establishes no participant for a failed redemption", async () => {
    stubRedemption({ won: false, attemptsRemaining: 4 });
    const upsert = vi.spyOn(Participant, "findOneAndUpdate");
    const context = routeContext({ email: principal, code: "999999" });

    await redeemHandler()(context.req, context.res);

    expect(upsert).not.toHaveBeenCalled();
  });

  it("does not raise the authority version when an existing participant re-verifies", async () => {
    // Verifying again on one device must not revoke the same person's other
    // device: only an explicit revocation may move the counter.
    stubRedemption();
    const upsert = vi.spyOn(Participant, "findOneAndUpdate");
    const context = routeContext({ email: principal, code });

    await redeemHandler()(context.req, context.res);

    const update = upsert.mock.calls[0][1] as any;
    expect(update.$set).toEqual({ verifiedAt: now });
    expect(update.$setOnInsert).toEqual({ authorityVersion: 1 });
    expect(update.$inc).toBeUndefined();
  });

  it("answers in the envelope when redemption itself fails", async () => {
    vi.spyOn(ParticipantVerification, "findOneAndUpdate").mockReturnValue({
      select: () => ({
        lean: () => ({
          exec: vi.fn().mockRejectedValue(new Error("database unavailable")),
        }),
      }),
    } as unknown as ReturnType<typeof ParticipantVerification.findOneAndUpdate>);
    const context = routeContext({ email: principal, code });

    await redeemHandler()(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(503);
    expect(responseBody(context).error.code).toBe("VERIFICATION_UNAVAILABLE");
  });

  it("refuses rather than inventing authority when the credential cannot be signed", async () => {
    stubRedemption();
    const context = routeContext({ email: principal, code });
    const handler = createRedeemParticipantVerificationHandler({
      ...dependencies(),
      readSecret: () => Buffer.from("too-short"),
    });

    await handler(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(503);
    expect(responseBody(context)).not.toHaveProperty("authority");
  });
});
