import { isEffectivelyAvailable } from "./requestAvailability.js";

export type RequestResponseDate = Date | string;

export interface PublicRequestDocument {
  _id: unknown;
  vendor: string;
  food: string;
  pickupWindowText: string;
  windowStart?: RequestResponseDate | null;
  windowEnd?: RequestResponseDate | null;
  status: string;
  createdAt: RequestResponseDate;
  expiresAt: RequestResponseDate;
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
    windowStart: document.windowStart ?? null,
    windowEnd: document.windowEnd ?? null,
    status: document.status,
    createdAt: document.createdAt,
    expiresAt: document.expiresAt,
  };
}

export function buildPublicRequestDetailResponse(
  document: PublicRequestDocument
): PublicRequestDetailResponse {
  return {
    request: mapPublicRequestFields(document),
  };
}

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
