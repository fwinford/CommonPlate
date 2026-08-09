import type { Request, Response } from "express";
import mongoose, { type ClientSession, type Types } from "mongoose";
import { z } from "zod";
import {
  Fulfillment,
  Request as MealRequest,
  Participant,
  type IRequest,
} from "../models/db.js";
import { normalizeParticipantPrincipal } from "./participantIdentity.js";
import {
  claimTokenDigestMatches,
  digestClaimToken,
  isValidRawClaimToken,
  readClaimTokenHmacSecret,
} from "./claimToken.js";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import { sendDay4Error } from "./day4Errors.js";
import { sendFulfillmentEmail } from "./emailHelpers.js";
import { startRequesterFulfillmentPush } from "./requesterFulfillmentPush.js";
import {
  buildPublicRequestDetailResponse,
  type PublicRequestDocument,
} from "./requestListResponse.js";

export const FULFILLMENT_ROUTE_PATH = "/api/request/:id/fulfill";
export const PLACED_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
export const fulfillmentRateLimiter = createDay4MutationRateLimiter(10);

// A CommonPlate Grubhub order number contains digits only. Validated as a
// string and stored as one — never coerced to a number — so a leading zero
// survives and a long value is not reshaped by numeric conversion. The 50-digit
// cap is a length bound on that string, not a magnitude bound.
const orderNumberFormat = /^[0-9]{1,50}$/;
const requiredText = z.string().trim().min(1);
/**
 * The historical `fulfillment.fulfillerEmail` key, tolerated and discarded.
 *
 * Since W3-I1 the helper is whoever the claim is bound to, read from
 * `helperParticipantId`, and no payload value may name them. But an app build
 * that predates this slice sends this key on every fulfillment, and the
 * grandfathered claims this slice must keep recordable are held by exactly
 * those builds — so a strict schema that rejects the key would refuse the
 * compatibility path before it could be reached, and a helper holding a real
 * Grubhub order would be unable to record it.
 *
 * It is therefore accepted as *wire shape only* and then dropped by the
 * allowlisting transform below, so it is absent from
 * `FulfillmentRequestPayload` and unreadable by anything downstream — not as
 * identity, not as a helper address, not as a Reply-To. That is a type-level
 * guarantee rather than a convention someone has to remember. Its declared type
 * is deliberately `unknown`: nothing validates a value nothing consumes, and
 * validating it would suggest it means something.
 */
const legacyFulfillerEmailWireKey = z.unknown().optional();

const fulfillmentRequestSchema = z
  .object({
    claimToken: z.string(),
    fulfillment: z
      .object({
        fulfillerEmail: legacyFulfillerEmailWireKey,
        orderNumber: requiredText.regex(orderNumberFormat),
        eta: requiredText,
        contactMessage: z
          .string()
          .trim()
          .optional()
          .transform((value) => value || undefined),
      })
      .strict()
      // The explicit allowlist of what a fulfillment payload actually supplies.
      .transform((fulfillment) => ({
        orderNumber: fulfillment.orderNumber,
        eta: fulfillment.eta,
        contactMessage: fulfillment.contactMessage,
      })),
  })
  .strict();

type FulfillmentRequestPayload = z.infer<typeof fulfillmentRequestSchema>;

interface FulfillmentDiagnosticDocument {
  status?: string;
  claimExpiresAt?: Date | null;
  claimTokenDigest?: string | null;
}

/**
 * The helper this reservation belongs to (W3-I1).
 *
 * `verified` is every claim granted since this slice: the participant the
 * claim mutation bound, and that participant's current principal.
 *
 * `legacyCompatible` is the pre-I1 fulfillment-safety carve-out: a claim whose
 * conditional grant predates `helperParticipantId` entirely, so the field is
 * absent rather than null. `claimRoute.ts` writes `helperParticipantId` in the
 * same conditional mutation that grants every claim since this slice shipped,
 * so an unexpired claim reaching here with the field absent cannot be a
 * post-I1 caller bypassing the helper gate — the mutation that would have
 * created such a row does not exist. It can only be a claim issued before this
 * slice existed.
 */
type BoundHelper =
  | { kind: "verified"; participantId: Types.ObjectId; email: string }
  | { kind: "legacyCompatible" };

export const CLAIM_IDENTITY_UNAVAILABLE_CODE = "CLAIM_IDENTITY_UNAVAILABLE";
/**
 * Deliberately does not suggest placing another order. A helper reaching this
 * may already hold a real Grubhub order, and no recovery path in CommonPlate
 * may ever imply that a second one is the fix.
 */
