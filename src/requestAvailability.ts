/**
 * Five full minutes is the single eligibility threshold. It gates the atomic
 * claim mutation, so every path that advertises a request has to apply the same
 * threshold: advertising a request with less time left would offer help that is
 * guaranteed to fail with `REQUEST_INSUFFICIENT_TIME`.
 */
export const CLAIM_MINIMUM_REMAINING_MS = 5 * 60 * 1000;

export interface AvailabilityDocument {
  status: string;
  expiresAt?: Date | string | null;
  claimExpiresAt?: Date | string | null;
  visibleFrom?: Date | string | null;
}

function dateValue(value: Date | string | null | undefined): number {
  return value == null ? Number.NaN : new Date(value).getTime();
}

/** Earliest `expiresAt` that still leaves five full minutes after `now`. */
function minimumEligibleExpiration(now: Date): Date {
  return new Date(now.getTime() + CLAIM_MINIMUM_REMAINING_MS);
}

/**
 * The canonical minimum-remaining-time rule, as a MongoDB `expiresAt` clause.
 * Exactly five minutes remaining qualifies — the bound is inclusive — so the
 * last advertised instant is also the last claimable instant.
 *
 * `$gt: now` is implied by the minimum and kept only as an explicit expiration
 * guard; both bounds are computed from the one instant the caller captured.
 */
export function buildMinimumRemainingTimeFilter(now: Date) {
  return { $gt: now, $gte: minimumEligibleExpiration(now) };
}

/** In-memory form of {@link buildMinimumRemainingTimeFilter}. Fails closed. */
export function hasMinimumRemainingTime(
  expiresAt: Date | string | null | undefined,
  now: Date
): boolean {
  const expiration = dateValue(expiresAt);
  return (
    Number.isFinite(expiration) &&
    expiration >= minimumEligibleExpiration(now).getTime()
  );
}

/**
 * The one outcome for a request whose start has not arrived, shared by every
 * route that has to answer for one. Kept here, beside the rule that decides it,
 * so the claim refusal and the public-detail refusal cannot drift into two
 * different codes or two different sentences for the same situation.
 *
 * It is deliberately not the not-found outcome: a request that has not begun
 * exists, and telling a helper it does not would be a lie they might act on by
 * giving up on it. It is equally not "no longer available" — nothing has run
 * out. The message says the one true thing and implies the one useful move.
 */
export const REQUEST_NOT_YET_AVAILABLE_CODE = "REQUEST_NOT_YET_AVAILABLE";
export const REQUEST_NOT_YET_AVAILABLE_MESSAGE =
  "This request is not available to help with yet.";

/**
 * The canonical start-of-visibility rule, as a MongoDB `visibleFrom` clause.
 * A request must not be advertised, notified about, or claimed before the
 * instant its requester chose (`src/requestTiming.ts`).
 *
 * Written as `$not: { $gt: now }` rather than `$lte: now` for one reason: it
 * is a single-key clause that also matches documents which carry no
 * `visibleFrom` at all. Requests persisted before this field existed were
 * visible from creation, and no slice migrates them, so a missing value keeps
 * meaning exactly that. `$lte` would silently hide every one of them.
 *
 * The bound is inclusive at the start: a request is visible at its start
 * instant, not one millisecond after it.
 */
export function buildVisibleNowFilter(now: Date) {
  return { $not: { $gt: now } };
}

/** In-memory form of {@link buildVisibleNowFilter}. */
export function isVisibleNow(
  visibleFrom: Date | string | null | undefined,
  now: Date
): boolean {
  // Same legacy allowance as the database clause: no start recorded means the
  // request was visible from creation. An unparseable one is not a legacy
  // absence, so it fails closed.
  if (visibleFrom == null) return true;
  const start = dateValue(visibleFrom);
  return Number.isFinite(start) && start <= now.getTime();
}

/**
 * MongoDB filter for requests that can truthfully be advertised to helpers.
 * Expired claims remain stored as `claimed`; availability is derived without
 * mutating them from a GET or notification path.
 */
export function buildEffectiveAvailabilityFilter(now: Date) {
  return {
    visibleFrom: buildVisibleNowFilter(now),
    expiresAt: buildMinimumRemainingTimeFilter(now),
    $or: [
      { status: "open" },
      {
        status: "claimed",
        claimExpiresAt: { $lte: now },
      },
    ],
  };
}

export function isEffectivelyAvailable(
  document: AvailabilityDocument,
  now: Date
): boolean {
  if (!isVisibleNow(document.visibleFrom, now)) {
    return false;
  }

  if (!hasMinimumRemainingTime(document.expiresAt, now)) {
    return false;
  }

  return (
    document.status === "open" ||
    (document.status === "claimed" &&
      dateValue(document.claimExpiresAt) <= now.getTime())
  );
}
