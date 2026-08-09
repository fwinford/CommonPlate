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
import { isVisibleNow } from "./requestAvailability.js";
import { resolveRequestInstallationAssociation } from "./requestInstallationAssociation.js";
import {
  isSupportedVendor,
  UNSUPPORTED_VENDOR_MESSAGE,
} from "./supportedVendors.js";
import {
  buildPublicRequestDetailResponse,
  type PublicRequestDocument,
} from "./requestListResponse.js";
import { formatMealRequestWindow, startOfCampusDay } from "./utils/date.js";
import {
  isAcceptableScheduledStart,
  resolveAsapTiming,
  resolveScheduledTiming,
  type RequestTimingWindow,
} from "./requestTiming.js";
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

/**
 * The requester selects one instant, and only one. Under the W3-R1 timing
 * contract the end of a request's availability is derived from its start
 * (`src/requestTiming.ts`), so `windowEnd` is deliberately absent from this
 * shape rather than accepted and discarded: taking an end the backend cannot
 * honour would let the requester believe they chose something they did not.
 * `.strict()` therefore refuses a payload that still carries one.
 */
const canonicalScheduledSchema = z
  .object({
    ...requesterFields,
    timing: z.literal("scheduled"),
    windowStart: isoTimestamp,
    installationCredential: optionalInstallationCredential,
  })
  .strict();

const canonicalSchema = z.union([
  canonicalAsapSchema,
  canonicalScheduledSchema,
]);

/**
 * The website form's shape, kept accepting exactly the keys it has always
 * sent. Two of them are now shape-only:
 *
 * - `pickupWindowText` is still required, because a payload missing it has
 *   always been `INVALID_REQUEST`, but the persisted display text is derived
 *   from the backend's timing decision rather than taken from here. A client
 *   cannot describe a window the backend did not grant.
 * - `windowEnd` is still validated as a well-formed timestamp after
 *   `windowStart`, but no longer decides expiration: the start alone does.
 *   The web form's second time input is consequently vestigial and is left for
 *   the separate web pass rather than removed here.
 */
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
  /**
   * The accepted scheduled start, on scheduled requests only. It is the sole
   * requester-supplied timing input: `visibleFrom`, `expiresAt`, `windowEnd`,
   * and the display text are all derived from it plus the backend clock.
   */
  windowStart?: Date;
  /** Present only on the canonical iOS shapes; the legacy web shape has none. */
  installationCredential?: string;
}

const resend = new Resend(process.env.RESEND_API_KEY);

/**
 * Backend-owned visibility and expiration. The client supplies neither — both
 * create schemas are `.strict()` — and both are written explicitly rather than
 * left to the schema's 24-hour `pre("save")` fallback, so what is persisted
 * always matches what the requester is told.
 *
 * ASAP: visible from the backend creation instant, for three hours.
 * Scheduled: visible from the accepted start, for three hours after it.
 *
 * `src/requestTiming.ts` owns both durations; nothing here recomputes them.
 */
