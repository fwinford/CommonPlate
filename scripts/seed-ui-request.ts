import "dotenv/config";
import { pathToFileURL } from "node:url";
import mongoose, { Types } from "mongoose";
import { Participant, Request as MealRequest } from "../models/db.js";

export const UI_FIXTURE_MARKER = {
  vendor: "CommonPlate QA Dining Hall",
  food: "Test meal — safe to delete",
  email: "commonplate-ui-seed@example.invalid",
  pickupWindowText: "Available for UI review",
  // W3-C1 made this a required part of every request's public shape, and
  // W4-R4 added the structured fields beside it; the client's decoder fails
  // the whole list on a request that omits either, so the fixture carries a
  // complete Meal Exchange representation like every real request.
  menuPath: "meal-exchange",
  mealSwipes: 2,
  mealItems: ["Test meal — safe to delete", "Test side — safe to delete"],
} as const;

const FIXTURE_LIFETIME_MS = 2 * 60 * 60 * 1000;

/** W4-R4 requires exactly one structured meal-detail entry per selected
 * swipe, so a seeded fixture supplies one per swipe rather than a single
 * flat description. */
function mealItemsFor(label: string, mealSwipes: number): string[] {
  return Array.from({ length: mealSwipes }, (_, index) => `${label} — item ${index + 1}`);
}

// W4-H4 device-walkthrough support: distinct varied vendors so the seeded
// owned fixtures are easy to tell apart on screen. This is local dev/test
// tooling only — it has no bearing on the H4 SwiftUI composition contract.
const OWNED_FIXTURE_VENDORS: readonly string[] = [
  "CommonPlate QA Dining Hall",
  "CommonPlate QA Kosher Kitchen",
  "CommonPlate QA Global Eats",
  "CommonPlate QA Vegan Corner",
];

// Every owned fixture's `food` starts with this exact prefix, which is the
// sole cleanup-matching key (alongside the resolved owner's participant id).
// It must never collide with a real request's food description.
export const OWNED_FIXTURE_FOOD_PREFIX = "H4 QA owned fixture";

const MIN_OWNED_FIXTURE_COUNT = 1;
const MAX_OWNED_FIXTURE_COUNT = 20;
const DEFAULT_OWNED_FIXTURE_COUNT = 8;

// W4-H4 device-walkthrough support: reproduces a `Needs help right now`
// board deep enough to reach the persistent `Request Food` area. These
// fixtures are deliberately never owned by anyone — `requesterParticipantId`
// stays `null`, the same "no current-authority server evidence" shape a real
// request has before ownership resolution, which the backend already proves
// resolves to `isOwnRequest: false` for every verified caller (see
// `src/requestDetailOwnership.test.ts`). This tool never looks up or
// fabricates a participant identity for these fixtures.
const NEEDS_HELP_FIXTURE_VENDORS: readonly string[] = [
  "CommonPlate QA Dining Hall",
  "CommonPlate QA Kosher Kitchen",
  "CommonPlate QA Global Eats",
  "CommonPlate QA Vegan Corner",
  "CommonPlate QA Noodle Bar",
];

// Sole cleanup-matching key. Must never collide with a real request's food
// description, and is distinct from `OWNED_FIXTURE_FOOD_PREFIX` so the two
// fixture sets can be seeded/cleaned up independently.
export const NEEDS_HELP_FIXTURE_FOOD_PREFIX = "H4 QA needs-help fixture";

const MIN_NEEDS_HELP_FIXTURE_COUNT = 1;
const MAX_NEEDS_HELP_FIXTURE_COUNT = 20;
const DEFAULT_NEEDS_HELP_FIXTURE_COUNT = 8;
const SAFE_DATABASE_NAME =
  /^(test|testing|dev|development|local|qa|staging|sandbox)$|(^|[-_])(test|testing|dev|development|local|qa|staging|sandbox)([-_]|$)/i;
const PRODUCTION_DATABASE_NAME =
  /^(commonplate|prod|production|live)$|(^|[-_])(prod|production|live)([-_]|$)/i;

type SeedEnvironment = {
  [key: string]: string | undefined;
  ALLOW_LOCAL_SEED?: string;
  MONGO_URI?: string;
  NODE_ENV?: string;
  SEED_OWNER_EMAIL?: string;
  SEED_OWNER_COUNT?: string;
  SEED_NEEDS_HELP_COUNT?: string;
};

