import { Subscriber } from "../models/db.js";
import {
  digestSubscriptionToken,
  generateSubscriptionToken,
  isValidRawSubscriptionToken,
} from "./subscriptionTokens.js";

/**
 * Internal outcome of redeeming a confirmation token. It is deliberately not a
 * response shape: the caller decides what a browser or API surface may learn,
 * and no route consumes this yet.
 */
export type ConfirmationOutcome =
  | "confirmed"
  | "alreadyConfirmed"
  | "expired"
  | "invalid";

export interface ConfirmationResult {
  outcome: ConfirmationOutcome;
  subscriberId?: string;
  /**
   * Only present on a first `confirmed` transition. The raw unsubscribe token
   * exists in memory for exactly one caller, mirroring the winner-only raw
   * claim token: only its digest is ever persisted, and it is never logged.
   */
  rawUnsubscribeToken?: string;
}

export interface ConfirmSubscriptionDependencies {
  generateRawUnsubscribeToken: () => string;
}

const defaultDependencies: ConfirmSubscriptionDependencies = {
  generateRawUnsubscribeToken: generateSubscriptionToken,
};

/** Cleared by a successful transition: none of it outlives `pending`. */
const CONFIRMATION_CLEARED_FIELDS = [
  "confirmationTokenDigest",
  "confirmationExpiresAt",
  // Confirmation is the user's action, not the send attempt's. It must succeed
  // under a live or orphaned signup lease, and it ends that lease: the
  // lifecycle the lease guarded no longer exists once the address is confirmed.
  "confirmationSendAttemptId",
  "confirmationSendAttemptAt",
  "unsubscribedAt",
  // Legacy raw credentials from a pre-digest row. A subscriber confirmed by
  // this lifecycle keeps digests only, so a raw token left behind here would be
  // a live credential the new contract never issued and cannot revoke.
  "confirmToken",
  "unsubToken",
] as const;

export function createConfirmSubscription(
  overrides: Partial<ConfirmSubscriptionDependencies> = {}
) {
  const dependencies = { ...defaultDependencies, ...overrides };

  /**
   * Redeems a raw confirmation token against backend `now`.
   *
   * The transition is one conditional atomic mutation. Reading the subscriber
   * first and saving a decided status would let two concurrent redemptions both
   * observe `pending` and both write, issuing two unsubscribe credentials for
   * one address; the conditional update lets exactly one win.
   */
  return async function confirmSubscription(
    rawToken: unknown,
    now: Date
  ): Promise<ConfirmationResult> {
    if (!isValidRawSubscriptionToken(rawToken)) return { outcome: "invalid" };

    const confirmationTokenDigest = digestSubscriptionToken(rawToken);
    // Generated before the attempt so the digest can be written in the same
    // mutation. A losing attempt simply discards it: nothing is persisted
    // unless this exact mutation matches.
    const rawUnsubscribeToken = dependencies.generateRawUnsubscribeToken();
    const unsubscribeTokenDigest = digestSubscriptionToken(rawUnsubscribeToken);

    const confirmed = await Subscriber.findOneAndUpdate(
      {
        status: "pending",
        confirmationTokenDigest,
        confirmationExpiresAt: { $gt: now },
      },
      // An aggregation pipeline, because the receipt must carry the expiry the
      // document already held. Reading it in a separate round trip would
      // reopen the race this single mutation exists to close.
      [
        {
          $set: {
            status: "confirmed",
            lastConfirmedTokenDigest: "$confirmationTokenDigest",
            lastConfirmedTokenExpiresAt: "$confirmationExpiresAt",
            unsubscribeTokenDigest: { $literal: unsubscribeTokenDigest },
            // Confirmation starts delivery history over: a freshly confirmed
            // address must not inherit a bounce or a spent daily allowance
            // from an earlier lifecycle.
            lastSentAt: { $literal: null },
            dailyCount: { $literal: 0 },
            bounced: { $literal: false },
          },
        },
        { $unset: [...CONFIRMATION_CLEARED_FIELDS] },
      ],
      { new: true }
    )
      .select("_id")
      .lean<{ _id: unknown }>()
      .exec();

    if (confirmed) {
      return {
        outcome: "confirmed",
        subscriberId: String(confirmed._id),
        rawUnsubscribeToken,
      };
    }

    // Checked only after the mutation lost, so the loser of a concurrent
    // redemption reports the winner's success rather than an invalid token.
    // The receipt is honoured only inside the original confirmation window;
    // past it the link is simply spent.
    const alreadyConfirmed = await Subscriber.findOne({
      status: "confirmed",
      lastConfirmedTokenDigest: confirmationTokenDigest,
      lastConfirmedTokenExpiresAt: { $gt: now },
    })
      .select("_id")
      .lean<{ _id: unknown }>()
      .exec();
    if (alreadyConfirmed) {
      return {
        outcome: "alreadyConfirmed",
        subscriberId: String(alreadyConfirmed._id),
      };
    }

    const expired = await Subscriber.exists({
      confirmationTokenDigest,
      confirmationExpiresAt: { $lte: now },
    });
    if (expired) return { outcome: "expired" };

    return { outcome: "invalid" };
  };
}

export const confirmSubscription = createConfirmSubscription();
