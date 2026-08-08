/**
 * The helper new-request push payload and its APNs headers.
 *
 * Pure: no configuration, no database, no secret. The payload may carry only
 * fields already public through `mapPublicRequestFields`, and the accepted
 * helper alert email already shows helpers exactly `vendor`, `food`, and
 * `pickupWindowText`. The push carries the same information plus the request
 * id a later tap-routing slice needs, and nothing else — never the requester's
 * email, the pickup name, a claim token or its digest, claim state, the
 * fulfiller, the installation credential, or the APNs token.
 */
export const HELPER_NEW_REQUEST_NOTIFICATION_TYPE = "new-request";
export const HELPER_NEW_REQUEST_THREAD_ID = "new-request";

/**
 * `vendor`, `food`, and `pickupWindowText` are requester-supplied free text.
 * Bounding each one keeps a single long field from crowding the visible alert
 * or approaching the 4 KB APNs payload limit.
 */
export const MAXIMUM_PUSH_TEXT_LENGTH = 80;

export class HelperPushPayloadError extends Error {}

export interface HelperPushRequest {
  _id: unknown;
  vendor: string;
  food: string;
  pickupWindowText: string;
  expiresAt?: Date | string | null;
}

export interface HelperNewRequestPayload {
  aps: {
    alert: { title: string; body: string };
    sound: "default";
    "interruption-level": "active";
    "thread-id": typeof HELPER_NEW_REQUEST_THREAD_ID;
  };
  type: typeof HELPER_NEW_REQUEST_NOTIFICATION_TYPE;
  requestId: string;
}

/** Bounded, whitespace-collapsed display text. */
export function boundPushText(value: unknown): string {
  const text = String(value ?? "").replace(/\s+/g, " ").trim();
  return text.length <= MAXIMUM_PUSH_TEXT_LENGTH
    ? text
    : `${text.slice(0, MAXIMUM_PUSH_TEXT_LENGTH - 1)}…`;
}

/**
 * An alert notification, never a silent `content-available` push: the accepted
 * product behavior requires a visible notification, including while
 * CommonPlate is in the foreground.
 */
export function buildHelperNewRequestPayload(
  request: HelperPushRequest
): HelperNewRequestPayload {
  const vendor = boundPushText(request.vendor);
  const food = boundPushText(request.food);
  const pickupWindowText = boundPushText(request.pickupWindowText);

  return {
    aps: {
      alert: {
        title: `New request at ${vendor}`,
        body: `${food} · ${pickupWindowText}`,
      },
      sound: "default",
      "interruption-level": "active",
      "thread-id": HELPER_NEW_REQUEST_THREAD_ID,
    },
    type: HELPER_NEW_REQUEST_NOTIFICATION_TYPE,
    // The routing identifier, and the only linkage the payload carries. It is
    // the same public `id` the list and detail responses already expose.
    requestId: String(request._id),
  };
}

export interface HelperNewRequestHeaderOptions {
  /** The configured bundle identifier. */
  topic: string;
}

/**
 * Everything but `authorization`, which the dispatcher adds from the cached
 * provider token at submission time. Keeping the provider JWT out of this
 * module means no pure builder — and no test of one — ever holds a secret.
 *
 * `apns-expiration` comes from the request's own availability deadline, so a
 * notification APNs could not deliver promptly is discarded rather than
 * surfacing after the request can no longer be helped. `apns-collapse-id` is
 * the request id, a second device-side guard against a duplicate banner.
 */
export function buildHelperNewRequestHeaders(
  request: HelperPushRequest,
  options: HelperNewRequestHeaderOptions
): Record<string, string> {
  const expiration = request.expiresAt == null
    ? Number.NaN
    : new Date(request.expiresAt).getTime();
  if (!Number.isFinite(expiration)) {
    throw new HelperPushPayloadError(
      "a helper new-request push requires the request's expiresAt"
    );
  }
  if (options.topic.trim() === "") {
    throw new HelperPushPayloadError(
      "a helper new-request push requires a configured apns-topic"
    );
  }

  return {
    "apns-push-type": "alert",
    "apns-priority": "10",
    "apns-topic": options.topic,
    "apns-collapse-id": String(request._id),
    "apns-expiration": String(Math.floor(expiration / 1000)),
    "content-type": "application/json",
  };
}
