import mongoose from "mongoose";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { Subscriber } from "../models/db.js";
import { createConfirmSubscription } from "./confirmSubscription.js";
import {
  SUBSCRIPTION_TOKEN_BYTES,
  digestSubscriptionToken,
} from "./subscriptionTokens.js";

const mongoUri = process.env.MONGO_INTEGRATION_URI;
const describeMongo = mongoUri ? describe : describe.skip;
const backendNow = new Date("2026-08-03T18:30:00.000Z");

function rawToken(byte: number): string {
  return Buffer.alloc(SUBSCRIPTION_TOKEN_BYTES, byte).toString("base64url");
}

interface PendingOverrides {
  email?: string;
  confirmationExpiresAt?: Date;
  confirmationSendAttemptId?: string;
  confirmationSendAttemptAt?: Date;
  bounced?: boolean;
  dailyCount?: number;
  lastSentAt?: Date | null;
  unsubscribedAt?: Date;
  confirmToken?: string;
  unsubToken?: string;
}

async function insertPending(token: string, overrides: PendingOverrides = {}) {
  const {
    email = "helper@example.edu",
    confirmationExpiresAt = new Date(backendNow.getTime() + 60_000),
    ...rest
  } = overrides;
  const id = new mongoose.Types.ObjectId();
  await Subscriber.collection.insertOne({
    _id: id,
    email,
    status: "pending",
    confirmationTokenDigest: digestSubscriptionToken(token),
    confirmationExpiresAt,
    bounced: false,
    dailyCount: 0,
    ...rest,
  });
  return id;
}

