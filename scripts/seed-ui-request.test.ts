import { describe, expect, it } from "vitest";
import {
  NEEDS_HELP_FIXTURE_FOOD_PREFIX,
  OWNED_FIXTURE_FOOD_PREFIX,
  SeedSafetyError,
  UI_FIXTURE_MARKER,
  assertSafeDatabaseName,
  buildExactFixtureFilter,
  buildFixtureDocument,
  buildNeedsHelpFixtureDocument,
  buildNeedsHelpFixtureFilter,
  buildOwnedFixtureDocument,
  buildOwnedFixtureFilter,
  normalizeOwnerEmail,
  parseExplicitDatabaseName,
  parseNeedsHelpFixtureCount,
  parseOwnedFixtureCount,
  validateRuntimeSafety,
} from "./seed-ui-request.js";

describe("UI request seed safety", () => {
  it("refuses production mode", () => {
    expect(() =>
      validateRuntimeSafety({
        NODE_ENV: "production",
        ALLOW_LOCAL_SEED: "true",
        MONGO_URI: "mongodb://localhost/commonplate_test",
      })
    ).toThrow(SeedSafetyError);
  });

  it("requires explicit confirmation", () => {
    expect(() =>
      validateRuntimeSafety({
        NODE_ENV: "development",
        ALLOW_LOCAL_SEED: "false",
        MONGO_URI: "mongodb://localhost/commonplate_test",
      })
    ).toThrow("ALLOW_LOCAL_SEED=true");
  });

  it("requires a MongoDB URI", () => {
    expect(() =>
      validateRuntimeSafety({
        NODE_ENV: "development",
        ALLOW_LOCAL_SEED: "true",
      })
    ).toThrow("MONGO_URI is required");
  });

  it.each(["prod", "production", "commonplate", "commonplate-production"])(
    "refuses production-like database name %s",
    (databaseName) => {
      expect(() => assertSafeDatabaseName(databaseName)).toThrow(
        "production-like"
      );
    }
  );

  it.each(["test", "commonplate_dev", "commonplate_test", "commonplate_local"])(
    "accepts clearly non-production database name %s",
    (databaseName) => {
      expect(() => assertSafeDatabaseName(databaseName)).not.toThrow();
    }
  );

  it("parses only the database name from a URI", () => {
    expect(
      parseExplicitDatabaseName(
        "mongodb://localhost:27017/commonplate_test?retryWrites=true"
      )
    ).toBe("commonplate_test");
  });
});

describe("UI request fixture", () => {
  it("builds an exact cleanup filter from all identifying values", () => {
    expect(buildExactFixtureFilter()).toEqual(UI_FIXTURE_MARKER);
  });

  it("builds an open fixture with matching availability and deletion deadlines", () => {
    const now = new Date("2026-07-26T12:00:00.000Z");
    const fixture = buildFixtureDocument(now);

    expect(fixture).toMatchObject({
      ...UI_FIXTURE_MARKER,
      status: "open",
    });
    expect(fixture.expiresAt.toISOString()).toBe("2026-07-26T14:00:00.000Z");
    expect(fixture.deleteAt).toEqual(fixture.expiresAt);
  });
});

