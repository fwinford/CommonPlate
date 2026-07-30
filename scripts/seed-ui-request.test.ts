import { describe, expect, it } from "vitest";
import {
  SeedSafetyError,
  UI_FIXTURE_MARKER,
  assertSafeDatabaseName,
  buildExactFixtureFilter,
  buildFixtureDocument,
  parseExplicitDatabaseName,
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
