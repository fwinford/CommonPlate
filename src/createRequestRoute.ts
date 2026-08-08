import type { Request, Response } from "express";
import type { Types } from "mongoose";
import { Resend } from "resend";
import { z } from "zod";
import { Request as MealRequest } from "../models/db.js";
import {
  NYU_EMAIL_REQUIRED_MESSAGE,
  hasAllowedEmailDomain,
} from "./allowedEmailDomains.js";
import { escapeHtml } from "./htmlEscape.js";
import { startHelperNewRequestPush } from "./helperNewRequestPush.js";
import { isValidRawInstallationCredential } from "./installationCredential.js";
import { notifySubscribersForRequest } from "./notifySubscribers.js";
import { resolveRequestInstallationAssociation } from "./requestInstallationAssociation.js";
import {
  isSupportedVendor,
  UNSUPPORTED_VENDOR_MESSAGE,
} from "./supportedVendors.js";
import {
  buildPublicRequestDetailResponse,
  type PublicRequestDocument,
} from "./requestListResponse.js";
import { formatMealRequestWindow } from "./utils/date.js";
import { createDay4MutationRateLimiter } from "./claimRoute.js";

/**
 * Per-IP create throttle that returns the structured error envelope. Because
 * create is non-idempotent, iOS must distinguish this definitive pre-write
 * refusal from an unreadable, potentially committed response.
 */
export const createRequestRateLimiter = createDay4MutationRateLimiter(5);

const requesterString = z.string().trim().min(1);
/**
 * The shape rule only. A present, non-blank `email` is a well-formed payload;
 * whether the address itself is usable is decided by `isEligibleRequesterEmail`
 * after the whole payload has passed, so a missing or blank address stays the
 * same structural failure as a missing `vendor` rather than becoming an
 * address problem the requester is told to fix.
 */
const requesterEmail = z.string().trim().toLowerCase().min(1);
/**
 * Syntax plus the shared exact-domain allowlist, applied to the already
 * trimmed and lowercased value. `.email()` is the same syntax check this route
 * has always used; the allowlist is the one `POST /api/subscribe` enforces.
 */
const eligibleRequesterEmail = z
  .string()
  .email()
  .refine(hasAllowedEmailDomain);
const isoTimestamp = z.iso.datetime({ offset: true });

/**
 * iOS sends its existing installation credential with request creation
 * (Week 3 Day 6 Slice 6E) so the backend can resolve/establish the
 * originating installation for a later best-effort fulfillment push. Web
 * requests carry none, and stay valid without one — this is optional on
 * every schema that has it, never required. A present-but-malformed value is
 * a structural failure, exactly like every other malformed field on this
 * route, rather than a dedicated error code of its own.
 */
const optionalInstallationCredential = z
  .string()
  .refine(isValidRawInstallationCredential)
  .optional();

const requesterFields = {
  vendor: requesterString,
  food: requesterString,
  pickupName: requesterString,
  email: requesterEmail,
};

const canonicalAsapSchema = z
  .object({
    ...requesterFields,
    timing: z.literal("asap"),
    installationCredential: optionalInstallationCredential,
  })
  .strict();

const canonicalScheduledSchema = z
  .object({
    ...requesterFields,
    timing: z.literal("scheduled"),
    windowStart: isoTimestamp,
    windowEnd: isoTimestamp,
    installationCredential: optionalInstallationCredential,
  })
  .strict()
  .refine(
    ({ windowStart, windowEnd }) =>
      new Date(windowEnd).getTime() > new Date(windowStart).getTime(),
    {
      path: ["windowEnd"],
      message: "windowEnd must be after windowStart",
    }
  );

const canonicalSchema = z.union([
  canonicalAsapSchema,
  canonicalScheduledSchema,
]);

const legacyWebSchema = z
  .object({
    ...requesterFields,
    pickupWindowText: requesterString,
    windowStart: isoTimestamp.optional(),
    windowEnd: isoTimestamp.optional(),
  })
  .strict()
  .superRefine(({ windowStart, windowEnd }, context) => {
    if ((windowStart === undefined) !== (windowEnd === undefined)) {
      context.addIssue({
        code: "custom",
        path: [windowStart === undefined ? "windowStart" : "windowEnd"],
        message: "Legacy scheduled requests require both window fields",
      });
      return;
    }

    if (
      windowStart !== undefined &&
      windowEnd !== undefined &&
      new Date(windowEnd).getTime() <= new Date(windowStart).getTime()
    ) {
      context.addIssue({
        code: "custom",
        path: ["windowEnd"],
        message: "windowEnd must be after windowStart",
      });
    }
  });