describeMongo("confirmation redemption against real MongoDB", () => {
  beforeAll(async () => {
    // Own database, because `subscribeRoute.mongo.test.ts` clears the whole
    // Subscriber collection between its cases and the runner executes Mongo
    // files concurrently. Sharing one database would let either suite delete
    // the other's fixtures mid-test.
    await mongoose.connect(mongoUri!, {
      dbName: "commonplate_confirmation_test",
    });
    await Subscriber.syncIndexes();
  });

  afterEach(async () => {
    vi.restoreAllMocks();
    await Subscriber.deleteMany({});
  });

  afterAll(async () => {
    await mongoose.disconnect();
  });

  it("transitions pending to confirmed and rewrites the whole lifecycle", async () => {
    const token = rawToken(1);
    const confirmationExpiresAt = new Date(backendNow.getTime() + 3_600_000);
    const id = await insertPending(token, {
      confirmationExpiresAt,
      bounced: true,
      dailyCount: 4,
      lastSentAt: new Date("2026-08-02T10:00:00.000Z"),
      unsubscribedAt: new Date("2026-08-01T10:00:00.000Z"),
    });
    const unsubscribeToken = rawToken(2);

    const result = await createConfirmSubscription({
      generateRawUnsubscribeToken: () => unsubscribeToken,
    })(token, backendNow);

    expect(result.outcome).toBe("confirmed");
    expect(result.subscriberId).toBe(String(id));
    expect(result.rawUnsubscribeToken).toBe(unsubscribeToken);
    const stored = await Subscriber.collection.findOne({ _id: id });
    expect(stored?.status).toBe("confirmed");
    expect(stored).not.toHaveProperty("confirmationTokenDigest");
    expect(stored).not.toHaveProperty("confirmationExpiresAt");
    expect(stored).not.toHaveProperty("unsubscribedAt");
    expect(stored?.bounced).toBe(false);
    expect(stored?.dailyCount).toBe(0);
    expect(stored?.lastSentAt).toBeNull();
    expect(stored?.unsubscribeTokenDigest).toBe(
      digestSubscriptionToken(unsubscribeToken)
    );
    // The receipt of the spent link keeps the expiry the document already had.
    expect(stored?.lastConfirmedTokenDigest).toBe(
      digestSubscriptionToken(token)
    );
    expect(stored?.lastConfirmedTokenExpiresAt).toEqual(confirmationExpiresAt);
    expect(JSON.stringify(stored)).not.toContain(token);
    expect(JSON.stringify(stored)).not.toContain(unsubscribeToken);
  });

  it("strips legacy raw credentials carried by the pending row it confirms", async () => {
    const token = rawToken(30);
    const id = await insertPending(token, {
      email: "legacy-pending@example.edu",
      confirmToken: "legacy-raw-confirm-token",
      unsubToken: "legacy-raw-unsubscribe-token",
    });
    const unsubscribeToken = rawToken(31);

    const result = await createConfirmSubscription({
      generateRawUnsubscribeToken: () => unsubscribeToken,
    })(token, backendNow);

    expect(result.outcome).toBe("confirmed");
    const stored = await Subscriber.collection.findOne({ _id: id });
    expect(stored?.status).toBe("confirmed");
    // A raw token left behind would be a live credential this lifecycle never
    // issued and has no way to revoke.
    expect(stored).not.toHaveProperty("confirmToken");
    expect(stored).not.toHaveProperty("unsubToken");
    expect(JSON.stringify(stored)).not.toContain("legacy-raw-confirm-token");
    expect(JSON.stringify(stored)).not.toContain("legacy-raw-unsubscribe-token");
    expect(stored?.unsubscribeTokenDigest).toBe(
      digestSubscriptionToken(unsubscribeToken)
    );
    expect(stored?.lastConfirmedTokenDigest).toBe(
      digestSubscriptionToken(token)
    );
    expect(stored).not.toHaveProperty("confirmationTokenDigest");
    expect(stored?.bounced).toBe(false);
    expect(stored?.dailyCount).toBe(0);
    expect(stored?.lastSentAt).toBeNull();
  });

  it("keeps exactly one mutation and one unsubscribe digest under concurrency", async () => {
    const token = rawToken(3);
    const id = await insertPending(token);
    let issued = 0;
    const confirm = createConfirmSubscription({
      generateRawUnsubscribeToken: () => rawToken(20 + issued++),
    });

    const [first, second] = await Promise.all([
      confirm(token, backendNow),
      confirm(token, backendNow),
    ]);

    const outcomes = [first.outcome, second.outcome].sort();
    expect(outcomes).toEqual(["alreadyConfirmed", "confirmed"]);
    const winner = first.outcome === "confirmed" ? first : second;
    const loser = first.outcome === "confirmed" ? second : first;
    expect(loser.rawUnsubscribeToken).toBeUndefined();
    expect(loser.subscriberId).toBe(String(id));
    expect(issued).toBe(2);
    const stored = await Subscriber.collection.findOne({ _id: id });
    expect(stored?.status).toBe("confirmed");
    // Only the winner's credential exists: the loser's generated token was
    // discarded rather than overwriting a live unsubscribe digest.
    expect(stored?.unsubscribeTokenDigest).toBe(
      digestSubscriptionToken(winner.rawUnsubscribeToken!)
    );
    expect(
      await Subscriber.countDocuments({ unsubscribeTokenDigest: { $exists: true } })
    ).toBe(1);
  });

  it("returns alreadyConfirmed and rotates nothing when the same link is reopened", async () => {
    const token = rawToken(4);
    const id = await insertPending(token);
    const confirm = createConfirmSubscription({
      generateRawUnsubscribeToken: () => rawToken(5),
    });
    await confirm(token, backendNow);
    const afterFirst = await Subscriber.collection.findOne({ _id: id });

    const repeated = await createConfirmSubscription({
      generateRawUnsubscribeToken: () => rawToken(6),
    })(token, new Date(backendNow.getTime() + 30_000));

    expect(repeated).toEqual({
      outcome: "alreadyConfirmed",
      subscriberId: String(id),
    });
    expect(await Subscriber.collection.findOne({ _id: id })).toEqual(afterFirst);
  });

  it("stops recognising the spent link once its original expiry passes", async () => {
    const token = rawToken(7);
    const confirmationExpiresAt = new Date(backendNow.getTime() + 60_000);
    const id = await insertPending(token, { confirmationExpiresAt });
    await createConfirmSubscription({
      generateRawUnsubscribeToken: () => rawToken(8),
    })(token, backendNow);
    const afterFirst = await Subscriber.collection.findOne({ _id: id });

    const repeated = await createConfirmSubscription({
      generateRawUnsubscribeToken: () => rawToken(9),
    })(token, new Date(confirmationExpiresAt.getTime() + 1));

    expect(repeated).toEqual({ outcome: "invalid" });
    expect(await Subscriber.collection.findOne({ _id: id })).toEqual(afterFirst);
  });

  it("leaves an expired pending token completely unmutated", async () => {
    const token = rawToken(10);
    const id = await insertPending(token, {
      confirmationExpiresAt: new Date(backendNow.getTime() - 1),
    });
    const before = await Subscriber.collection.findOne({ _id: id });

    const result = await createConfirmSubscription({
      generateRawUnsubscribeToken: () => rawToken(11),
    })(token, backendNow);

    expect(result).toEqual({ outcome: "expired" });
    expect(await Subscriber.collection.findOne({ _id: id })).toEqual(before);
  });

  it("leaves an unknown token unmutated across every record", async () => {
    const id = await insertPending(rawToken(12));
    const before = await Subscriber.collection.findOne({ _id: id });

    const result = await createConfirmSubscription({
      generateRawUnsubscribeToken: () => rawToken(13),
    })(rawToken(14), backendNow);

    expect(result).toEqual({ outcome: "invalid" });
    expect(await Subscriber.collection.findOne({ _id: id })).toEqual(before);
  });

  it.each([
    [
      "a live signup send lease",
      new Date(backendNow.getTime() - 1_000),
    ],
    [
      "an orphaned send lease",
      new Date(backendNow.getTime() - 60 * 60 * 1000),
    ],
  ])("confirms under %s and clears its ownership", async (_label, attemptAt) => {
    const token = rawToken(15);
    const id = await insertPending(token, {
      confirmationSendAttemptId: "signup-attempt",
      confirmationSendAttemptAt: attemptAt,
    });

    const result = await createConfirmSubscription({
      generateRawUnsubscribeToken: () => rawToken(16),
    })(token, backendNow);

    expect(result.outcome).toBe("confirmed");
    const stored = await Subscriber.collection.findOne({ _id: id });
    expect(stored?.status).toBe("confirmed");
    expect(stored).not.toHaveProperty("confirmationSendAttemptId");
    expect(stored).not.toHaveProperty("confirmationSendAttemptAt");
  });

  describe("late Day 2 compensation cannot undo confirmation", () => {
    const token = rawToken(17);
    const attemptId = "signup-attempt";

    async function confirmUnderLease() {
      const id = await insertPending(token, {
        confirmationSendAttemptId: attemptId,
        confirmationSendAttemptAt: backendNow,
      });
      const result = await createConfirmSubscription({
        generateRawUnsubscribeToken: () => rawToken(18),
      })(token, backendNow);
      expect(result.outcome).toBe("confirmed");
      return { id, confirmed: await Subscriber.collection.findOne({ _id: id }) };
    }

    it("cannot delete the confirmed subscriber", async () => {
      const { id, confirmed } = await confirmUnderLease();

      // The exact digest-and-attempt filter the signup slice uses for a
      // brand-new record whose provider submission failed.
      await Subscriber.deleteOne({
        _id: id,
        confirmationTokenDigest: digestSubscriptionToken(token),
        confirmationSendAttemptId: attemptId,
      });

      expect(await Subscriber.collection.findOne({ _id: id })).toEqual(confirmed);
    });

    it("cannot roll the subscriber back to pending or replace its credential", async () => {
      const { id, confirmed } = await confirmUnderLease();

      await Subscriber.updateOne(
        {
          _id: id,
          confirmationTokenDigest: digestSubscriptionToken(token),
          confirmationSendAttemptId: attemptId,
        },
        {
          $set: {
            status: "pending",
            confirmationTokenDigest: digestSubscriptionToken(token),
            confirmationExpiresAt: new Date(backendNow.getTime() + 60_000),
            unsubscribeTokenDigest: "f".repeat(64),
          },
        }
      );

      const stored = await Subscriber.collection.findOne({ _id: id });
      expect(stored).toEqual(confirmed);
      expect(stored?.status).toBe("confirmed");
      expect(stored?.unsubscribeTokenDigest).toBe(
        confirmed?.unsubscribeTokenDigest
      );
    });

    it("cannot clear the send owner it no longer matches", async () => {
      const { id, confirmed } = await confirmUnderLease();

      await Subscriber.updateOne(
        {
          _id: id,
          confirmationTokenDigest: digestSubscriptionToken(token),
          confirmationSendAttemptId: attemptId,
        },
        {
          $unset: {
            confirmationSendAttemptId: "",
            confirmationSendAttemptAt: "",
          },
        }
      );

      expect(await Subscriber.collection.findOne({ _id: id })).toEqual(confirmed);
    });
  });

  it("leaves a legacy confirmed subscriber untouched and unmigrated", async () => {
    const id = new mongoose.Types.ObjectId();
    await Subscriber.collection.insertOne({
      _id: id,
      email: "legacy@example.edu",
      status: "confirmed",
      confirmToken: "legacy-raw-confirm-token",
      unsubToken: "legacy-raw-unsubscribe-token",
      bounced: false,
      dailyCount: 2,
      lastSentAt: new Date("2026-08-03T12:00:00.000Z"),
    });
    const before = await Subscriber.collection.findOne({ _id: id });

    const result = await createConfirmSubscription({
      generateRawUnsubscribeToken: () => rawToken(19),
    })(rawToken(21), backendNow);

    expect(result).toEqual({ outcome: "invalid" });
    const stored = await Subscriber.collection.findOne({ _id: id });
    expect(stored).toEqual(before);
    expect(stored).not.toHaveProperty("lastConfirmedTokenDigest");
    expect(stored).not.toHaveProperty("lastConfirmedTokenExpiresAt");
    expect(stored).not.toHaveProperty("unsubscribeTokenDigest");
    expect(stored?.unsubToken).toBe("legacy-raw-unsubscribe-token");
  });
});