describe("W4-H4 owned fixture tooling", () => {
  it("requires an owner email", () => {
    expect(() => normalizeOwnerEmail(undefined)).toThrow(SeedSafetyError);
    expect(() => normalizeOwnerEmail("   ")).toThrow("SEED_OWNER_EMAIL");
  });

  it("normalizes an owner email to lowercase and trimmed", () => {
    expect(normalizeOwnerEmail("  Faith@NYU.edu  ")).toBe("faith@nyu.edu");
  });

  it("defaults the owned fixture count to 8", () => {
    expect(parseOwnedFixtureCount(undefined)).toBe(8);
    expect(parseOwnedFixtureCount("")).toBe(8);
  });

  it("accepts an explicit in-range owned fixture count", () => {
    expect(parseOwnedFixtureCount("10")).toBe(10);
  });

  it.each(["0", "21", "abc", "3.5"])(
    "rejects an out-of-range or non-integer owned fixture count %s",
    (value) => {
      expect(() => parseOwnedFixtureCount(value)).toThrow(SeedSafetyError);
    }
  );

  it("builds distinguishable owned fixtures sharing the resolved participant id", () => {
    const now = new Date("2026-08-22T12:00:00.000Z");
    const participantId = "participant-id-123";
    const first = buildOwnedFixtureDocument(0, "faith@nyu.edu", participantId, now);
    const second = buildOwnedFixtureDocument(1, "faith@nyu.edu", participantId, now);

    expect(first.requesterParticipantId).toBe(participantId);
    expect(second.requesterParticipantId).toBe(participantId);
    expect(first.email).toBe("faith@nyu.edu");
    expect(first.status).toBe("open");
    expect(first.food).toBe(`${OWNED_FIXTURE_FOOD_PREFIX} #1`);
    expect(second.food).toBe(`${OWNED_FIXTURE_FOOD_PREFIX} #2`);
    expect(first.vendor).not.toBe(second.vendor);
    expect(first.expiresAt.toISOString()).toBe("2026-08-22T14:00:00.000Z");
    expect(first.deleteAt).toEqual(first.expiresAt);
  });

  it("builds a cleanup filter scoped to both the participant id and the fixture prefix", () => {
    const filter = buildOwnedFixtureFilter("participant-id-123");

    expect(filter.requesterParticipantId).toBe("participant-id-123");
    expect(filter.food.$regex).toBe(`^${OWNED_FIXTURE_FOOD_PREFIX}`);
    // Never matches a real request's food description, only fixtures this
    // tool itself created.
    expect(new RegExp(filter.food.$regex).test("Chicken biryani")).toBe(false);
    expect(new RegExp(filter.food.$regex).test(`${OWNED_FIXTURE_FOOD_PREFIX} #4`)).toBe(true);
  });
});

describe("W4-H4 needs-help fixture tooling", () => {
  it("defaults the needs-help fixture count to 8", () => {
    expect(parseNeedsHelpFixtureCount(undefined)).toBe(8);
    expect(parseNeedsHelpFixtureCount("")).toBe(8);
  });

  it("accepts an explicit in-range needs-help fixture count", () => {
    expect(parseNeedsHelpFixtureCount("10")).toBe(10);
  });

  it.each(["0", "21", "abc", "3.5"])(
    "rejects an out-of-range or non-integer needs-help fixture count %s",
    (value) => {
      expect(() => parseNeedsHelpFixtureCount(value)).toThrow(SeedSafetyError);
    }
  );

  it("builds distinguishable needs-help fixtures that are never owned by anyone", () => {
    const now = new Date("2026-08-22T12:00:00.000Z");
    const first = buildNeedsHelpFixtureDocument(0, now);
    const second = buildNeedsHelpFixtureDocument(1, now);

    // `null` matches the same "no current-authority server evidence" shape
    // a real not-yet-owned request has; the backend already proves this
    // resolves to `isOwnRequest: false` for every verified caller.
    expect(first.requesterParticipantId).toBeNull();
    expect(second.requesterParticipantId).toBeNull();
    expect(first.status).toBe("open");
    expect(first.food).toBe(`${NEEDS_HELP_FIXTURE_FOOD_PREFIX} #1`);
    expect(second.food).toBe(`${NEEDS_HELP_FIXTURE_FOOD_PREFIX} #2`);
    expect(first.vendor).not.toBe(second.vendor);
    expect(first.expiresAt.toISOString()).toBe("2026-08-22T14:00:00.000Z");
    expect(first.deleteAt).toEqual(first.expiresAt);
  });

  it("builds a cleanup filter scoped only to the needs-help fixture prefix", () => {
    const filter = buildNeedsHelpFixtureFilter();

    expect(filter.food.$regex).toBe(`^${NEEDS_HELP_FIXTURE_FOOD_PREFIX}`);
    // Never matches a real request's food description or the owned-fixture
    // prefix, only fixtures this tool itself created for this operation.
    expect(new RegExp(filter.food.$regex).test("Chicken biryani")).toBe(false);
    expect(new RegExp(filter.food.$regex).test(OWNED_FIXTURE_FOOD_PREFIX)).toBe(false);
    expect(new RegExp(filter.food.$regex).test(`${NEEDS_HELP_FIXTURE_FOOD_PREFIX} #4`)).toBe(true);
  });
});