type SeedOperation =
  | "seed"
  | "cleanup"
  | "seed-owned"
  | "cleanup-owned"
  | "seed-needs-help"
  | "cleanup-needs-help";

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
  const expiresAt = new Date(now.getTime() + FIXTURE_LIFETIME_MS);
  return {
    ...UI_FIXTURE_MARKER,
    status: "open" as const,
    expiresAt,
    deleteAt: expiresAt,
  };
}

// W4-H4 device-walkthrough support (dev/test tooling only, not part of the
// H4 SwiftUI contract). `ownerEmail` must be the exact address of a
// Participant that already independently completed the app's own email-code
// verification — this tool only looks that record up, it never creates or
// otherwise fabricates verified-participant authority.
export function normalizeOwnerEmail(email: string | undefined): string {
  const trimmed = email?.trim();
  if (!trimmed) {
    throw new SeedSafetyError(
      "SEED_OWNER_EMAIL is required for seed-owned/cleanup-owned."
    );
  }
  return trimmed.toLowerCase();
}

export function parseOwnedFixtureCount(argument: string | undefined): number {
  if (argument === undefined || argument === "") {
    return DEFAULT_OWNED_FIXTURE_COUNT;
  }
  const parsed = Number(argument);
  if (
    !Number.isInteger(parsed) ||
    parsed < MIN_OWNED_FIXTURE_COUNT ||
    parsed > MAX_OWNED_FIXTURE_COUNT
  ) {
    throw new SeedSafetyError(
      `SEED_OWNER_COUNT must be an integer between ${MIN_OWNED_FIXTURE_COUNT} and ${MAX_OWNED_FIXTURE_COUNT}.`
    );
  }
  return parsed;
}

export function buildOwnedFixtureDocument(
  index: number,
  ownerEmail: string,
  requesterParticipantId: unknown,
  now = new Date()
) {
  const expiresAt = new Date(now.getTime() + FIXTURE_LIFETIME_MS);
  const vendor = OWNED_FIXTURE_VENDORS[index % OWNED_FIXTURE_VENDORS.length];
  const label = `${OWNED_FIXTURE_FOOD_PREFIX} #${index + 1}`;
  return {
    vendor,
    food: label,
    email: ownerEmail,
    pickupWindowText: `${label} — safe to delete`,
    menuPath: "meal-exchange",
    mealSwipes: (index % 5) + 1,
    mealItems: mealItemsFor(label, (index % 5) + 1),
    status: "open" as const,
    expiresAt,
    deleteAt: expiresAt,
    requesterParticipantId,
  };
}

export function buildOwnedFixtureFilter(requesterParticipantId: unknown) {
  return {
    requesterParticipantId,
    food: { $regex: `^${escapeRegExp(OWNED_FIXTURE_FOOD_PREFIX)}` },
  };
}

export function parseNeedsHelpFixtureCount(argument: string | undefined): number {
  if (argument === undefined || argument === "") {
    return DEFAULT_NEEDS_HELP_FIXTURE_COUNT;
  }
  const parsed = Number(argument);
  if (
    !Number.isInteger(parsed) ||
    parsed < MIN_NEEDS_HELP_FIXTURE_COUNT ||
    parsed > MAX_NEEDS_HELP_FIXTURE_COUNT
  ) {
    throw new SeedSafetyError(
      `SEED_NEEDS_HELP_COUNT must be an integer between ${MIN_NEEDS_HELP_FIXTURE_COUNT} and ${MAX_NEEDS_HELP_FIXTURE_COUNT}.`
    );
  }
  return parsed;
}

export function buildNeedsHelpFixtureDocument(index: number, now = new Date()) {
  const expiresAt = new Date(now.getTime() + FIXTURE_LIFETIME_MS);
  const vendor = NEEDS_HELP_FIXTURE_VENDORS[index % NEEDS_HELP_FIXTURE_VENDORS.length];
  const label = `${NEEDS_HELP_FIXTURE_FOOD_PREFIX} #${index + 1}`;
  return {
    vendor,
    food: label,
    email: `commonplate-ui-seed-needs-help-${index + 1}@example.invalid`,
    pickupWindowText: `${label} — safe to delete`,
    menuPath: "meal-exchange",
    mealSwipes: (index % 5) + 1,
    mealItems: mealItemsFor(label, (index % 5) + 1),
    status: "open" as const,
    expiresAt,
    deleteAt: expiresAt,
    requesterParticipantId: null,
  };
}