export const CLAIM_IDENTITY_UNAVAILABLE_MESSAGE =
  "CommonPlate can’t confirm who reserved this request. Don’t place another Grubhub order.";

class ConditionalPlacementFailure extends Error {}
/**
 * Raised only when a claim names a `helperParticipantId` that no longer
 * resolves to a usable participant principal — a data-integrity case, not the
 * ordinary pre-I1 absence, which takes the `legacyCompatible` path instead.
 */
class MissingHelperIdentity extends Error {}

function isInvalidId(id: unknown): boolean {
  return !mongoose.Types.ObjectId.isValid(String(id));
}

function payloadHasValidClaimToken(
  body: unknown
): body is { claimToken: string } & Record<string, unknown> {
  return (
    typeof body === "object" &&
    body !== null &&
    isValidRawClaimToken((body as Record<string, unknown>).claimToken)
  );
}

function transactionUnsupported(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  const candidate = error as { code?: number; message?: string };
  return (
    candidate.code === 20 ||
    /transaction numbers are only allowed on a replica set member or mongos/i.test(
      candidate.message || ""
    )
  );
}

async function diagnosticRequest(
  id: string
): Promise<FulfillmentDiagnosticDocument | null> {
  return (await MealRequest.findById(id)
    .select("status claimExpiresAt +claimTokenDigest")
    .lean()
    .exec()) as FulfillmentDiagnosticDocument | null;
}

/**
 * What to answer when every specific classification below has been ruled out.
 *
 * Two callers need different terminals for the same walk through the same
 * diagnostic. A rejected conditional update that reaches the end is a genuine
 * internal failure; a reservation whose verified-helper binding is missing has
 * reached the end for a known reason, and saying "internal failure" to a helper
 * who may already be holding a real order would be both wrong and unactionable.
 */
type TerminalExplanation = { status: number; code: string; message: string };

const INTERNAL_TERMINAL: TerminalExplanation = {
  status: 500,
  code: "INTERNAL_FAILURE",
  message: "Unable to record this placement right now.",
};

const MISSING_HELPER_IDENTITY_TERMINAL: TerminalExplanation = {
  status: 409,
  code: CLAIM_IDENTITY_UNAVAILABLE_CODE,
  message: CLAIM_IDENTITY_UNAVAILABLE_MESSAGE,
};

async function explainConditionalFailure(
  id: string,
  submittedDigest: string,
  now: Date,
  res: Response,
  terminal: TerminalExplanation = INTERNAL_TERMINAL
): Promise<Response> {
  const document = await diagnosticRequest(id);
  if (!document) {
    return sendDay4Error(
      res,
      404,
      "REQUEST_NOT_FOUND",
      "This request could not be found."
    );
  }
  if (document.status === "placed") {
    return sendDay4Error(
      res,
      409,
      "REQUEST_ALREADY_PLACED",
      "This request has already been placed."
    );
  }
  if (document.status !== "claimed") {
    return sendDay4Error(
      res,
      409,
      "REQUEST_NOT_CLAIMED",
      "This request does not have an active claim."
    );
  }
  if (
    !document.claimExpiresAt ||
    document.claimExpiresAt.getTime() <= now.getTime()
  ) {
    return sendDay4Error(
      res,
      409,
      "CLAIM_EXPIRED",
      "This claim has expired."
    );
  }
  if (
    !claimTokenDigestMatches(document.claimTokenDigest, submittedDigest)
  ) {
    return sendDay4Error(
      res,
      403,
      "INVALID_CLAIM_TOKEN",
      "The claim token is missing or invalid."
    );
  }

  return sendDay4Error(res, terminal.status, terminal.code, terminal.message);
}

