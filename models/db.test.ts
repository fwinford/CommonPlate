import { describe, expect, it } from "vitest";
import { Request as MealRequest } from "./db.js";

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
});
