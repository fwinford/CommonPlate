import "dotenv/config";
import { pathToFileURL } from "node:url";
import mongoose from "mongoose";
import { Request as MealRequest } from "../models/db.js";

export const UI_FIXTURE_MARKER = {
  vendor: "CommonPlate QA Dining Hall",
  food: "Test meal — safe to delete",
  pickupName: "QA Test Student",
  email: "commonplate-ui-seed@example.invalid",
  pickupWindowText: "Available for UI review",
} as const;

const FIXTURE_LIFETIME_MS = 2 * 60 * 60 * 1000;
const SAFE_DATABASE_NAME =
  /^(test|testing|dev|development|local|qa|staging|sandbox)$|(^|[-_])(test|testing|dev|development|local|qa|staging|sandbox)([-_]|$)/i;
const PRODUCTION_DATABASE_NAME =
  /^(commonplate|prod|production|live)$|(^|[-_])(prod|production|live)([-_]|$)/i;

type SeedEnvironment = {
  [key: string]: string | undefined;
  ALLOW_LOCAL_SEED?: string;
  MONGO_URI?: string;
  NODE_ENV?: string;
};

type SeedOperation = "seed" | "cleanup";

export class SeedSafetyError extends Error {}

export function validateRuntimeSafety(environment: SeedEnvironment): string {
  if (environment.NODE_ENV?.toLowerCase() === "production") {
    throw new SeedSafetyError(
      "Refusing to seed or clean up while NODE_ENV=production."
    );
  }

  if (environment.ALLOW_LOCAL_SEED !== "true") {
    throw new SeedSafetyError(
      "Refusing to continue without ALLOW_LOCAL_SEED=true."
    );
  }

  if (!environment.MONGO_URI) {
    throw new SeedSafetyError("MONGO_URI is required.");
  }

  return environment.MONGO_URI;
}

export function parseExplicitDatabaseName(uri: string): string | null {
  let parsed: URL;
  try {
    parsed = new URL(uri);
  } catch {
    throw new SeedSafetyError("MONGO_URI could not be parsed safely.");
  }

  const queryDatabaseName = parsed.searchParams.get("dbName");
  const pathDatabaseName = parsed.pathname.replace(/^\/+/, "").split("/")[0];
  const encodedDatabaseName = queryDatabaseName || pathDatabaseName;
  return encodedDatabaseName ? decodeURIComponent(encodedDatabaseName) : null;
}

export function assertSafeDatabaseName(databaseName: string): void {
  if (PRODUCTION_DATABASE_NAME.test(databaseName)) {
    throw new SeedSafetyError(
      `Refusing to modify production-like database "${databaseName}".`
    );
  }

  if (!SAFE_DATABASE_NAME.test(databaseName)) {
    throw new SeedSafetyError(
      `Refusing to modify database "${databaseName}" because its name is not clearly development/test.`
    );
  }
}

export function buildExactFixtureFilter() {
  return { ...UI_FIXTURE_MARKER };
}

export function buildFixtureDocument(now = new Date()) {
  return {
    ...UI_FIXTURE_MARKER,
    status: "requested" as const,
    expiresAt: new Date(now.getTime() + FIXTURE_LIFETIME_MS),
  };
}

function parseOperation(argument: string | undefined): SeedOperation {
  if (argument === "seed" || argument === "cleanup") {
    return argument;
  }
  throw new SeedSafetyError(
    "Usage: tsx scripts/seed-ui-request.ts <seed|cleanup>"
  );
}

async function seed(databaseName: string): Promise<void> {
  const filter = buildExactFixtureFilter();
  const removed = await MealRequest.deleteMany(filter).exec();
  const request = await MealRequest.create(buildFixtureDocument());

  console.log(`database name: ${databaseName}`);
  console.log(`removed prior matching fixtures: ${removed.deletedCount}`);
  console.log(`inserted request ID: ${String(request._id)}`);
  console.log(`expiration: ${request.expiresAt?.toISOString()}`);
  console.log(
    "cleanup command: ALLOW_LOCAL_SEED=true npm run seed:ui:cleanup"
  );
}

async function cleanup(databaseName: string): Promise<void> {
  const result = await MealRequest.deleteMany(buildExactFixtureFilter()).exec();

  console.log(`database name: ${databaseName}`);
  console.log(`matching fixtures removed: ${result.deletedCount}`);
}

export async function runSeedTool(
  operationArgument: string | undefined,
  environment: SeedEnvironment = process.env
): Promise<void> {
  const operation = parseOperation(operationArgument);
  const uri = validateRuntimeSafety(environment);
  const explicitDatabaseName = parseExplicitDatabaseName(uri);
  if (explicitDatabaseName) {
    assertSafeDatabaseName(explicitDatabaseName);
  }

  try {
    await mongoose.connect(uri);
    const databaseName = mongoose.connection.name;
    assertSafeDatabaseName(databaseName);

    if (operation === "seed") {
      await seed(databaseName);
    } else {
      await cleanup(databaseName);
    }
  } finally {
    await mongoose.disconnect().catch(() => undefined);
  }
}

const entryPath = process.argv[1];
if (entryPath && import.meta.url === pathToFileURL(entryPath).href) {
  try {
    await runSeedTool(process.argv[2]);
  } catch (error) {
    const message =
      error instanceof SeedSafetyError
        ? error.message
        : "UI seed operation failed; no credentials were printed.";
    console.error(message);
    process.exitCode = 1;
  }
}