async function persistCorePlacement(
  id: string,
  payload: FulfillmentRequestPayload,
  submittedDigest: string,
  helper: BoundHelper,
  placedAt: Date,
  session: ClientSession
): Promise<IRequest> {
  let placedRequest: IRequest | null = null;

  await session.withTransaction(
    async () => {
      const setFields: Record<string, unknown> = {
        status: "placed",
        placedAt,
        deleteAt: new Date(placedAt.getTime() + PLACED_RETENTION_MS),
        orderNumber: payload.fulfillment.orderNumber,
        etaText: payload.fulfillment.eta,
        notificationStatus: "pending",
        updatedAt: placedAt,
      };
      if (helper.kind === "verified") {
        // The claim-bound helper's verified principal, resolved from the
        // request's own `helperParticipantId`. Never a payload value.
        setFields.fulfillerEmail = helper.email;
      }
      // A legacyCompatible claim has no verified principal to derive an
      // address from and the payload carries none (W3-I1 removed that field).
      // `fulfillerEmail` is optional on the schema, so leaving it unset is a
      // truthful placement, not a defect.
      if (payload.fulfillment.contactMessage) {
        setFields.contactMessage = payload.fulfillment.contactMessage;
      }

      const unsetFields: Record<string, 1> = {
        claimedAt: 1,
        claimExpiresAt: 1,
        claimExtendedAt: 1,
        claimTokenDigest: 1,
      };
      if (!payload.fulfillment.contactMessage) {
        unsetFields.contactMessage = 1;
      }

      placedRequest = await MealRequest.findOneAndUpdate(
        {
          _id: id,
          status: "claimed",
          claimExpiresAt: { $gt: placedAt },
          claimTokenDigest: submittedDigest,
          // Pins the placement to the exact binding the helper address was
          // read from. If the reservation lapsed and another verified helper
          // re-claimed between that read and this write, this condition fails
          // and the ordinary conditional-failure classifier answers — rather
          // than recording the new helper's order under the old helper's
          // address. A legacyCompatible claim never had the field at all, so
          // its pin is exact absence, not a value — matching the same
          // `$exists: false` pattern already accepted for legacy rows in
          // `resolveUnsubscribeCredentialVersion`.
          helperParticipantId:
            helper.kind === "verified"
              ? helper.participantId
              : { $exists: false },
        },
        {
          $set: setFields,
          $unset: unsetFields,
        },
        { new: true, runValidators: true, session }
      )
        // `installationId` is `select: false`; the requester-fulfillment push
        // dispatched after this transaction commits needs it to find the
        // originating installation, so it must be requested explicitly here.
        .select("+installationId")
        .exec();

      if (!placedRequest) {
        throw new ConditionalPlacementFailure();
      }

      await Fulfillment.create(
        [
          {
            requestId: placedRequest._id,
            orderNumber: payload.fulfillment.orderNumber,
            etaText: payload.fulfillment.eta,
            placedAt,
          },
        ],
        { session }
      );
    },
    {
      readConcern: { level: "snapshot" },
      writeConcern: { w: "majority" },
    }
  );

  if (!placedRequest) {
    throw new ConditionalPlacementFailure();
  }
  return placedRequest;
}

/**
 * Reads the reservation's bound helper.
 *
 * Two documents, both private: `helperParticipantId` is `select: false` on the
 * Request, and the principal itself lives on the Participant. Read before the
 * transaction rather than inside it because the address has to be part of the
 * placement `$set`, and the conditional filter re-pins the same binding, so the
 * read cannot go stale between here and the write without the write failing.
 *
 * An absent binding takes the `legacyCompatible` path (see `BoundHelper`)
 * rather than being refused: it can only be a claim issued before this slice,
 * and the existing fulfillment-safety contract requires such a claim to
 * remain recordable. A binding that is present but no longer resolves to a
 * usable participant is a different, narrower failure — see
 * `MissingHelperIdentity` — and is refused.
 */
async function resolveBoundHelper(id: string): Promise<BoundHelper> {
  const reservation = await MealRequest.findById(id)
    .select("+helperParticipantId")
    .lean<{ helperParticipantId?: Types.ObjectId | null }>()
    .exec();
  const participantId = reservation?.helperParticipantId;
  if (!participantId) return { kind: "legacyCompatible" };

  const participant = await Participant.findById(participantId)
    .select("email")
    .lean<{ email: string }>()
    .exec();
  const email = normalizeParticipantPrincipal(participant?.email);
  if (!email) throw new MissingHelperIdentity();

  return { kind: "verified", participantId, email };
}

async function recordNotificationOutcome(
  requestId: string,
  placedAt: Date,
  status: "sent" | "failed"
): Promise<void> {
  const attemptedAt = new Date();
  try {
    await MealRequest.updateOne(
      { _id: requestId, status: "placed", placedAt },
      {
        $set: {
          notificationStatus: status,
          notificationAttemptedAt: attemptedAt,
          updatedAt: attemptedAt,
        },
      }
    ).exec();
  } catch {
    // The transaction already committed. A verification-state write failure
    // must never reverse placement or turn this into another order attempt.
    console.error(
      `[fulfillment] Requester email provider result could not be recorded (${status})`
    );
  }
}

