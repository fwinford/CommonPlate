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
 * `GET /api/participant/active-reservation` (W3-H1 continuation).
 *
 * Resolves "does this verified participant currently hold an active
 * reservation, and which one" directly from `Request.helperParticipantId` —
 * the same binding `claimRequest` writes and `fulfillmentRoute` already
 * reads — rather than from the Participant-side enforcement lock, which
 * exists only to make the claim transaction safe and is not itself exposed.
 * Never returns the raw claim token: it was never persisted, and continuation
 * consumes participant authority for extend/release instead. Client
 * presentation state is not authoritative; this response is what is.
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
  try {
    const document = await MealRequest.findOne({
      helperParticipantId: new mongoose.Types.ObjectId(
        authority.participant.participantId
      ),
      status: "claimed",
      claimExpiresAt: { $gt: now },
    })
      .lean()
      .exec();

    if (!document) {
      return res.json({ reservation: null });
    }
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