function requestTimingWindow(
  validated: ValidatedCreateRequest,
  createdAt: Date
): RequestTimingWindow {
  if (validated.timing === "scheduled" && validated.windowStart) {
    return resolveScheduledTiming(validated.windowStart);
  }
  return resolveAsapTiming(createdAt);
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
 * A scheduled start must not already have passed, judged against this
 * handler's own `now` rather than any client clock.
 *
 * `src/requestTiming.ts` owns the rule and its boundary. Applying it here, in
 * shape validation, keeps the refusal ahead of the daily-limit read, the write,
 * the requester confirmation email, and both notification dispatches, so an
 * elapsed start produces no side effect of any kind.
 */
function isUsableScheduledStart(windowStart: Date, now: Date): boolean {
  return isAcceptableScheduledStart(windowStart, now);
}

/**
 * What helpers read on every ASAP request. The three-hour availability rule
 * is explained once, at the requester's timing choice (`RequestFoodView`'s
 * form / the legacy web form's radio label); this label deliberately does not
 * restate it, so every downstream surface that renders `pickupWindowText`
 * (lists, detail, requester/helper email) is not repeating policy the
 * requester already saw. `REQUEST_VISIBLE_DURATION_MS` remains the sole
 * source of the actual duration.
 */
export const ASAP_WINDOW_TEXT = "ASAP";

/**
 * What helpers read on every surface that renders a request. Derived here from
 * the backend's own timing decision, for both create shapes, so no client can
 * post display text that contradicts the availability it describes.
 *
 * The scheduled text is formatted in NYU campus time
 * (`formatMealRequestWindow`), so it reads the same to a helper in New York
 * and to one whose device is not.
 */
function requestWindowText(
  timing: "asap" | "scheduled",
  window: RequestTimingWindow
): string {
  return timing === "asap"
    ? ASAP_WINDOW_TEXT
    : formatMealRequestWindow(window.visibleFrom, window.expiresAt);
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
        installationCredential: result.data.installationCredential,
      };
    }

    const windowStart = new Date(result.data.windowStart);
    if (!isUsableScheduledStart(windowStart, now)) return null;

    return {
      vendor: result.data.vendor,
      food: result.data.food,
      pickupName: result.data.pickupName,
      email: result.data.email,
      timing: "scheduled",
      windowStart,
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
    };
  }

  const windowStart = new Date(result.data.windowStart!);
  if (!isUsableScheduledStart(windowStart, now)) return null;

  return {
    vendor: result.data.vendor,
    food: result.data.food,
    pickupName: result.data.pickupName,
    email: result.data.email,
    timing: "scheduled",
    windowStart,
  };
}

/**
 * Why a create payload was refused.
 *
 * `payload` is every structural failure this route has always answered with one
 * generic message: a missing, blank, or wrongly typed field, an unexpected key,
 * a bad `timing`, a mismatched window, or a scheduled start that has already
 * passed, on either create shape.
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
  pickupWindowText: string,
  requestId: string
): Promise<void> {
  const htmlVendor = escapeHtml(request.vendor);
  const htmlFood = escapeHtml(request.food);
  const htmlPickupName = escapeHtml(request.pickupName);
  // The same backend-derived, NYU-campus-time text helpers see, so the
  // requester's confirmation cannot state a window the request does not have.
  const htmlPickupWindow = escapeHtml(pickupWindowText);

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
      text: `Your meal request has been submitted!\nVendor: ${request.vendor}\nFood: ${request.food}\nPickup Name: ${request.pickupName}\nPickup Window: ${pickupWindowText}\nWhen someone helps, CommonPlate will attempt to email you the order details. Request creation does not guarantee that later email will be delivered.\nRequest ID: ${requestId}`,
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
  // One backend creation-time value for the whole handler: scheduled-start
  // validation, the daily-limit window, and the ASAP visibility window are all
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
    // not a transactional quota guarantee under concurrent requests. The day
    // boundary is the NYU campus calendar day, not the Node process's local
    // timezone, so quota reset time does not depend on where this process runs.
    const startOfDay = startOfCampusDay(now);

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

    const { visibleFrom, expiresAt } = requestTimingWindow(validated, now);
    const pickupWindowText = requestWindowText(validated.timing, {
      visibleFrom,
      expiresAt,
    });

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
      pickupWindowText,
      windowStart: validated.windowStart,
      // The advertised window is the availability window. Persisting the
      // derived expiration here — rather than whatever end a client sent —
      // keeps the public `windowEnd`, the display text, and `expiresAt` from
      // being three different claims about one request.
      windowEnd: validated.timing === "scheduled" ? expiresAt : undefined,
      status: "open",
      visibleFrom,
      // Which path owns starting helper notification for this request (W3-N3).
      // Decided by the one visibility rule every other path applies, so this
      // records what the two dispatches started below will actually do rather
      // than a second opinion about it: a request that is helper-visible now is
      // being dispatched for now, and a future Later request is not — its
      // dispatches will both find it unavailable and do nothing, and the
      // eligibility sweep picks it up at `visibleFrom` instead.
      helperNotification: isVisibleNow(visibleFrom, now)
        ? "initiated"
        : "awaiting-eligibility",
      expiresAt,
      deleteAt: expiresAt,
      ...(installationId ? { installationId } : {}),
    });

    const response = buildPublicRequestDetailResponse(
      document as unknown as PublicRequestDocument,
      now
    );
    const requestId = String(document._id);

    await attemptRequesterConfirmation(validated, pickupWindowText, requestId);

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
