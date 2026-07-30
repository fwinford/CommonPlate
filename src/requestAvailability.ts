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
 * MongoDB filter for requests that can truthfully be advertised to helpers.
 * Expired claims remain stored as `claimed`; availability is derived without
 * mutating them from a GET or notification path.
 */
export function buildEffectiveAvailabilityFilter(now: Date) {
  return {
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
  if (!hasMinimumRemainingTime(document.expiresAt, now)) {
    return false;
  }

  return (
    document.status === "open" ||
    (document.status === "claimed" &&
      dateValue(document.claimExpiresAt) <= now.getTime())
  );
}
