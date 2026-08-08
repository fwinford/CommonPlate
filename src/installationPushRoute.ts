import type { Request, Response } from "express";
import { z } from "zod";
import { Installation } from "../models/db.js";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import { sendDay4Error } from "./day4Errors.js";
import {
  digestInstallationCredential,
  isValidRawInstallationCredential,
} from "./installationCredential.js";

/**
 * Week 3 Day 6 Slice 6A.1 — declarative installation push-state
 * synchronization. The app reports its complete current push state on every
 * call; this endpoint reconciles the persisted installation record to match.
 * It sends no notification and has no other public operation for token
 * refresh, replacement, reactivation, or removal — this one endpoint covers
 * all of them.
 */
export const INSTALLATION_PUSH_ROUTE_PATH = "/api/installations/push";
export const INSTALLATION_PUSH_UNAVAILABLE_MESSAGE =
  "Push notification setup is temporarily unavailable.";
export const INVALID_INSTALLATION_REQUEST_MESSAGE =
  "The installation push request is invalid.";

const APNS_TOKEN_PATTERN = /^[a-f0-9]+$/;
// Apple's current device token is 32 bytes (64 hex characters), but nothing
// here assumes that exact size stays fixed. The bound below is a defense
// against pathological input, not a pin to today's token length: 100 bytes
// (200 hex characters) comfortably covers any plausible future APNs token
// while still rejecting an unbounded string.
const MIN_APNS_TOKEN_HEX_LENGTH = 2;
const MAX_APNS_TOKEN_HEX_LENGTH = 200;

/**
 * Normalized shape: lowercase hex, no separators, no wrapping characters, one
 * two-character pair per byte (so always an even length), bounded but not
 * fixed to Apple's current 32-byte token.
 */
export function isNormalizedApnsToken(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length >= MIN_APNS_TOKEN_HEX_LENGTH &&
    value.length <= MAX_APNS_TOKEN_HEX_LENGTH &&
    value.length % 2 === 0 &&
    APNS_TOKEN_PATTERN.test(value)
  );
}

const installationCredentialSchema = z
  .string()
  .refine(isValidRawInstallationCredential);

const enabledRequestSchema = z
  .object({
    installationCredential: installationCredentialSchema,
    enabled: z.literal(true),
    apnsToken: z.string().refine(isNormalizedApnsToken),
    environment: z.enum(["development", "production"]),
  })
  .strict();

const disabledRequestSchema = z
  .object({
    installationCredential: installationCredentialSchema,
    enabled: z.literal(false),
  })
  .strict();

// A discriminated union rather than one object with optional fields, so an
// enabled request without a token or environment — and a disabled request
// that smuggles one in — are both rejected by the schema itself rather than
// by later handler logic.
const installationPushBodySchema = z.discriminatedUnion("enabled", [
  enabledRequestSchema,
  disabledRequestSchema,
]);

export interface InstallationPushDependencies {
  now: () => Date;
}

const defaultDependencies: InstallationPushDependencies = {
  now: () => new Date(),
};

function isDuplicateKeyError(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    (error as { code?: unknown }).code === 11000
  );
}

function pushState(enabled: boolean) {
  return { push: { enabled } };
}

function sendInvalidRequest(res: Response): Response {
  return sendDay4Error(
    res,
    400,
    "INVALID_INSTALLATION_REQUEST",
    INVALID_INSTALLATION_REQUEST_MESSAGE
  );
}

// Bounded so a persistent conflict fails loudly instead of looping forever.
// In practice this resolves within one or two attempts: the partial unique
// index on (apnsToken, apnsEnvironment) guarantees at most one installation
// can hold `pushEnabled: true` for a given pair at any instant, so a
// duplicate-key conflict means exactly one other document to demote.
const MAX_OWNERSHIP_ATTEMPTS = 5;

export function createInstallationPushHandler(
  overrides: Partial<InstallationPushDependencies> = {}
) {
  const dependencies = { ...defaultDependencies, ...overrides };

  return async function synchronizeInstallationPush(
    req: Request,
    res: Response
  ): Promise<Response> {
    const parsed = installationPushBodySchema.safeParse(req.body);
    if (!parsed.success) return sendInvalidRequest(res);

    const { installationCredential, enabled } = parsed.data;
    const installationCredentialDigest = digestInstallationCredential(
      installationCredential
    );
    const now = dependencies.now();

    if (!enabled) {
      // No upsert: an installation that never registered has nothing to
      // disable, and reporting `false` for it is already truthful. Disabling
      // an existing installation leaves its token in place — see the schema
      // comment on `apnsToken` — and only its eligibility is cleared.
      const updated = await Installation.findOneAndUpdate(
        { installationCredentialDigest },
        { $set: { pushEnabled: false, updatedAt: now } },
        { new: true }
      )
        .select("pushEnabled")
        .lean()
        .exec();
      return res.json(pushState(updated?.pushEnabled ?? false));
    }

    const { apnsToken, environment } = parsed.data;

    for (let attempt = 0; attempt < MAX_OWNERSHIP_ATTEMPTS; attempt++) {
      try {
        const updated = await Installation.findOneAndUpdate(
          { installationCredentialDigest },
          {
            $set: {
              pushEnabled: true,
              apnsToken,
              apnsEnvironment: environment,
              tokenUpdatedAt: now,
              invalidatedAt: null,
              updatedAt: now,
            },
            $setOnInsert: { createdAt: now },
          },
          { new: true, upsert: true }
        )
          .select("pushEnabled")
          .lean()
          .exec();
        return res.json(pushState(updated!.pushEnabled));
      } catch (error) {
        if (!isDuplicateKeyError(error)) throw error;
        // Another installation currently holds this exact token/environment
        // as the eligible owner — the partial unique index refused this
        // write. Demote that installation, then retry this installation's
        // own upsert.
        await Installation.updateMany(
          {
            apnsToken,
            apnsEnvironment: environment,
            pushEnabled: true,
            installationCredentialDigest: { $ne: installationCredentialDigest },
          },
          { $set: { pushEnabled: false, invalidatedAt: now, updatedAt: now } }
        );
      }
    }

    console.error(
      "[installationPush] Could not reconcile token ownership after repeated conflicts",
      { installationCredentialDigest }
    );
    return sendDay4Error(
      res,
      500,
      "INTERNAL_FAILURE",
      "Unable to update push notification state right now."
    );
  };
}

export const synchronizeInstallationPush = createInstallationPushHandler();

// Its own bucket, matching the Day 4 mutation pattern, so installation
// synchronization cannot spend another public action's allowance and vice
// versa. Sized above the Day 4 mutations because ordinary app foreground and
// background-refresh events call this endpoint more often than a person
// claims or extends a claim.
export const installationPushRateLimiter = createDay4MutationRateLimiter(20);
