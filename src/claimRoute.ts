import type { NextFunction, Request, Response } from "express";
import rateLimit from "express-rate-limit";
import mongoose from "mongoose";
import { Request as MealRequest } from "../models/db.js";
import {
  buildPublicRequestDetailResponse,
  type PublicRequestDocument,
} from "./requestListResponse.js";
import {
  claimTokenDigestMatches,
  digestClaimToken,
  generateClaimToken,
  isValidRawClaimToken,
  readClaimTokenHmacSecret,
} from "./claimToken.js";
import { day4Error, sendDay4Error } from "./day4Errors.js";
import { isPublicActionsPaused } from "./publicActionsPause.js";
import {
  buildMinimumRemainingTimeFilter,
  hasMinimumRemainingTime,
} from "./requestAvailability.js";

export const CLAIM_ROUTE_PATH = "/api/request/:id/claim";
export const CLAIM_EXTENSION_ROUTE_PATH = "/api/request/:id/claim/extend";
export const CLAIM_DURATION_MS = 15 * 60 * 1000;
export const CLAIM_EXTENSION_MS = 5 * 60 * 1000;
export const CLAIM_UNAVAILABLE_MESSAGE =
  "Helping with meal requests is temporarily unavailable.";

interface ClaimDiagnosticDocument {
  status?: string;
  expiresAt?: Date | null;
  claimExpiresAt?: Date | null;
  claimExtendedAt?: Date | null;
  claimTokenDigest?: string | null;
}

function isInvalidId(id: unknown): boolean {
  return !mongoose.Types.ObjectId.isValid(String(id));
}

function diagnosticRequest(id: string) {
  return MealRequest.findById(id)
    .select(
      "status expiresAt claimExpiresAt claimExtendedAt +claimTokenDigest"
    )
    .lean()
    .exec() as Promise<ClaimDiagnosticDocument | null>;
}

function isExpired(value: Date | null | undefined, now: Date): boolean {
  return !value || value.getTime() <= now.getTime();
}

async function explainClaimFailure(
  id: string,
  now: Date,
  res: Response
): Promise<Response> {
  const document = await diagnosticRequest(id);
  if (!document) {
    return sendDay4Error(
      res,
      404,
      "REQUEST_NOT_FOUND",
      "This request could not be found."
    );
  }
  if (document.status === "placed") {
    return sendDay4Error(
      res,
      409,
      "REQUEST_ALREADY_PLACED",
      "This request has already been placed."
    );
  }
  if (isExpired(document.expiresAt, now)) {
    return sendDay4Error(
      res,
      410,
      "REQUEST_EXPIRED",
      "This request is no longer available."
    );
  }
  if (!hasMinimumRemainingTime(document.expiresAt, now)) {
    return sendDay4Error(
      res,
      409,
      "REQUEST_INSUFFICIENT_TIME",
      "This request does not have five full minutes remaining."
    );
  }
  if (
    document.status === "claimed" &&
    document.claimExpiresAt &&
    document.claimExpiresAt.getTime() > now.getTime()
  ) {
    return sendDay4Error(
      res,
      409,
      "REQUEST_ALREADY_CLAIMED",
      "Someone else just started helping with this request."
    );
  }

  return sendDay4Error(
    res,
    500,
    "INTERNAL_FAILURE",
    "Unable to claim this request right now."
  );
}

export async function claimRequest(
  req: Request,
  res: Response
): Promise<Response> {
  const id = req.params.id;
  if (isInvalidId(id)) {
    return sendDay4Error(
      res,
      400,
      "INVALID_REQUEST_ID",
      "The request ID is invalid."
    );
  }

  // This one captured instant drives the eligibility filter, all persisted
  // claim timestamps, failure classification, and the returned expiration.
  const now = new Date();
  const maximumClaimExpiration = new Date(now.getTime() + CLAIM_DURATION_MS);

  try {
    const secret = readClaimTokenHmacSecret();
    const rawToken = generateClaimToken();
    const tokenDigest = digestClaimToken(rawToken, secret);

    const document = await MealRequest.findOneAndUpdate(
      {
        _id: id,
        status: { $ne: "placed" },
        expiresAt: buildMinimumRemainingTimeFilter(now),
        $or: [
          { status: "open" },
          {
            status: "claimed",
            claimExpiresAt: { $lte: now },
          },
        ],
      },
      [
        {
          $set: {
            status: "claimed",
            claimedAt: now,
            claimExpiresAt: {
              $min: [maximumClaimExpiration, "$expiresAt"],
            },
            claimExtendedAt: null,
            claimTokenDigest: tokenDigest,
            updatedAt: now,
          },
        },
      ],
      { new: true }
    )
      .lean()
      .exec();

    if (!document) {
      return await explainClaimFailure(id, now, res);
    }

    const publicResponse = buildPublicRequestDetailResponse(
      document as unknown as PublicRequestDocument
    );
    return res.json({
      request: publicResponse.request,
      claim: {
        pickupName: document.pickupName,
        claimToken: rawToken,
        claimExpiresAt: document.claimExpiresAt,
      },
    });
  } catch {
    console.error("[route] Claim mutation failed");
    return sendDay4Error(
      res,
      500,
      "INTERNAL_FAILURE",
      "Unable to claim this request right now."
    );
  }
}

