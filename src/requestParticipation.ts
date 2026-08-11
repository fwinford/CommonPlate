import type { Request } from "express";
import mongoose from "mongoose";
import { RequestParticipation } from "../models/db.js";
import {
  resolveParticipantAuthority,
  type ResolvedParticipant,
} from "./participantAuthorityGate.js";

/**
 * Resolves the caller's verified participant identity when one is presented,
 * without ever refusing the call when it is not (W3-H2).
 *
 * Browsing/reading a request stays open to anyone (W3-I1): a missing,
 * malformed, or no-longer-valid credential here must degrade to "read as
 * though anonymous", never to a refusal — unlike every participant-gated
 * mutation, which is what `resolveParticipantAuthority` itself is for.
 */
export async function resolveOptionalParticipantAuthority(
  req: Request
): Promise<ResolvedParticipant | null> {
  const resolution = await resolveParticipantAuthority(req);
  return resolution.ok ? resolution.participant : null;
}

/**
 * The exact set of request ids this verified participant has ever
 * successfully held (the W3-H2 durable one-successful-participation record),
 * restricted to the supplied candidate ids.
 *
 * Used to remove a request from a verified participant's own marketplace
 * list after they have released or expired out of it — every other eligible
 * participant's view is unaffected, because this read and its filter are
 * always scoped to exactly one caller's own participant id.
 */
export async function findParticipatedRequestIds(
  participantId: string,
  candidateRequestIds: unknown[]
): Promise<Set<string>> {
  if (candidateRequestIds.length === 0) return new Set();

  const rows = await RequestParticipation.find({
    participantId: new mongoose.Types.ObjectId(participantId),
    requestId: { $in: candidateRequestIds },
  })
    .select("requestId")
    .lean()
    .exec();

  return new Set(
    rows.map((row) => String((row as { requestId: unknown }).requestId))
  );
}

/**
 * The W3-H2 marketplace-presentation filter behind `GET /api/requests`:
 * removes every request the resolved caller has ever successfully held from
 * their own list. `participant` is `null` for anonymous/unverified browsing
 * (W3-I1), which returns `docs` unfiltered and untouched rather than
 * refusing or querying anything. Every other eligible participant's own list
 * is unaffected, because the lookup and filter are always scoped to exactly
 * this one caller's own participant id.
 *
 * Extracted from the `GET /api/requests` handler in `app.ts` so this
 * behavior — list correctly excludes previously-held requests, other
 * eligible participants' lists are unaffected — has direct focused/Mongo
 * test coverage rather than only source inspection.
 */
export async function filterRequestListForParticipant<
  T extends { _id: unknown }
>(docs: T[], participant: ResolvedParticipant | null): Promise<T[]> {
  if (!participant || docs.length === 0) return docs;

  const participatedIds = await findParticipatedRequestIds(
    participant.participantId,
    docs.map((doc) => doc._id)
  );
  if (participatedIds.size === 0) return docs;

  return docs.filter((doc) => !participatedIds.has(String(doc._id)));
}
