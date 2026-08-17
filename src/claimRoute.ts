import type { NextFunction, Request, Response } from "express";
import rateLimit from "express-rate-limit";
import mongoose from "mongoose";
import {
  Participant,
  Request as MealRequest,
  RequestParticipation,
} from "../models/db.js";
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
import {
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
  type ParticipantAuthorityRefusal,
} from "./participantAuthorityGate.js";
import { isPublicActionsPaused } from "./publicActionsPause.js";
import {
  buildMinimumRemainingTimeFilter,
  buildVisibleNowFilter,
  hasMinimumRemainingTime,
  isVisibleNow,
  REQUEST_NOT_YET_AVAILABLE_CODE,
  REQUEST_NOT_YET_AVAILABLE_MESSAGE,
} from "./requestAvailability.js";

export const CLAIM_ROUTE_PATH = "/api/request/:id/claim";
export const CLAIM_EXTENSION_ROUTE_PATH = "/api/request/:id/claim/extend";
export const CLAIM_RELEASE_ROUTE_PATH = "/api/request/:id/claim/release";
export const CLAIM_DURATION_MS = 15 * 60 * 1000;
export const CLAIM_EXTENSION_MS = 5 * 60 * 1000;
export const CLAIM_UNAVAILABLE_MESSAGE =
  "Helping with meal requests is temporarily unavailable.";

export const HELPER_ALREADY_HAS_ACTIVE_RESERVATION_CODE =
  "HELPER_ALREADY_HAS_ACTIVE_RESERVATION";
export const HELPER_ALREADY_HAS_ACTIVE_RESERVATION_MESSAGE =
  "You already have an active reservation. Finish or release it before starting another.";

// W3-H2: once a verified participant has successfully acquired this exact
// request, they can never successfully acquire it again — not after release,
// not after passive expiry, not from another device or reinstall. Distinct
// from `HELPER_ALREADY_HAS_ACTIVE_RESERVATION` above: that refusal is about a
// *different* request the caller is still holding; this one is about this
// exact request's own durable history with this caller, and applies even
// when the caller currently holds no reservation at all.
export const REQUEST_ALREADY_PARTICIPATED_CODE = "REQUEST_ALREADY_PARTICIPATED";
export const REQUEST_ALREADY_PARTICIPATED_MESSAGE =
  "You've already helped with this request and can't reserve it again.";

// W4-H2: a verified participant can never successfully acquire a reservation
// on their own request. Distinct from `REQUEST_ALREADY_PARTICIPATED` above,
// which is about this caller's own prior *helper* history on the request;
// this is about the caller being the request's own requester, and applies
// regardless of whether they have ever attempted to help with it.
export const REQUEST_OWN_REQUEST_CODE = "REQUEST_OWN_REQUEST";
export const REQUEST_OWN_REQUEST_MESSAGE =
  "You can't help with your own request.";

interface ClaimDiagnosticDocument {
  status?: string;
  visibleFrom?: Date | null;
  expiresAt?: Date | null;
  claimExpiresAt?: Date | null;
  claimExtendedAt?: Date | null;
  claimTokenDigest?: string | null;
  helperParticipantId?: mongoose.Types.ObjectId | null;
}

function isInvalidId(id: unknown): boolean {
  return !mongoose.Types.ObjectId.isValid(String(id));
}