interface ValidatedCreateRequest {
  vendor: string;
  food: string;
  pickupName: string;
  email: string;
  timing: "asap" | "scheduled";
  windowStart?: Date;
  windowEnd?: Date;
  pickupWindowText: string;
  /** Present only on the canonical iOS shapes; the legacy web shape has none. */
  installationCredential?: string;
}

const resend = new Resend(process.env.RESEND_API_KEY);

/**
 * How long an ASAP request stays available after backend creation.
 *
 * This is an absolute duration between two instants, not a calendar offset,
 * so it is unaffected by day boundaries or DST transitions.
 */
const ASAP_LIFETIME_MS = 5 * 60 * 60 * 1000;

/**
 * Backend-owned expiration. The client never supplies it — both create
 * schemas are `.strict()`, and this value is written explicitly rather than
 * left to the schema's 24-hour `pre("save")` fallback, so the persisted
 * expiration always matches what the requester is told.
 *
 * ASAP: five hours after the backend creation time.
 * Scheduled: the validated canonical `windowEnd`, so a request cannot outlive
 * the pickup window it was posted for. Validation guarantees that end is still
 * in the future, so a created request is never already expired.
 */
function requestExpiration(
  validated: ValidatedCreateRequest,
  createdAt: Date
): Date {
  if (validated.timing === "scheduled" && validated.windowEnd) {
    return validated.windowEnd;
  }
  return new Date(createdAt.getTime() + ASAP_LIFETIME_MS);
}

function errorEnvelope(code: string, message: string) {
  return { error: { code, message } };
}

function hasTiming(value: unknown): boolean {
  return (
    typeof value === "object" &&
    value !== null &&
    Object.prototype.hasOwnProperty.call(value, "timing")
  );
}

/**
 * A scheduled window must still have time left on it. Since `expiresAt` is the
 * validated `windowEnd`, a window that has already ended would create a request
 * that is expired the moment it is written — invisible to every helper.
 *
 * Only the end is checked against server time. A window that has already
 * started but has not ended is still usable, so `windowStart` is deliberately
 * allowed to be in the past; `windowEnd > windowStart` is enforced separately
 * by the schemas.
 */
function isUsableScheduledWindow(windowEnd: Date, now: Date): boolean {
  return windowEnd.getTime() > now.getTime();
}

function validateCreateShape(
  body: unknown,
  now: Date
): ValidatedCreateRequest | null {
  if (hasTiming(body)) {
    const result = canonicalSchema.safeParse(body);
    if (!result.success) return null;

    if (result.data.timing === "asap") {
      return {
        vendor: result.data.vendor,
        food: result.data.food,
        pickupName: result.data.pickupName,
        email: result.data.email,
        timing: "asap",
        pickupWindowText: "ASAP (within the next 5 hours)",
        installationCredential: result.data.installationCredential,
      };
    }

    const windowStart = new Date(result.data.windowStart);
    const windowEnd = new Date(result.data.windowEnd);
    if (!isUsableScheduledWindow(windowEnd, now)) return null;

    return {
      vendor: result.data.vendor,
      food: result.data.food,
      pickupName: result.data.pickupName,
      email: result.data.email,
      timing: "scheduled",
      windowStart,
      windowEnd,
      pickupWindowText: formatMealRequestWindow(windowStart, windowEnd),
      installationCredential: result.data.installationCredential,
    };
  }

  const result = legacyWebSchema.safeParse(body);
  if (!result.success) return null;

  if (
    result.data.windowStart === undefined &&
    result.data.windowEnd === undefined
  ) {
    return {
      vendor: result.data.vendor,
      food: result.data.food,
      pickupName: result.data.pickupName,
      email: result.data.email,
      timing: "asap",
      pickupWindowText: "ASAP (within the next 5 hours)",
    };
  }

  const windowStart = new Date(result.data.windowStart!);
  const windowEnd = new Date(result.data.windowEnd!);
  if (!isUsableScheduledWindow(windowEnd, now)) return null;

  return {
    vendor: result.data.vendor,
    food: result.data.food,
    pickupName: result.data.pickupName,
    email: result.data.email,
    timing: "scheduled",
    windowStart,
    windowEnd,
    pickupWindowText: formatMealRequestWindow(windowStart, windowEnd),
  };
}

