import type { Request, Response } from "express";
import mongoose from "mongoose";
import {
  afterAll,
  afterEach,
  beforeAll,
  describe,
  expect,
  it,
  vi,
} from "vitest";
import { Request as MealRequest } from "../models/db.js";
import { claimRequest } from "./claimRoute.js";
import {
  CLAIM_MINIMUM_REMAINING_MS,
  buildEffectiveAvailabilityFilter,
} from "./requestAvailability.js";
import {
  buildPublicRequestListResponse,
  type RequestListDocument,
} from "./requestListResponse.js";

/**
 * Integration files run in parallel against the same mongod, and this suite
 * clears the collection between cases. It gets its own database so that cleanup
 * cannot delete another file's fixtures mid-run.
 */
function isolatedDatabaseUri(base: string): string {
  const uri = new URL(base);
  uri.pathname = `${uri.pathname}_availability`;
  return uri.toString();
}

const mongoUri = process.env.MONGO_INTEGRATION_URI
  ? isolatedDatabaseUri(process.env.MONGO_INTEGRATION_URI)
  : undefined;
const describeMongo = mongoUri ? describe : describe.skip;

/**
 * Every advertising query is driven by one instant the caller captures, and
 * these fixtures are positioned relative to that same instant. Nothing here
 * compares against a clock read later in the test, so the boundary cases are
 * exact rather than racy.
 */
function fixtures(now: Date) {
  const exactMinimum = new Date(now.getTime() + CLAIM_MINIMUM_REMAINING_MS);
  const justShort = new Date(exactMinimum.getTime() - 1);
  const farFuture = new Date(now.getTime() + 60 * 60 * 1000);

  return [
    { food: "exact-minimum", status: "open", expiresAt: exactMinimum },
    { food: "just-short", status: "open", expiresAt: justShort },
    {
      food: "expired-claim-with-runway",
      status: "claimed",
      expiresAt: farFuture,
      claimExpiresAt: new Date(now.getTime() - 1),
    },
    {
      food: "expired-claim-too-short",
      status: "claimed",
      expiresAt: justShort,
      claimExpiresAt: new Date(now.getTime() - 1),
    },
    {
      food: "active-claim",
      status: "claimed",
      expiresAt: farFuture,
      claimExpiresAt: new Date(now.getTime() + 10 * 60 * 1000),
    },
    { food: "already-expired", status: "open", expiresAt: now },
  ];
}

async function seed(now: Date) {
  await MealRequest.insertMany(
    fixtures(now).map((fixture) => ({
      vendor: "Boundary Cafe",
      pickupName: "Boundary Requester",
      pickupWindowText: "ASAP",
      email: "requester@example.edu",
      createdAt: new Date(now.getTime() - 60 * 1000),
      // Retention, not availability. Held past the run so the TTL monitor can
      // never remove a fixture mid-test.
      deleteAt: new Date(now.getTime() + 60 * 60 * 1000),
      ...fixture,
    }))
  );
}

function foods(documents: { food: string }[]): string[] {
  return documents.map((document) => document.food).sort();
}

describeMongo("advertised availability against a real database", () => {
  beforeAll(async () => {
    vi.stubEnv(
      "CLAIM_TOKEN_HMAC_SECRET",
      "real-mongo-test-secret-material-32-bytes"
    );
    await mongoose.connect(mongoUri!);
    await MealRequest.syncIndexes();
  });

  afterEach(async () => {
    await MealRequest.deleteMany({});
  });

  afterAll(async () => {
    await mongoose.disconnect();
    vi.unstubAllEnvs();
  });

  it("excludes short-lived requests from the GET /api/requests query", async () => {
    const now = new Date();
    await seed(now);

    // The exact query and projection GET /api/requests runs, both handed the
    // one captured instant.
    const documents = await MealRequest.find(
      buildEffectiveAvailabilityFilter(now)
    )
      .limit(200)
      .lean()
      .exec();
    const response = buildPublicRequestListResponse(
      documents as unknown as RequestListDocument[],
      now
    );

    expect(foods(documents as unknown as { food: string }[])).toEqual([
      "exact-minimum",
      "expired-claim-with-runway",
    ]);
    expect(foods(response.requests)).toEqual([
      "exact-minimum",
      "expired-claim-with-runway",
    ]);
    expect(
      response.requests.map((request) => request.status)
    ).toEqual(["open", "open"]);
  });

  it("leaves every record untouched while reading", async () => {
    const now = new Date();
    await seed(now);
    const before = await MealRequest.find({}).sort({ food: 1 }).lean();

    await MealRequest.find(buildEffectiveAvailabilityFilter(now)).lean();

    const after = await MealRequest.find({}).sort({ food: 1 }).lean();
    expect(after).toEqual(before);
    // The reopened request is still persisted as a claim; only the projection
    // called it open.
    expect(
      after.find((document) => document.food === "expired-claim-with-runway")
        ?.status
    ).toBe("claimed");
  });

  it("excludes short-lived requests from the hourly digest query", async () => {
    const digestNow = new Date();
    await seed(digestNow);
    const oneHourAgo = new Date(digestNow.getTime() - 60 * 60 * 1000);

    const recentRequests = await MealRequest.find({
      createdAt: { $gte: oneHourAgo },
      ...buildEffectiveAvailabilityFilter(digestNow),
    }).lean();

    expect(foods(recentRequests as unknown as { food: string }[])).toEqual([
      "exact-minimum",
      "expired-claim-with-runway",
    ]);
  });

  it("excludes short-lived requests from recent-request notification queries", async () => {
    const availabilityNow = new Date();
    await seed(availabilityNow);
    const since = new Date(availabilityNow.getTime() - 24 * 60 * 60 * 1000);

    const recentRequests = await MealRequest.find({
      createdAt: { $gte: since },
      ...buildEffectiveAvailabilityFilter(availabilityNow),
    })
      .sort({ createdAt: -1 })
      .limit(50)
      .lean();

    expect(foods(recentRequests as unknown as { food: string }[])).toEqual([
      "exact-minimum",
      "expired-claim-with-runway",
    ]);
  });

  it("excludes a single request from the real-time alert availability check", async () => {
    const now = new Date();
    await seed(now);
    const shortLived = await MealRequest.findOne({ food: "just-short" }).lean();

    const stillAvailable = await MealRequest.exists({
      _id: shortLived!._id,
      ...buildEffectiveAvailabilityFilter(now),
    });

    expect(stillAvailable).toBeNull();
  });

  it("refuses to claim what it refuses to advertise", async () => {
    const now = new Date();
    await seed(now);
    const shortLived = await MealRequest.findOne({ food: "just-short" }).lean();
    // The claim route captures its own instant, which can only be later than
    // `now` — so a request already inside the final five minutes is refused
    // regardless of how long this test takes.
    const req = {
      params: { id: String(shortLived!._id) },
    } as unknown as Request;
    const res = {} as Response;
    let statusCode = 200;
    let body: any;
    res.status = vi.fn((value: number) => {
      statusCode = value;
      return res;
    }) as any;
    res.json = vi.fn((value: unknown) => {
      body = value;
      return res;
    }) as any;

    await claimRequest(req, res);

    expect(statusCode).toBe(409);
    expect(body.error.code).toBe("REQUEST_INSUFFICIENT_TIME");
  });
});
