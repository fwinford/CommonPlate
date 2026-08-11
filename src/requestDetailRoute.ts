import type { NextFunction, Request, Response } from "express";
import mongoose from "mongoose";
import { Request as MealRequest } from "../models/db.js";
import { sendDay4Error } from "./day4Errors.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  findParticipatedRequestIds,
  resolveOptionalParticipantAuthority,
} from "./requestParticipation.js";
import {
  isVisibleNow,
  REQUEST_NOT_YET_AVAILABLE_CODE,
  REQUEST_NOT_YET_AVAILABLE_MESSAGE,
} from "./requestAvailability.js";
import {
  buildPublicRequestDetailResponse,
  type PublicRequestDocument,
} from "./requestListResponse.js";

export async function getPublicRequestDetail(
  req: Request,
  res: Response,
  next: NextFunction
): Promise<Response | void> {
  // W3-H2: this response is now caller-specific (`alreadyParticipated` can
  // differ per verified participant for the identical request id), so no
  // shared or private HTTP cache may ever store or reuse one caller's
  // answer for another. Set first, ahead of every return path below —
  // including the 400/404/409 refusals and the error-delegated 500 — so
  // none of them can be cached either. `Vary` on the participant-authority
  // header is defense in depth alongside `no-store`, for any intermediary
  // that inspects it before honoring `no-store`.
  res.setHeader("Cache-Control", "private, no-store");
  res.setHeader("Vary", PARTICIPANT_AUTHORITY_HEADER);

  try {
    const { id } = req.params;
    if (!mongoose.Types.ObjectId.isValid(String(id))) {
      return res.status(400).json({ error: "Invalid request id" });
    }

    // One instant decides both the visibility gate below and the effective
    // status of the response, so the two cannot disagree about the same read.
    const now = new Date();

    const document = await MealRequest.findById(id).lean().exec();
    if (!document) {
      return res.status(404).json({ error: "Request not found" });
    }

    // A scheduled request withheld from the list must also be withheld here.
    // Otherwise this route is the hole in the W3-R1 visibility rule: knowing
    // an id — from a shared link, an enumeration attempt, or a notification
    // that should not have been sent yet — would return the vendor, the food,
    // the pickup window, and a status of `open`, hours before helpers are
    // meant to see any of it.
    //
    // The refusal carries no request content of any kind: only the shared
    // not-yet-available code and sentence, which are the same ones the claim
    // route answers with. It is deliberately distinct from the 404 below,
    // which keeps meaning exactly one thing — no such request — so a client
    // can tell "come back later" apart from "this is gone" without either
    // answer describing the request itself.
    //
    // Legacy rows carry no `visibleFrom`, and `isVisibleNow` reads that
    // absence as "visible from creation", so nothing persisted before this
    // field existed becomes unreachable.
    if (!isVisibleNow((document as { visibleFrom?: Date }).visibleFrom, now)) {
      return sendDay4Error(
        res,
        409,
        REQUEST_NOT_YET_AVAILABLE_CODE,
        REQUEST_NOT_YET_AVAILABLE_MESSAGE
      );
    }

    const response = buildPublicRequestDetailResponse(
      document as unknown as PublicRequestDocument,
      now
    );

    // W3-H2 stale detail Reserve truth: browsing stays open to anyone
    // (W3-I1), so an absent or unusable credential here degrades to the
    // ordinary public response rather than refusing the read. When the
    // caller does present a verified participant identity, this is the same
    // durable participation truth `/api/requests` already filters its own
    // list by (`findParticipatedRequestIds`) — a stale detail screen reached
    // through direct navigation, a deep link, or a not-yet-refreshed list can
    // now be told this participant already successfully held this exact
    // request, so it can withdraw the Reserve affordance instead of only
    // discovering the refusal after a tap. `claimRequest`'s own conditional
    // grant remains the authoritative backstop regardless of this flag.
    const participant = await resolveOptionalParticipantAuthority(req);
    if (participant) {
      const participatedIds = await findParticipatedRequestIds(
        participant.participantId,
        [document._id]
      );
      if (participatedIds.has(String(document._id))) {
        return res.json({ ...response, alreadyParticipated: true });
      }
    }

    return res.json(response);
  } catch (err) {
    next(err);
  }
}