/**
 * Why a create payload was refused.
 *
 * `payload` is every structural failure this route has always answered with one
 * generic message: a missing, blank, or wrongly typed field, an unexpected key,
 * a bad `timing`, a mismatched or already-ended window, on either create shape.
 * `email` is reserved for an address that is present and non-blank but fails
 * syntax or the NYU allowlist. `vendor` is reserved for a vendor that is
 * present and non-blank but is not one of the supported catalog entries.
 */
type CreateRefusal = "payload" | "vendor" | "email";

type CreateValidation =
  | { ok: true; request: ValidatedCreateRequest }
  | { ok: false; refusal: CreateRefusal };

function isEligibleRequesterEmail(email: string): boolean {
  return eligibleRequesterEmail.safeParse(email).success;
}

/**
 * The vendor and email allowlists are strictly additive and run after shape
 * validation, so they can only refuse a payload that would otherwise have
 * been created. Every existing structural failure — and every case where
 * another field is also invalid — keeps the exact generic error it has
 * always returned; the vendor- and address-specific messages are each
 * reserved for the one case where that field alone is what's wrong.
 *
 * All three refusals happen here, before the daily-limit read, the write,
 * the requester confirmation email, and helper notification.
 */
function validateCreateRequest(body: unknown, now: Date): CreateValidation {
  const request = validateCreateShape(body, now);
  if (!request) return { ok: false, refusal: "payload" };
  if (!isSupportedVendor(request.vendor)) {
    return { ok: false, refusal: "vendor" };
  }
  if (!isEligibleRequesterEmail(request.email)) {
    return { ok: false, refusal: "email" };
  }
  return { ok: true, request };
}

async function attemptRequesterConfirmation(
  request: ValidatedCreateRequest,
  requestId: string
): Promise<void> {
  const htmlVendor = escapeHtml(request.vendor);
  const htmlFood = escapeHtml(request.food);
  const htmlPickupName = escapeHtml(request.pickupName);
  const htmlPickupWindow = escapeHtml(request.pickupWindowText);

  try {
    const result = await resend.emails.send({
      from: "CommonPlate <noreply@commonplatenyu.org>",
      to: request.email,
      subject: "Request Confirmed - CommonPlate",
      html: `
        <h2>Your meal request has been submitted!</h2>
        <p><strong>Vendor:</strong> ${htmlVendor}</p>
        <p><strong>Food:</strong> ${htmlFood}</p>
        <p><strong>Pickup Name:</strong> ${htmlPickupName}</p>
        <p><strong>Pickup Window:</strong> ${htmlPickupWindow}</p>
        <p>When someone helps, CommonPlate will attempt to email you the order details. Request creation does not guarantee that later email will be delivered.</p>
        <p>Request ID: ${requestId}</p>
      `,
      text: `Your meal request has been submitted!\nVendor: ${request.vendor}\nFood: ${request.food}\nPickup Name: ${request.pickupName}\nPickup Window: ${request.pickupWindowText}\nWhen someone helps, CommonPlate will attempt to email you the order details. Request creation does not guarantee that later email will be delivered.\nRequest ID: ${requestId}`,
    });

    if (result.error) {
      console.error(
        `[email] Request confirmation failed after persistence for request ${requestId}`
      );
    }
  } catch {
    console.error(
      `[email] Request confirmation failed after persistence for request ${requestId}`
    );
  }
}

/**
 * The route-facing entry point for real-time helper-email fan-out, and a
 * **total** function: an ordinary non-`async` function that never throws and
 * returns nothing the route can await. Mirrors `startHelperNewRequestPush`.
 *
 * Both guards are load-bearing. The attached `.catch` contains every
 * asynchronous rejection from `notifySubscribersForRequest` — a query
 * failure, a provider error escaping its own per-subscriber isolation. The
 * synchronous `try`/`catch` contains a setup error thrown before any promise
 * exists.
 *
 * This matters because `createRequest` calls it *after* the `201` has been
 * sent. Full-fanout selection makes this call's duration unbounded with
 * confirmed-subscriber count, so it must never be awaited, and an escaping
 * throw or unhandled rejection here would attempt a second response on a
 * request whose headers are already flushed.
 */