function diagnosticRequest(id: string) {
  return MealRequest.findById(id)
    .select(
      "status visibleFrom expiresAt claimExpiresAt claimExtendedAt +claimTokenDigest +helperParticipantId"
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
  // Ahead of the expiration checks: a request whose start has not arrived is
  // not late, and telling a helper it is "no longer available" would be the
  // opposite of true. Code and sentence are shared with the public-detail
  // refusal, so one situation has one answer wherever it is met.
  if (!isVisibleNow(document.visibleFrom, now)) {
    return sendDay4Error(
      res,
      409,
      REQUEST_NOT_YET_AVAILABLE_CODE,
      REQUEST_NOT_YET_AVAILABLE_MESSAGE
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

class ConditionalClaimFailure extends Error {}
/**
 * The target request was successfully claimed, but this exact verified
 * helper already holds a different active reservation elsewhere (W3-H1). The
 * Request-side claim is rolled back with the rest of the transaction: a
 * helper never ends up holding two reservations because the second half of
 * this check failed.
 */
class ActiveReservationConflict extends Error {}

/**
 * The target request was successfully claimed, but this exact verified
 * participant already holds a durable one-successful-participation record for
 * it (W3-H2). Rolled back with the rest of the transaction exactly like
 * `ActiveReservationConflict`: a reacquisition never ends up granted.
 */
class AlreadyParticipatedConflict extends Error {}

/**
 * The target request is the caller's own request (W4-H2). Rolled back with
 * the rest of the transaction, exactly like `AlreadyParticipatedConflict`: a
 * self-claim is never granted.
 */
class SelfClaimConflict extends Error {}

function isDuplicateKeyError(error: unknown): boolean {
  return (
    Boolean(error) &&
    typeof error === "object" &&
    (error as { code?: unknown }).code === 11000
  );
}

interface ClaimedRequestDocument extends PublicRequestDocument {
  pickupName: string;
  claimExpiresAt: Date;
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

  // The helper gate (W3-I1). Browsing requests stays open to anyone, but
  // reserving one is a participant action: it takes a real student's meal out
  // of everyone else's reach and commits a person to placing an order. Checked
  // before token generation and before the conditional mutation, so an
  // unverified caller reserves nothing and is told nothing about the request.
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }
  const participantId = new mongoose.Types.ObjectId(
    authority.participant.participantId
  );

  // This one captured instant drives the eligibility filter, all persisted
  // claim timestamps, failure classification, and the returned expiration.
  const now = new Date();
  const maximumClaimExpiration = new Date(now.getTime() + CLAIM_DURATION_MS);

  let session: mongoose.ClientSession | undefined;
  try {
    const secret = readClaimTokenHmacSecret();
    const rawToken = generateClaimToken();
    const tokenDigest = digestClaimToken(rawToken, secret);

    session = await mongoose.startSession();
    let claimedDocument: ClaimedRequestDocument | null = null;

    await session.withTransaction(
      async () => {
        // Rollout-compatibility gap (W3-H1): a claim granted before the
        // Participant lock below existed never wrote
        // `activeReservationRequestId`, so the lock-only check further down
        // cannot see it — that participant would read as lock-free even
        // while a real reservation is still live. This direct read closes
        // the gap by finding any *other* live claim already bound to this
        // participant, regardless of whether the lock was ever written for
        // it. Concurrency safety for two brand-new claims by the same
        // participant still comes from the Participant document's own
        // write-conflict detection below — this read only extends what
        // counts as "already reserved," it does not replace the lock.
        const existingActiveReservation = await MealRequest.findOne(
          {
            helperParticipantId: participantId,
            status: "claimed",
            claimExpiresAt: { $gt: now },
          },
          { _id: 1 },
          { session }
        )
          .lean()
          .exec();

        if (existingActiveReservation) {
          throw new ActiveReservationConflict();
        }

        // The W4-H2 self-claim guard, consulted inside the same
        // transaction/session as the grant that follows: a verified
        // participant can never successfully acquire a reservation on their
        // own request. `requesterParticipantId` is immutable after creation
        // (only `createRequestRoute` ever writes it), so this read is the
        // authoritative answer for the entire transaction — nothing else can
        // change it out from under this check. `+requesterParticipantId` is
        // required because the field is `select: false` on the schema.
        const ownershipCheck = await MealRequest.findById(
          id,
          null,
          { session }
        )
          .select("+requesterParticipantId")
          .lean()
          .exec();

        if (
          ownershipCheck?.requesterParticipantId &&
          String(ownershipCheck.requesterParticipantId) ===
            authority.participant.participantId
        ) {
          throw new SelfClaimConflict();
        }

        // The W3-H2 one-successful-participation invariant, consulted before
        // the conditional grant below: a participant who has ever
        // successfully acquired this exact request is refused regardless of
        // the request's current status (open, claimed, or claim-expired) or
        // who granted this read the request last. Read inside the same
        // transaction/session as the grant that follows, and backstopped by
        // the unique-index insert after a successful grant below — so a
        // reacquisition can never be granted even if this pre-check and the
        // insert somehow disagreed.
        const existingParticipation = await RequestParticipation.findOne(
          { requestId: id, participantId },
          { _id: 1 },
          { session }
        )
          .lean()
          .exec();

        if (existingParticipation) {
          throw new AlreadyParticipatedConflict();
        }

        const document = await MealRequest.findOneAndUpdate(
          {
            _id: id,
            status: { $ne: "placed" },
            // The same start-of-visibility rule the list, digest, and alert
            // paths apply. A request nobody can see yet must not be
            // claimable either.
            visibleFrom: buildVisibleNowFilter(now),
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
                // The reservation's owner, written in the same conditional
                // mutation that grants it, so a claim never exists without
                // the verified helper it belongs to. A request re-claimed
                // after an expired reservation is rebound to whoever won it
                // this time. Fulfillment reads this instead of accepting a
                // helper address.
                helperParticipantId: participantId,
                updatedAt: now,
              },
            },
          ],
          { new: true, session }
        )
          .lean()
          .exec();

        if (!document) {
          throw new ConditionalClaimFailure();
        }

        // One-active-reservation-per-verified-helper (W3-H1). Pinned to this
        // exact participant document, whose per-`_id` write conflict
        // detection is what makes this safe against a second concurrent
        // claim by the same principal on a *different* request — the two
        // transactions cannot both win a conditional update against the same
        // document, so only one commits.
        const lock = await Participant.findOneAndUpdate(
          {
            _id: participantId,
            $or: [
              { activeReservationRequestId: null },
              { activeReservationClaimExpiresAt: { $lte: now } },
            ],
          },
          {
            $set: {
              activeReservationRequestId: document._id,
              activeReservationClaimExpiresAt: (
                document as ClaimedRequestDocument
              ).claimExpiresAt,
            },
          },
          { session }
        ).exec();

        if (!lock) {
          throw new ActiveReservationConflict();
        }

        // The durable W3-H2 participation record, written atomically in the
        // same transaction as the grant it belongs to. A duplicate-key error
        // here means a concurrent transaction already recorded this exact
        // (request, participant) pair — the final backstop for the pre-check
        // above — and aborts this entire grant along with it.
        try {
          await RequestParticipation.create(
            [{ requestId: document._id, participantId }],
            { session }
          );
        } catch (participationError) {
          if (isDuplicateKeyError(participationError)) {
            throw new AlreadyParticipatedConflict();
          }
          throw participationError;
        }

        claimedDocument = document as unknown as ClaimedRequestDocument;
      },
      {
        readConcern: { level: "snapshot" },
        writeConcern: { w: "majority" },
      }
    );

    if (!claimedDocument) {
      throw new ConditionalClaimFailure();
    }
    // TypeScript cannot see through the transaction closure's assignment.
    const document = claimedDocument as ClaimedRequestDocument;

    const publicResponse = buildPublicRequestDetailResponse(document, now);
    return res.json({
      request: publicResponse.request,
      claim: {
        pickupName: document.pickupName,
        claimToken: rawToken,
        claimExpiresAt: document.claimExpiresAt,
      },
    });
  } catch (error) {
    if (error instanceof ActiveReservationConflict) {
      return sendDay4Error(
        res,
        409,
        HELPER_ALREADY_HAS_ACTIVE_RESERVATION_CODE,
        HELPER_ALREADY_HAS_ACTIVE_RESERVATION_MESSAGE
      );
    }
    if (error instanceof AlreadyParticipatedConflict) {
      return sendDay4Error(
        res,
        409,
        REQUEST_ALREADY_PARTICIPATED_CODE,
        REQUEST_ALREADY_PARTICIPATED_MESSAGE
      );
    }
    if (error instanceof SelfClaimConflict) {
      return sendDay4Error(
        res,
        409,
        REQUEST_OWN_REQUEST_CODE,
        REQUEST_OWN_REQUEST_MESSAGE
      );
    }
    if (error instanceof ConditionalClaimFailure) {
      return await explainClaimFailure(id, now, res);
    }
    console.error("[route] Claim mutation failed");
    return sendDay4Error(
      res,
      500,
      "INTERNAL_FAILURE",
      "Unable to claim this request right now."
    );
  } finally {
    if (session) {
      try {
        await session.endSession();
      } catch {
        console.error(
          "[route] MongoDB session cleanup failed after claim attempt"
        );
      }
    }
  }
}

/**
 * How a caller may authorize an action against an existing claim (extend,
 * release), once the raw claim token generated at claim time is no longer
 * available in-process (W3-H1 continuation).
 *
 * `token` is the original, unchanged authorization: the raw claim token
 * confirms possession of a specific reservation and is matched by digest,
 * exactly as before this slice.
 *
 * `participant` is additive: the caller's verified participant authority
 * (W3-I1), matched against the target request's own `helperParticipantId`.
 * It exists for the case the raw token is gone — after termination and
 * relaunch — and never replaces or weakens the token path, which stays
 * available for the still-in-process case.
 */
export type ClaimActionAuthorization =
  | { mode: "token"; digest: string }
  | { mode: "participant"; participantId: string };

export type ClaimActionAuthorizationRefusal =
  | { kind: "participant"; refusal: ParticipantAuthorityRefusal }
  | { kind: "invalidToken" }
  | { kind: "unavailable" };

/**
 * Distinguishes the two accepted request shapes for a claim action: a body
 * carrying exactly `{ claimToken }` (the original in-process path), or an
 * empty body carrying the participant-authority header (the continuation
 * path). Any other shape is refused before either credential is checked, the
 * same "answer nothing until the shape is right" posture `extendClaim`
 * already applied to the token-only body.
 */
async function resolveClaimActionAuthorization(
  req: Request
): Promise<
  | { ok: true; authorization: ClaimActionAuthorization }
  | { ok: false; refusal: ClaimActionAuthorizationRefusal }
> {
  const body = req.body;
  const isPlainObject =
    Boolean(body) && typeof body === "object" && !Array.isArray(body);
  const keys = isPlainObject ? Object.keys(body as Record<string, unknown>) : [];

  if (isPlainObject && keys.length === 1 && keys[0] === "claimToken") {
    const candidate = (body as Record<string, unknown>).claimToken;
    if (!isValidRawClaimToken(candidate)) {
      return { ok: false, refusal: { kind: "invalidToken" } };
    }
    try {
      const secret = readClaimTokenHmacSecret();
      const digest = digestClaimToken(candidate, secret);
      return { ok: true, authorization: { mode: "token", digest } };
    } catch {
      console.error("[route] Claim token secret unavailable");
      return { ok: false, refusal: { kind: "unavailable" } };
    }
  }

  if (isPlainObject && keys.length === 0) {
    const authority = await resolveParticipantAuthority(req);
    if (!authority.ok) {
      return {
        ok: false,
        refusal: { kind: "participant", refusal: authority.refusal },
      };
    }
    return {
      ok: true,
      authorization: {
        mode: "participant",
        participantId: authority.participant.participantId,
      },
    };
  }

  return { ok: false, refusal: { kind: "invalidToken" } };
}

function sendClaimActionAuthorizationRefusal(
  res: Response,
  refusal: ClaimActionAuthorizationRefusal,
  unavailableMessage: string
): Response {
  switch (refusal.kind) {
    case "participant":
      return sendParticipantAuthorityRefusal(res, refusal.refusal);
    case "invalidToken":
      return sendDay4Error(
        res,
        400,
        "INVALID_CLAIM_TOKEN",
        "The claim token is missing or invalid."
      );
    case "unavailable":
      return sendDay4Error(res, 500, "INTERNAL_FAILURE", unavailableMessage);
  }
}

function claimActionAuthorizationMatches(
  authorization: ClaimActionAuthorization,
  document: ClaimDiagnosticDocument
): boolean {
  if (authorization.mode === "token") {
    return claimTokenDigestMatches(
      document.claimTokenDigest,
      authorization.digest
    );
  }
  return (
    document.helperParticipantId != null &&
    String(document.helperParticipantId) === authorization.participantId
  );
}

function claimActionFilter(
  authorization: ClaimActionAuthorization
): Record<string, unknown> {
  return authorization.mode === "token"
    ? { claimTokenDigest: authorization.digest }
    : {
        helperParticipantId: new mongoose.Types.ObjectId(
          authorization.participantId
        ),
      };
}

async function explainExtensionFailure(
  id: string,
  now: Date,
  res: Response,
  authorization: ClaimActionAuthorization
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
  // Deliberately no start-of-visibility branch here, unlike the claim
  // diagnostic. Extension is only reachable by a caller who already holds a
  // claim, so a not-yet-visible request cannot legitimately arrive — and this
  // classification runs before authorization, so adding one would answer a
  // caller who has proved nothing.
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
  // Expiration is classified before authorization. A claim that lapsed and
  // was replaced by another helper carries that helper's credential, so
  // checking authorization first would tell the original holder their
  // credential is wrong when the truth is that their claim ran out.
  // Authorization is unchanged for an active claim: it still gates every
  // non-expired path below.
  if (isExpired(document.claimExpiresAt, now)) {
    return sendDay4Error(
      res,
      409,
      "CLAIM_EXPIRED",
      "This claim has expired."
    );
  }
  if (!claimActionAuthorizationMatches(authorization, document)) {
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

class ConditionalExtensionFailure extends Error {}

interface ExtendedRequestDocument {
  _id: mongoose.Types.ObjectId;
  claimExpiresAt: Date;
  claimExtendedAt: Date;
  helperParticipantId?: mongoose.Types.ObjectId | null;
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

  const resolution = await resolveClaimActionAuthorization(req);
  if (!resolution.ok) {
    return sendClaimActionAuthorizationRefusal(
      res,
      resolution.refusal,
      "Unable to extend this claim right now."
    );
  }
  const authorization = resolution.authorization;

  // This one captured instant drives the active-claim filter, the persisted
  // extension timestamp, failure classification, and the response.
  const now = new Date();
  let session: mongoose.ClientSession | undefined;

  try {
    session = await mongoose.startSession();
    let extendedDocument: ExtendedRequestDocument | null = null;

    await session.withTransaction(
      async () => {
        const document = await MealRequest.findOneAndUpdate(
          {
            _id: id,
            status: "claimed",
            claimExpiresAt: { $gt: now },
            claimExtendedAt: null,
            ...claimActionFilter(authorization),
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
          { new: true, session }
        )
          .select("+helperParticipantId")
          .lean()
          .exec();

        if (!document) {
          throw new ConditionalExtensionFailure();
        }
        const extended = document as unknown as ExtendedRequestDocument;

        // Mirrors the new deadline onto the one-active-reservation lock so a
        // just-extended claim cannot be mistaken for a stale one that no
        // longer blocks a fresh claim by the same principal. A
        // pre-W3-I1 legacy claim has no `helperParticipantId` and therefore
        // no lock to mirror; nothing here needs to run for it.
        if (extended.helperParticipantId) {
          // Owning the exact lock is now mandatory for the extension to
          // commit at all (independent-review MUST FIX 2), not merely a
          // best-effort mirror. A stale/delayed extension whose lock has
          // since moved to a later reservation — because the old claim
          // genuinely expired and this same participant reserved something
          // else in the meantime — must never durably renew this Request's
          // deadline; that would leave the participant holding two live
          // reservations at once. The `$or` accepts the lock either already
          // pointing at this exact request (the ordinary case) or never
          // having been written for it at all — a pre-H1 claim, self-healed
          // here rather than refused, matching the accepted rollout-
          // compatibility handling `claimRequest`'s own direct read applies.
          // It never accepts the lock pointing at a *different* request:
          // that is exactly the race this closes.
          const lockSync = await Participant.updateOne(
            {
              _id: extended.helperParticipantId,
              $or: [
                { activeReservationRequestId: extended._id },
                { activeReservationRequestId: null },
              ],
            },
            {
              $set: {
                activeReservationRequestId: extended._id,
                activeReservationClaimExpiresAt: extended.claimExpiresAt,
              },
            },
            { session }
          ).exec();

          if (lockSync.matchedCount === 0) {
            throw new ConditionalExtensionFailure();
          }
        }

        extendedDocument = extended;
      },
      {
        readConcern: { level: "snapshot" },
        writeConcern: { w: "majority" },
      }
    );

    if (!extendedDocument) {
      throw new ConditionalExtensionFailure();
    }
    const document = extendedDocument as ExtendedRequestDocument;

    return res.json({
      claim: {
        claimExpiresAt: document.claimExpiresAt,
        claimExtendedAt: document.claimExtendedAt,
      },
    });
  } catch (error) {
    if (error instanceof ConditionalExtensionFailure) {
      return await explainExtensionFailure(id, now, res, authorization);
    }
    console.error("[route] Claim extension mutation failed");
    return sendDay4Error(
      res,
      500,
      "INTERNAL_FAILURE",
      "Unable to extend this claim right now."
    );
  } finally {
    if (session) {
      try {
        await session.endSession();
      } catch {
        console.error(
          "[route] MongoDB session cleanup failed after extension attempt"
        );
      }
    }
  }
}

async function explainReleaseFailure(
  id: string,
  now: Date,
  res: Response,
  authorization: ClaimActionAuthorization
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
  // Pinned by the release mutation's own filter (`status: "claimed"`): a
  // placed request can never be the row this update matched, so this is a
  // truthful classification of why release found nothing to do, never a
  // path that could itself reopen a placement.
  if (document.status === "placed") {
    return sendDay4Error(
      res,
      409,
      "REQUEST_ALREADY_PLACED",
      "This request has already been placed."
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
  if (isExpired(document.claimExpiresAt, now)) {
    return sendDay4Error(
      res,
      409,
      "CLAIM_EXPIRED",
      "This claim has expired."
    );
  }
  if (!claimActionAuthorizationMatches(authorization, document)) {
    return sendDay4Error(
      res,
      403,
      "INVALID_CLAIM_TOKEN",
      "The claim token is missing or invalid."
    );
  }

  return sendDay4Error(
    res,
    500,
    "INTERNAL_FAILURE",
    "Unable to release this reservation right now."
  );
}

class ConditionalReleaseFailure extends Error {}

interface ReleaseReservationVersion {
  claimExpiresAt: Date;
  claimExtendedAt?: Date | null;
}

interface ReleasedRequestDocument {
  _id: mongoose.Types.ObjectId;
  helperParticipantId?: mongoose.Types.ObjectId | null;
}

/**
 * Captures the reservation version this release attempt originally met.
 *
 * This read deliberately happens once, outside `withTransaction`: the Mongo
 * driver may invoke a transaction callback again after a transient write
 * conflict, but a retry must not silently adopt an extension that committed
 * after this release began. `claimExpiresAt` changes on every extension, and
 * `claimExtendedAt` records the one-use transition, so together they are the
 * existing reservation-version CAS without adding persistence or wire state.
 */
async function readReleaseReservationVersion(
  id: string
): Promise<ReleaseReservationVersion | null> {
  const document = (await MealRequest.findById(id)
    .select("claimExpiresAt claimExtendedAt")
    .lean()
    .exec()) as ReleaseReservationVersion | null;

  if (!document?.claimExpiresAt) return null;
  return {
    claimExpiresAt: document.claimExpiresAt,
    ...(document.claimExtendedAt === undefined
      ? {}
      : { claimExtendedAt: document.claimExtendedAt }),
  };
}

function releaseVersionFilter(
  version: ReleaseReservationVersion,
  now: Date
): Record<string, unknown> {
  return {
    // `$gt` preserves the existing active-claim deadline gate while `$eq`
    // prevents a driver retry from releasing a newer extension.
    claimExpiresAt: {
      $gt: now,
      $eq: version.claimExpiresAt,
    },
    claimExtendedAt:
      version.claimExtendedAt === undefined
        ? { $exists: false }
        // MongoDB's bare `{ field: null }` also matches an absent field.
        // H1 rows write an explicit null, while pre-H1 rows may physically
        // omit this marker, so preserve the representation captured above.
        : version.claimExtendedAt === null
          ? { $eq: null, $exists: true }
          : version.claimExtendedAt,
  };
}

/**
 * Explicit release (W3-H1, new). Atomically invalidates only the caller's
 * still-active reservation and restores the request to `open`, pinned to
 * `status: "claimed"` plus the matching authorization exactly as
 * `claimRequest`, `extendClaim`, and `fulfillmentRoute`'s placement mutation
 * already pin their own conditional updates — so release can never reopen a
 * `placed` request and can never release a different helper's reservation.
 *
 * Because release and fulfillment both pivot on the same
 * `status: "claimed"` → terminal-state conditional mutation, whichever
 * mutation's filter matches first simply wins; the other's conditional
 * update misses and is classified by `explainReleaseFailure` /
 * `explainConditionalFailure` exactly as any other lost race already is. No
 * new concurrency primitive is required.
 */
export async function releaseClaim(
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

  const resolution = await resolveClaimActionAuthorization(req);
  if (!resolution.ok) {
    return sendClaimActionAuthorizationRefusal(
      res,
      resolution.refusal,
      "Unable to release this reservation right now."
    );
  }
  const authorization = resolution.authorization;

  const now = new Date();
  let session: mongoose.ClientSession | undefined;

  try {
    // Immutable across every callback invocation `withTransaction` may make.
    // If extension moves the reservation to a new deadline after this read,
    // the release CAS below misses on retry instead of adopting that version.
    const originalVersion = await readReleaseReservationVersion(id);
    if (!originalVersion) {
      throw new ConditionalReleaseFailure();
    }

    session = await mongoose.startSession();
    let released: ReleasedRequestDocument | null = null;

    await session.withTransaction(
      async () => {
        // `new: false` (the default) returns the pre-release document, which
        // still carries `helperParticipantId` — needed a moment later to
        // clear that participant's reservation lock. The unset fields put
        // this request back exactly where an unclaimed request already
        // stands: nothing here distinguishes a released request from one
        // that was never claimed.
        const document = await MealRequest.findOneAndUpdate(
          {
            _id: id,
            status: "claimed",
            // The exact version captured before this transaction started.
            ...releaseVersionFilter(originalVersion, now),
            ...claimActionFilter(authorization),
          },
          {
            $set: { status: "open", updatedAt: now },
            $unset: {
              claimedAt: 1,
              claimExpiresAt: 1,
              claimExtendedAt: 1,
              claimTokenDigest: 1,
              helperParticipantId: 1,
            },
          },
          { session }
        )
          .select("+helperParticipantId")
          .lean()
          .exec();

        if (!document) {
          throw new ConditionalReleaseFailure();
        }
        const releasedDocument = document as unknown as ReleasedRequestDocument;

        if (releasedDocument.helperParticipantId) {
          await Participant.updateOne(
            {
              _id: releasedDocument.helperParticipantId,
              activeReservationRequestId: releasedDocument._id,
            },
            {
              $set: {
                activeReservationRequestId: null,
                activeReservationClaimExpiresAt: null,
              },
            },
            { session }
          ).exec();
        }

        released = releasedDocument;
      },
      {
        readConcern: { level: "snapshot" },
        writeConcern: { w: "majority" },
      }
    );

    if (!released) {
      throw new ConditionalReleaseFailure();
    }

    return res.json({ released: true });
  } catch (error) {
    if (error instanceof ConditionalReleaseFailure) {
      return await explainReleaseFailure(id, now, res, authorization);
    }
    console.error("[route] Claim release mutation failed");
    return sendDay4Error(
      res,
      500,
      "INTERNAL_FAILURE",
      "Unable to release this reservation right now."
    );
  } finally {
    if (session) {
      try {
        await session.endSession();
      } catch {
        console.error(
          "[route] MongoDB session cleanup failed after release attempt"
        );
      }
    }
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
export const claimReleaseRateLimiter = createDay4MutationRateLimiter(10);