export function buildNeedsHelpFixtureFilter() {
  return {
    food: { $regex: `^${escapeRegExp(NEEDS_HELP_FIXTURE_FOOD_PREFIX)}` },
  };
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function parseOperation(argument: string | undefined): SeedOperation {
  if (
    argument === "seed" ||
    argument === "cleanup" ||
    argument === "seed-owned" ||
    argument === "cleanup-owned" ||
    argument === "seed-needs-help" ||
    argument === "cleanup-needs-help"
  ) {
    return argument;
  }
  throw new SeedSafetyError(
    "Usage: tsx scripts/seed-ui-request.ts <seed|cleanup|seed-owned|cleanup-owned|seed-needs-help|cleanup-needs-help>"
  );
}

// Looks up an *already verified* Participant by email — never creates one.
// A missing record means Faith has not yet verified that address in the app
// on this database, which this tool must not work around.
async function findOwnerParticipantId(ownerEmail: string): Promise<Types.ObjectId> {
  const participant = await Participant.findOne({ email: ownerEmail })
    .select("_id")
    .lean()
    .exec();
  if (!participant) {
    throw new SeedSafetyError(
      `No verified Participant found for "${ownerEmail}" in this database. ` +
        "Verify that email in the app first (this tool never creates or " +
        "fabricates participant identity)."
    );
  }
  return participant._id as Types.ObjectId;
}

async function seedOwned(
  databaseName: string,
  ownerEmail: string,
  count: number
): Promise<void> {
  const participantId = await findOwnerParticipantId(ownerEmail);
  const filter = buildOwnedFixtureFilter(participantId);
  const removed = await MealRequest.deleteMany(filter).exec();

  const now = new Date();
  const documents = Array.from({ length: count }, (_, index) =>
    buildOwnedFixtureDocument(index, ownerEmail, participantId, now)
  );
  const created = await MealRequest.insertMany(documents);

  console.log(`database name: ${databaseName}`);
  console.log(`owner email: ${ownerEmail}`);
  console.log(`owner participant id: ${String(participantId)}`);
  console.log(`removed prior matching owned fixtures: ${removed.deletedCount}`);
  console.log(`inserted owned fixtures: ${created.length}`);
  console.log(`expiration: ${documents[0]!.expiresAt.toISOString()}`);
  console.log(
    `cleanup command: ALLOW_LOCAL_SEED=true SEED_OWNER_EMAIL=${ownerEmail} npm run seed:ui:owned:cleanup`
  );
}

async function cleanupOwned(databaseName: string, ownerEmail: string): Promise<void> {
  const participantId = await findOwnerParticipantId(ownerEmail);
  const result = await MealRequest.deleteMany(
    buildOwnedFixtureFilter(participantId)
  ).exec();

  console.log(`database name: ${databaseName}`);
  console.log(`owner email: ${ownerEmail}`);
  console.log(`matching owned fixtures removed: ${result.deletedCount}`);
}

async function seedNeedsHelp(databaseName: string, count: number): Promise<void> {
  const filter = buildNeedsHelpFixtureFilter();
  const removed = await MealRequest.deleteMany(filter).exec();

  const now = new Date();
  const documents = Array.from({ length: count }, (_, index) =>
    buildNeedsHelpFixtureDocument(index, now)
  );
  const created = await MealRequest.insertMany(documents);

  console.log(`database name: ${databaseName}`);
  console.log(`removed prior matching needs-help fixtures: ${removed.deletedCount}`);
  console.log(`inserted needs-help fixtures: ${created.length}`);
  console.log(`expiration: ${documents[0]!.expiresAt.toISOString()}`);
  console.log(
    "cleanup command: ALLOW_LOCAL_SEED=true npm run seed:ui:needs-help:cleanup"
  );
}

async function cleanupNeedsHelp(databaseName: string): Promise<void> {
  const result = await MealRequest.deleteMany(buildNeedsHelpFixtureFilter()).exec();

  console.log(`database name: ${databaseName}`);
  console.log(`matching needs-help fixtures removed: ${result.deletedCount}`);
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
    } else if (operation === "cleanup") {
      await cleanup(databaseName);
    } else if (operation === "seed-owned") {
      const ownerEmail = normalizeOwnerEmail(environment.SEED_OWNER_EMAIL);
      const count = parseOwnedFixtureCount(environment.SEED_OWNER_COUNT);
      await seedOwned(databaseName, ownerEmail, count);
    } else if (operation === "cleanup-owned") {
      const ownerEmail = normalizeOwnerEmail(environment.SEED_OWNER_EMAIL);
      await cleanupOwned(databaseName, ownerEmail);
    } else if (operation === "seed-needs-help") {
      const count = parseNeedsHelpFixtureCount(environment.SEED_NEEDS_HELP_COUNT);
      await seedNeedsHelp(databaseName, count);
    } else {
      await cleanupNeedsHelp(databaseName);
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
