import type { Request, Response } from "express";
import mongoose, { type ClientSession } from "mongoose";
import { z } from "zod";
import {
  Fulfillment,
  Request as MealRequest,
  type IRequest,
} from "../models/db.js";
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
const fulfillmentRequestSchema = z
  .object({
    claimToken: z.string(),
    fulfillment: z
      .object({
        fulfillerEmail: z.string().trim().toLowerCase().email(),
        orderNumber: requiredText.regex(orderNumberFormat),
        eta: requiredText,
        contactMessage: z
          .string()
          .trim()
          .optional()
          .transform((value) => value || undefined),
      })
      .strict(),
  })
  .strict();

type FulfillmentRequestPayload = z.infer<typeof fulfillmentRequestSchema>;

interface FulfillmentDiagnosticDocument {
  status?: string;
  claimExpiresAt?: Date | null;
  claimTokenDigest?: string | null;
}

class ConditionalPlacementFailure extends Error {}

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

async function explainConditionalFailure(
  id: string,
  submittedDigest: string,
  now: Date,
  res: Response
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

  return sendDay4Error(
    res,
    500,
    "INTERNAL_FAILURE",
    "Unable to record this placement right now."
  );
}

async function persistCorePlacement(
  id: string,
  payload: FulfillmentRequestPayload,
  submittedDigest: string,
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
        fulfillerEmail: payload.fulfillment.fulfillerEmail,
        notificationStatus: "pending",
        updatedAt: placedAt,
      };
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

  try {
    submittedDigest = digestClaimToken(
      validation.data.claimToken,
      readClaimTokenHmacSecret()
    );
    session = await mongoose.startSession();
    placedRequest = await persistCorePlacement(
      id,
      validation.data,
      submittedDigest,
      placedAt,
      session
    );
  } catch (error) {
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
      validation.data.fulfillment.fulfillerEmail
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
