import { describe, expect, it } from "vitest";
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