async function explainExtensionFailure(
  id: string,
  submittedDigest: string,
  now: Date,
  res: Response
): Promise<Response> {
  const document = await diagnosticRequest(id);
  if (!document) {
    return sendDay4Error(
      res,
      404,
      "REQUEST_NOT_FOUND",
      "This request could not be found."
    );
  }
  if (document.status === "placed") {
    return sendDay4Error(
      res,
      409,
      "REQUEST_ALREADY_PLACED",
      "This request has already been placed."
    );
  }
  if (isExpired(document.expiresAt, now)) {
    return sendDay4Error(
      res,
      410,
      "REQUEST_EXPIRED",
      "This request is no longer available."
    );
  }
  if (document.status !== "claimed") {
    return sendDay4Error(
      res,
      409,
      "REQUEST_NOT_CLAIMED",
      "This request does not have an active claim."
    );
  }
  // Expiration is classified before the digest. A claim that lapsed and was
  // replaced by another helper carries that helper's digest, so checking the
  // token first would tell the original holder their token is invalid when the
  // truth is that their claim ran out. Token validation is unchanged for an
  // active claim: the digest still gates every non-expired path below.
  if (isExpired(document.claimExpiresAt, now)) {
    return sendDay4Error(
      res,
      409,
      "CLAIM_EXPIRED",
      "This claim has expired."
    );
  }
  if (
    !claimTokenDigestMatches(document.claimTokenDigest, submittedDigest)
  ) {
    return sendDay4Error(
      res,
      403,
      "INVALID_CLAIM_TOKEN",
      "The claim token is missing or invalid."
    );
  }
  if (document.claimExtendedAt) {
    return sendDay4Error(
      res,
      409,
      "CLAIM_EXTENSION_ALREADY_USED",
      "This claim has already been extended."
    );
  }
  if (
    document.claimExpiresAt!.getTime() + CLAIM_EXTENSION_MS >
    document.expiresAt!.getTime()
  ) {
    return sendDay4Error(
      res,
      409,
      "CLAIM_EXTENSION_INSUFFICIENT_TIME",
      "There is not enough time remaining for a full extension."
    );
  }

  return sendDay4Error(
    res,
    500,
    "INTERNAL_FAILURE",
    "Unable to extend this claim right now."
  );
}

export async function extendClaim(
  req: Request,
  res: Response
): Promise<Response> {
  const id = req.params.id;
  if (isInvalidId(id)) {
    return sendDay4Error(
      res,
      400,
      "INVALID_REQUEST_ID",
      "The request ID is invalid."
    );
  }

  const rawToken =
    req.body &&
    typeof req.body === "object" &&
    Object.keys(req.body).length === 1
      ? req.body.claimToken
      : undefined;
  if (!isValidRawClaimToken(rawToken)) {
    return sendDay4Error(
      res,
      400,
      "INVALID_CLAIM_TOKEN",
      "The claim token is missing or invalid."
    );
  }

  // This one captured instant drives the active-claim filter, the persisted
  // extension timestamp, failure classification, and the response.
  const now = new Date();

  try {
    const secret = readClaimTokenHmacSecret();
    const submittedDigest = digestClaimToken(rawToken, secret);

    const document = await MealRequest.findOneAndUpdate(
      {
        _id: id,
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
    )
      .lean()
      .exec();

    if (!document) {
      return await explainExtensionFailure(
        id,
        submittedDigest,
        now,
        res
      );
    }

    return res.json({
      claim: {
        claimExpiresAt: document.claimExpiresAt,
        claimExtendedAt: document.claimExtendedAt,
      },
    });
  } catch {
    console.error("[route] Claim extension mutation failed");
    return sendDay4Error(
      res,
      500,
      "INTERNAL_FAILURE",
      "Unable to extend this claim right now."
    );
  }
}

export function pauseDay4Mutation(
  _req: Request,
  res: Response,
  next: NextFunction
): void {
  if (!isPublicActionsPaused()) {
    next();
    return;
  }

  res
    .status(503)
    .json(day4Error("PUBLIC_ACTIONS_PAUSED", CLAIM_UNAVAILABLE_MESSAGE));
}

export function createDay4MutationRateLimiter(max: number) {
  return rateLimit({
    windowMs: 60_000,
    max,
    standardHeaders: true,
    legacyHeaders: false,
    handler: (_req, res) =>
      res
        .status(429)
        .json(
          day4Error(
            "RATE_LIMITED",
            "Too many attempts. Please wait a moment and try again."
          )
        ),
  });
}

// Separate buckets prevent one step in a normal claim workflow from consuming
// the other mutation's allowance.
export const claimRateLimiter = createDay4MutationRateLimiter(10);
export const claimExtensionRateLimiter = createDay4MutationRateLimiter(10);