function startNotifySubscribersForRequest(
  request: Parameters<typeof notifySubscribersForRequest>[0]
): void {
  let requestId = "unknown";
  try {
    requestId = String(request._id);
    void notifySubscribersForRequest(request).catch((error: unknown) => {
      console.error(
        `[notify] Helper email dispatch failed for request ${requestId}`,
        error
      );
    });
  } catch (error) {
    console.error(
      `[notify] Helper email dispatch could not start for request ${requestId}`,
      error
    );
  }
}

/**
 * Focused handler for POST /api/request.
 *
 * Validation and persistence are core. Requester confirmation happens only
 * after the canonical response has been built from the persisted document,
 * and cannot change the creation result. Helper email and helper push
 * dispatch are both started after the response is sent and neither is
 * awaited, so email and push fail independently of each other, of requester
 * confirmation, and of creation — and neither can delay the requester's
 * `201`, regardless of confirmed-subscriber count.
 */
export async function createRequest(
  req: Request,
  res: Response
): Promise<Response> {
  // One backend creation-time value for the whole handler: scheduled-window
  // validation, the daily-limit window, and the ASAP expiration are all
  // measured from the same instant.
  const now = new Date();

  const validation = validateCreateRequest(req.body, now);
  if (!validation.ok) {
    // `INVALID_EMAIL` and `INVALID_VENDOR` are each a distinct code for one
    // specific, otherwise-valid field, rather than a second and third meaning
    // loaded onto `INVALID_REQUEST`. Clients that do not know either code
    // still render the message.
    if (validation.refusal === "email") {
      return res
        .status(400)
        .json(errorEnvelope("INVALID_EMAIL", NYU_EMAIL_REQUIRED_MESSAGE));
    }
    if (validation.refusal === "vendor") {
      return res
        .status(400)
        .json(errorEnvelope("INVALID_VENDOR", UNSUPPORTED_VENDOR_MESSAGE));
    }
    return res
      .status(400)
      .json(errorEnvelope("INVALID_REQUEST", "Invalid request payload"));
  }
  const validated = validation.request;

  try {
    // This serial read-before-write is intentionally best-effort abuse control,
    // not a transactional quota guarantee under concurrent requests.
    const startOfDay = new Date(now);
    startOfDay.setHours(0, 0, 0, 0);

    try {
      const todaysCount = await MealRequest.countDocuments({
        email: validated.email,
        createdAt: { $gte: startOfDay },
      });
      if (todaysCount >= 3) {
        return res.status(429).json(
          errorEnvelope(
            "REQUEST_LIMIT_REACHED",
            "You have reached the daily limit of 3 meal requests"
          )
        );
      }
    } catch {
      console.error("[route] Failed to enforce request daily limit");
      return res.status(500).json(
        errorEnvelope("REQUEST_CREATION_FAILED", "Unable to create request")
      );
    }

    const expiresAt = requestExpiration(validated, now);

    // Notification-routing identity only, and strictly best-effort: a failure
    // to resolve it must never block the core act of creating a food request.
    let installationId: Types.ObjectId | undefined;
    try {
      installationId = await resolveRequestInstallationAssociation(
        validated.installationCredential
      );
    } catch {
      console.error(
        "[route] Could not resolve the request-installation association"
      );
    }

    const document = await MealRequest.create({
      vendor: validated.vendor,
      food: validated.food,
      pickupName: validated.pickupName,
      email: validated.email,
      pickupWindowText: validated.pickupWindowText,
      windowStart: validated.windowStart,
      windowEnd: validated.windowEnd,
      status: "open",
      expiresAt,
      deleteAt: expiresAt,
      ...(installationId ? { installationId } : {}),
    });

    const response = buildPublicRequestDetailResponse(
      document as unknown as PublicRequestDocument,
      now
    );
    const requestId = String(document._id);

    await attemptRequesterConfirmation(validated, requestId);

    res.status(201).json(response);
    // Both started after the response is sent and deliberately not awaited: a
    // slow, timed-out, or misconfigured APNs submission, or a large or slow
    // confirmed-subscriber email fan-out, must not delay the requester's
    // `201`, turn a successful creation into `REQUEST_CREATION_FAILED`, or
    // alter the created request. Both start functions are total — neither
    // throws, and neither returns anything to await — so nothing here can
    // reach the outer `catch` after the headers are flushed.
    startHelperNewRequestPush(document);
    startNotifySubscribersForRequest(document);
    return res;
  } catch {
    console.error("[route] Request creation failed");
    return res.status(500).json(
      errorEnvelope(
        "REQUEST_CREATION_FAILED",
        "Unable to create request"
      )
    );
  }
}
