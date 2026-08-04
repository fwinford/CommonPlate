import { describe, expect, it } from "vitest";
import {
  INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION,
  MAXIMUM_UNSUBSCRIBE_CREDENTIAL_VERSION,
} from "../src/unsubscribeCredential.js";
import { Fulfillment, Request as MealRequest, Subscriber } from "./db.js";

describe("Subscriber pending-confirmation schema", () => {
  it("keeps confirmation digests, expiry, ownership, and legacy raw state private", () => {
    for (const field of [
      "confirmationTokenDigest",
      "confirmationExpiresAt",
      "confirmationSendAttemptId",
      "confirmationSendAttemptAt",
      "confirmToken",
    ]) {
      expect((Subscriber.schema.path(field) as any).options.select).toBe(false);
    }
  });

  it("requires the digest and expiry for new pending subscribers", () => {
    const missingLifecycle = new Subscriber({ email: "helper@example.edu" });
    const validPending = new Subscriber({
      email: "helper@example.edu",
      status: "pending",
      confirmationTokenDigest: "a".repeat(64),
      confirmationExpiresAt: new Date("2026-08-04T00:00:00.000Z"),
    });

    expect(missingLifecycle.validateSync()?.errors).toHaveProperty(
      "confirmationTokenDigest"
    );
    expect(missingLifecycle.validateSync()?.errors).toHaveProperty(
      "confirmationExpiresAt"
    );
    expect(validPending.validateSync()).toBeUndefined();
  });
});

describe("Subscriber unsubscribe credential version", () => {
  it("gives every new subscriber the initial version without being asked", () => {
    const created = new Subscriber({
      email: "helper@example.edu",
      status: "pending",
      confirmationTokenDigest: "a".repeat(64),
      confirmationExpiresAt: new Date("2026-08-04T00:00:00.000Z"),
    });

    expect(created.unsubscribeCredentialVersion).toBe(
      INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION
    );
    expect(INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION).toBe(1);
    expect(created.validateSync()).toBeUndefined();
  });

  it("keeps the version readable in ordinary projections", () => {
    // Alert and digest sends build the unsubscribe link from this field, so
    // unlike the confirmation digests it must not be `select: false`.
    const versionPath = Subscriber.schema.path(
      "unsubscribeCredentialVersion"
    ) as any;

    expect(versionPath.options.select).toBeUndefined();
  });

  it.each([
    ["zero", 0],
    ["a negative version", -1],
    ["a fractional version", 1.5],
    ["a version past the ceiling", MAXIMUM_UNSUBSCRIBE_CREDENTIAL_VERSION + 1],
  ])("rejects %s", (_label, version) => {
    const outOfRange = new Subscriber({
      email: "version@example.edu",
      status: "confirmed",
      unsubscribeCredentialVersion: version,
    });

    expect(outOfRange.validateSync()?.errors).toHaveProperty(
      "unsubscribeCredentialVersion"
    );
  });

  it("keeps the legacy raw unsubscribe token out of ordinary projections", () => {
    // Nothing reads it any more, so it should behave like every other private
    // credential field rather than riding along on ordinary Subscriber reads.
    expect(
      (Subscriber.schema.path("unsubToken") as any).options.select
    ).toBe(false);
  });

  it("no longer models a stored unsubscribe credential", () => {
    // The credential is signed on demand, so there is nothing to store and no
    // confirmed-row invariant that a stored digest could satisfy.
    expect(Subscriber.schema.path("unsubscribeTokenDigest")).toBeUndefined();
    expect(
      new Subscriber({
        email: "confirmed@example.edu",
        status: "confirmed",
      }).validateSync()
    ).toBeUndefined();
  });

  it.each(["pending", "confirmed", "unsubscribed"] as const)(
    "leaves a %s subscriber valid carrying only the derived credential",
    (status) => {
      const subscriber = new Subscriber({
        email: "lifecycle@example.edu",
        status,
        ...(status === "pending"
          ? {
              confirmationTokenDigest: "a".repeat(64),
              confirmationExpiresAt: new Date("2026-08-04T00:00:00.000Z"),
            }
          : {}),
      });

      expect(subscriber.validateSync()).toBeUndefined();
      expect(subscriber.unsubscribeCredentialVersion).toBe(
        INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION
      );
    }
  );
});

describe("Request lifecycle and retention schema", () => {
  it("uses only open, claimed, and placed with open as the default", () => {
    const statusPath = MealRequest.schema.path("status") as unknown as {
      options: { enum: string[]; default: string };
    };

    expect(statusPath.options.enum).toEqual(["open", "claimed", "placed"]);
    expect(statusPath.options.default).toBe("open");
    expect(new MealRequest().status).toBe("open");
  });

  it("moves TTL responsibility from expiresAt to private deleteAt", () => {
    const indexes = MealRequest.schema.indexes();
    const ttlIndexes = indexes.filter(
      ([, options]) => options.expireAfterSeconds === 0
    );

    expect(ttlIndexes).toEqual([
      [
        { deleteAt: 1 },
        {
          expireAfterSeconds: 0,
          name: "request_deleteAt_ttl",
          background: true,
        },
      ],
    ]);
    expect(indexes).not.toEqual(
      expect.arrayContaining([
        [{ expiresAt: 1 }, expect.objectContaining({ expireAfterSeconds: 0 })],
      ])
    );
  });

  it("keeps the digest excluded from ordinary model projections", () => {
    const digestPath = MealRequest.schema.path(
      "claimTokenDigest"
    ) as unknown as {
      options: { select: boolean };
    };

    expect(digestPath.options.select).toBe(false);
  });

  it("models private placement and notification verification fields", () => {
    expect(MealRequest.schema.path("placedAt")).toBeDefined();
    expect(MealRequest.schema.path("fulfillerEmail")).toBeDefined();
    expect(MealRequest.schema.path("contactMessage")).toBeDefined();
    expect(MealRequest.schema.path("notificationAttemptedAt")).toBeDefined();
    expect(
      (MealRequest.schema.path("notificationStatus") as any).options.enum
    ).toEqual(["pending", "sent", "failed"]);
    expect(MealRequest.schema.path("helperPhone")).toBeUndefined();
  });
});

describe("Fulfillment all-time ledger schema", () => {
  it("enforces one durable fulfillment per request", () => {
    expect(Fulfillment.schema.indexes()).toEqual(
      expect.arrayContaining([
        [
          { requestId: 1 },
          expect.objectContaining({
            unique: true,
            name: "fulfillment_request_unique",
          }),
        ],
      ])
    );
  });
});
