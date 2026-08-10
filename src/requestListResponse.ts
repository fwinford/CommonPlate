import { isEffectivelyAvailable } from "./requestAvailability.js";

export type RequestResponseDate = Date | string;

export interface PublicRequestDocument {
  _id: unknown;
  vendor: string;
  food: string;
  pickupWindowText: string;
  /**
   * V1 meal-swipe requirement (W3-C1). Every shape `POST /api/request`
   * accepts, including the legacy web one, has required an integer 1-5 since
   * this slice — that is the production boundary this projection trusts,
   * not something it re-validates. A document reaching this projection
   * without one is a malformed/pre-C1 stored row, not a supported outcome of
   * any accepted submission, and is out of scope for this projection to
   * paper over.
   */
  mealSwipes: number;
  windowStart?: RequestResponseDate | null;
  windowEnd?: RequestResponseDate | null;
  status: string;
  createdAt: RequestResponseDate;
  /**
   * When helpers begin seeing this request. Read for availability only; it is
   * deliberately not projected onto the public response, which already carries
   * the same instant as `windowStart` for a scheduled request and as
   * `createdAt` for an ASAP one.
   */
  visibleFrom?: RequestResponseDate | null;
  expiresAt: RequestResponseDate;
  claimExpiresAt?: RequestResponseDate | null;
}

export interface RequestListDocument
  extends Omit<PublicRequestDocument, "expiresAt"> {
  expiresAt?: RequestResponseDate | null;
  claimExpiresAt?: RequestResponseDate | null;
}

export interface PublicRequestResponse<Status extends string = string> {
  id: string;
  vendor: string;
  food: string;
  pickupWindowText: string;
  mealSwipes: number;
  windowStart: RequestResponseDate | null;
  windowEnd: RequestResponseDate | null;
  status: Status;
  createdAt: RequestResponseDate;
  expiresAt: RequestResponseDate;
}

/**
 * The list advertises availability, not storage. An expired claim stays
 * persisted as `claimed` — nothing here mutates it — but a request that is
 * effectively available is advertised as `open`, so a single wire value never
 * has to mean both "claimable" and "someone is already helping".
 */
export interface PublicRequestListResponse {
  requests: PublicRequestResponse<"open">[];
}

export interface PublicRequestDetailResponse {
  request: PublicRequestResponse;
}

function dateValue(value: RequestResponseDate | null | undefined): number {
  return value == null ? Number.NaN : new Date(value).getTime();
}

function isAvailable(
  document: RequestListDocument,
  serverNow: Date
): document is RequestListDocument & {
  status: "open" | "claimed";
  expiresAt: RequestResponseDate;
} {
  return isEffectivelyAvailable(document, serverNow);
}

export function mapPublicRequestFields<Status extends string>(
  document: PublicRequestDocument & { status: Status }
): PublicRequestResponse<Status> {
  return {
    id: String(document._id),
    vendor: document.vendor,
    food: document.food,
    pickupWindowText: document.pickupWindowText,
    mealSwipes: document.mealSwipes,
    windowStart: document.windowStart ?? null,
    windowEnd: document.windowEnd ?? null,
    status: document.status,
    createdAt: document.createdAt,
    expiresAt: document.expiresAt,
  };
}

/**
 * Unlike the list, the detail response advertises a real, individually
 * fetched request, so an unavailable one still needs a truthful status
 * rather than being dropped. A claim-expired request is effectively
 * available again; every other status is reported as persisted.
 */
export function buildPublicRequestDetailResponse(
  document: PublicRequestDocument,
  serverNow: Date
): PublicRequestDetailResponse {
  const mapped = mapPublicRequestFields(document);
  return {
    request: {
      ...mapped,
      status: isEffectivelyAvailable(document, serverNow)
        ? "open"
        : mapped.status,
    },
  };
}

/**
 * Ordering only; membership is decided by `isEffectivelyAvailable` above.
 *
 * The imminent-versus-later split predates the W3-R1 visibility rule. Now that
 * a request is withheld until its own start, every document reaching this sort
 * has already begun, so the split no longer separates anything and the result
 * is creation order. It is left in place because it still orders correctly for
 * rows persisted before `visibleFrom` existed, which carry a future
 * `windowStart` and are advertised immediately. Retiring it is an ordering
 * decision, not part of the timing contract.
 */
export function buildPublicRequestListResponse(
  documents: RequestListDocument[],
  serverNow: Date
): PublicRequestListResponse {
  const hourLater = serverNow.getTime() + 60 * 60 * 1000;
  const available = documents.filter((document) =>
    isAvailable(document, serverNow)
  );

  available.sort((left, right) => {
    const leftWindowStart = dateValue(left.windowStart);
    const rightWindowStart = dateValue(right.windowStart);
    const leftIsAsap =
      Number.isNaN(leftWindowStart) || leftWindowStart <= hourLater;
    const rightIsAsap =
      Number.isNaN(rightWindowStart) || rightWindowStart <= hourLater;

    if (leftIsAsap !== rightIsAsap) {
      return leftIsAsap ? -1 : 1;
    }

    if (leftIsAsap) {
      return dateValue(left.createdAt) - dateValue(right.createdAt);
    }

    return leftWindowStart - rightWindowStart;
  });

  return {
    requests: available.slice(0, 20).map((document) => ({
      ...mapPublicRequestFields(document),
      // Derived from effective availability, never written back to the record.
      status: "open" as const,
    })),
  };
}