export async function fulfillRequest(
  req: Request,
  res: Response
): Promise<Response> {
  const id = String(req.params.id);
  if (isInvalidId(id)) {
    return sendDay4Error(
      res,
      400,
      "INVALID_REQUEST_ID",
      "The request ID is invalid."
    );
  }

  if (!payloadHasValidClaimToken(req.body)) {
    return sendDay4Error(
      res,
      400,
      "INVALID_CLAIM_TOKEN",
      "The claim token is missing or invalid."
    );
  }

  const validation = fulfillmentRequestSchema.safeParse(req.body);
  if (!validation.success) {
    return sendDay4Error(
      res,
      400,
      "INVALID_FULFILLMENT_PAYLOAD",
      "The fulfillment details are invalid."
    );
  }

  const placedAt = new Date();
  // Declared here so the failure classifier and `finally` can see them, but
  // produced inside the try: a missing HMAC secret or an unavailable session
  // must answer in the structured error envelope rather than escape as a
  // rejected promise into the generic handler.
  let session: ClientSession | undefined;
  let submittedDigest: string | undefined;
  let placedRequest: IRequest;
  let helper: BoundHelper;

  try {
    submittedDigest = digestClaimToken(
      validation.data.claimToken,
      readClaimTokenHmacSecret()
    );
    helper = await resolveBoundHelper(id);
    session = await mongoose.startSession();
    placedRequest = await persistCorePlacement(
      id,
      validation.data,
      submittedDigest,
      helper,
      placedAt,
      session
    );
  } catch (error) {
    if (error instanceof MissingHelperIdentity && submittedDigest) {
      // The named participant no longer resolves, so the conditional update
      // would have been rejected anyway — its filter pins the same binding —
      // so this walks the ordinary classifier and keeps every existing
      // answer: not found, already placed, not claimed, claim expired, wrong
      // token. Only the case none of those explain, a live reservation whose
      // bound participant has vanished, reaches the dedicated terminal.
      return await explainConditionalFailure(
        id,
        submittedDigest,
        placedAt,
        res,
        MISSING_HELPER_IDENTITY_TERMINAL
      );
    }
    if (error instanceof ConditionalPlacementFailure && submittedDigest) {
      return await explainConditionalFailure(
        id,
        submittedDigest,
        placedAt,
        res
      );
    }
    if (transactionUnsupported(error)) {
      console.error(
        "[fulfillment] MongoDB transactions require a replica set or mongos"
      );
      return sendDay4Error(
        res,
        503,
        "TRANSACTIONS_UNAVAILABLE",
        "Placement recording requires a transaction-capable database."
      );
    }
    console.error("[fulfillment] Transactional placement failed");
    return sendDay4Error(
      res,
      500,
      "INTERNAL_FAILURE",
      "Unable to record this placement right now."
    );
  } finally {
    if (session) {
      try {
        await session.endSession();
      } catch {
        // The transaction outcome is already known here. Cleanup cannot change
        // placement truth or prevent the committed response path from running.
        // Deliberately omit request, token, order, and contact details.
        console.error("[fulfillment] MongoDB session cleanup failed after placement attempt");
      }
    }
  }

  let notificationStatus: "sent" | "failed" = "sent";
  try {
    await sendFulfillmentEmail(
      placedRequest,
      validation.data.fulfillment.orderNumber,
      validation.data.fulfillment.eta,
      validation.data.fulfillment.contactMessage,
      // The Reply-To the requester sees is the claim-bound helper's verified
      // address — the same value persisted above — so the coordination address
      // in that email is one CommonPlate has actually proved. A
      // legacyCompatible placement has no verified address to offer; the
      // payload carries none either, since W3-I1 removed that field, so
      // omitting Reply-To here is the only truthful choice.
      helper.kind === "verified" ? helper.email : undefined
    );
    console.info("[fulfillment] Requester email submitted to provider");
  } catch {
    notificationStatus = "failed";
    console.error("[fulfillment] Requester email provider submission failed");
  }

  await recordNotificationOutcome(id, placedAt, notificationStatus);
  const publicResponse = buildPublicRequestDetailResponse(
    placedRequest as unknown as PublicRequestDocument,
    placedAt
  );
  res.json({
    request: publicResponse.request,
    notification: { status: notificationStatus },
  });
  // Started after the response is sent and deliberately not awaited, matching
  // `startHelperNewRequestPush`: a slow, timed-out, or misconfigured APNs
  // submission must not delay this response, and placement has already
  // durably committed by this point regardless of what push does next. The
  // start function is total — it neither throws nor returns anything to
  // await — so nothing here can reach a `catch` after the headers are
  // flushed.
  startRequesterFulfillmentPush(placedRequest);
  return res;
}
