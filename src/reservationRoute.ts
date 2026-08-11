import type { Request, Response } from "express";
import mongoose from "mongoose";
import { Request as MealRequest } from "../models/db.js";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import { sendDay4Error } from "./day4Errors.js";
import {
  PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
  PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE,
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
} from "./participantAuthorityGate.js";
import {
  buildPublicRequestDetailResponse,
  type PublicRequestDocument,
} from "./requestListResponse.js";

export const ACTIVE_RESERVATION_ROUTE_PATH = "/api/participant/active-reservation";

// A read, not a mutation: more generous than the claim/extend/release
// buckets, and — like `GET /api/request/:id` — not gated by
// `PUBLIC_ACTIONS_PAUSED`, which exists to stop new mutations, not to hide a
// helper's own already-granted reservation from them.
export const activeReservationRateLimiter = createDay4MutationRateLimiter(30);

interface ActiveReservationDocument extends PublicRequestDocument {
  pickupName: string;
  claimExpiresAt?: Date | null;
  claimExtendedAt?: Date | null;
}

/**
 * A request this participant most recently placed, still existing within its
 * `PLACED_RETENTION_MS` retention horizon (W3-H2 fulfillment re-entry).
 * `notificationStatus` mirrors the persisted lifecycle value; `"pending"` and
 * absent both mean the outcome never settled (e.g. the process ended before
 * `recordNotificationOutcome` ran) and are reported the same way `fulfillRequest`
 * already treats an unsettled outcome — as unknown, never guessed.
 */
interface PlacedParticipationDocument extends PublicRequestDocument {
  notificationStatus?: "pending" | "sent" | "failed";
}

/**
 * `GET /api/participant/active-reservation` (W3-H1 continuation, extended by
 * W3-H2 fulfillment re-entry).
 *
 * Resolves "does this verified participant currently hold an active
 * reservation, and which one" directly from `Request.helperParticipantId` —
 * the same binding `claimRequest` writes and `fulfillmentRoute` already
 * reads — rather than from the Participant-side enforcement lock, which
 * exists only to make the claim transaction safe and is not itself exposed.
 * Never returns the raw claim token: it was never persisted, and continuation
 * consumes participant authority for extend/release instead. Client
 * presentation state is not authoritative; this response is what is.
 *
 * When this participant holds no active claimed reservation, the same
 * authoritative read additionally reports whether they most recently placed
 * a still-existing request (W3-H2): `Request.status === "placed"` plus this
 * `helperParticipantId` binding, retained until the existing `deleteAt`/
 * `PLACED_RETENTION_MS` TTL, is already durable proof that "this participant
 * placed this request" — `Fulfillment` carries no `participantId` and is not
 * the right anchor. This never recreates reservation authority and never
 * implies a second external order is available: it is a read of settled
 * placement truth only, so a relaunched client can restore Got It/
 * already-placed presentation instead of silently discarding it.
 */
export async function getActiveReservation(
  req: Request,
  res: Response
): Promise<Response> {
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }

  const now = new Date();
  const participantId = new mongoose.Types.ObjectId(
    authority.participant.participantId
  );
  try {
    const document = await MealRequest.findOne({
      helperParticipantId: participantId,
      status: "claimed",
      claimExpiresAt: { $gt: now },
    })
      .lean()
      .exec();

    if (document) {
      const reservation = document as unknown as ActiveReservationDocument;
      const publicResponse = buildPublicRequestDetailResponse(
        reservation,
        now
      );
      return res.json({
        reservation: {
          request: publicResponse.request,
          pickupName: reservation.pickupName,
          claimExpiresAt: reservation.claimExpiresAt,
          claimExtendedAt: reservation.claimExtendedAt ?? null,
        },
        placement: null,
      });
    }

    // `deleteAt` is authoritative retention, not the physical TTL sweep: Mongo's
    // TTL monitor runs on its own interval and does not delete a document the
    // instant `deleteAt` passes, so an unfiltered query here could resurrect a
    // request whose retention horizon has already elapsed merely because the
    // physical delete has not run yet. Compared against backend `now`, the same
    // instant already used for the active-claim read above.
    const placed = await MealRequest.findOne(
      {
        helperParticipantId: participantId,
        status: "placed",
        deleteAt: { $gt: now },
      },
      undefined,
      { sort: { placedAt: -1 } }
    )
      .lean()
      .exec();

    if (!placed) {
      return res.json({ reservation: null, placement: null });
    }
    const placedDocument = placed as unknown as PlacedParticipationDocument;
    const publicResponse = buildPublicRequestDetailResponse(
      placedDocument,
      now
    );
    return res.json({
      reservation: null,
      placement: {
        request: publicResponse.request,
        notification:
          placedDocument.notificationStatus === "sent" ||
          placedDocument.notificationStatus === "failed"
            ? { status: placedDocument.notificationStatus }
            : null,
      },
    });
  } catch {
    console.error("[route] Active reservation lookup failed");
    return sendDay4Error(
      res,
      503,
      PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
      PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE
    );
  }
}
