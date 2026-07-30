export const CLAIM_MINIMUM_REMAINING_MS = 5 * 60 * 1000;

export interface AvailabilityDocument {
  status: string;
  expiresAt?: Date | string | null;
  claimExpiresAt?: Date | string | null;
}

function dateValue(value: Date | string | null | undefined): number {
  return value == null ? Number.NaN : new Date(value).getTime();
}

/**
 * MongoDB filter for requests that can truthfully be advertised to helpers.
 * Expired claims remain stored as `claimed`; availability is derived without
 * mutating them from a GET or notification path.
 */
export function buildEffectiveAvailabilityFilter(now: Date) {
  return {
    expiresAt: { $gt: now },
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
  const expiration = dateValue(document.expiresAt);
  if (!Number.isFinite(expiration) || expiration <= now.getTime()) {
    return false;
  }

  return (
    document.status === "open" ||
    (document.status === "claimed" &&
      dateValue(document.claimExpiresAt) <= now.getTime())
  );
}
