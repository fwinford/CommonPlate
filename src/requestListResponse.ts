export type RequestListDate = Date | string;

export interface RequestListDocument {
  _id: unknown;
  vendor: string;
  food: string;
  pickupWindowText: string;
  windowStart?: RequestListDate | null;
  windowEnd?: RequestListDate | null;
  status: string;
  createdAt: RequestListDate;
  expiresAt?: RequestListDate | null;
}

export interface PublicRequestResponse {
  id: string;
  vendor: string;
  food: string;
  pickupWindowText: string;
  windowStart: RequestListDate | null;
  windowEnd: RequestListDate | null;
  status: "requested";
  createdAt: RequestListDate;
  expiresAt: RequestListDate;
}

export interface PublicRequestListResponse {
  requests: PublicRequestResponse[];
}

function dateValue(value: RequestListDate | null | undefined): number {
  return value == null ? Number.NaN : new Date(value).getTime();
}

function isAvailable(
  document: RequestListDocument,
  serverNow: Date
): document is RequestListDocument & {
  status: "requested";
  expiresAt: RequestListDate;
} {
  return (
    document.status === "requested" &&
    dateValue(document.expiresAt) > serverNow.getTime()
  );
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
      id: String(document._id),
      vendor: document.vendor,
      food: document.food,
      pickupWindowText: document.pickupWindowText,
      windowStart: document.windowStart ?? null,
      windowEnd: document.windowEnd ?? null,
      status: document.status,
      createdAt: document.createdAt,
      expiresAt: document.expiresAt,
    })),
  };
}
