import express, { type Request, type Response } from "express";
import { readFileSync, readdirSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import mongoose from "mongoose";
import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";

const { resendSend, notifySubscribersForRequest } = vi.hoisted(() => ({
  resendSend: vi.fn(),
  notifySubscribersForRequest: vi.fn(),
}));

vi.mock("resend", () => ({
  Resend: class {
    emails = { send: resendSend };
  },
}));

vi.mock("./notifySubscribers.js", () => ({
  notifySubscribersForRequest,
}));

import { Request as MealRequest } from "../models/db.js";
import {
  createRequest,
  createRequestRateLimiter,
} from "./createRequestRoute.js";

const requestId = new mongoose.Types.ObjectId("64b000000000000000000001");
/** Frozen backend creation time; the route's `new Date()` resolves to this. */
const createdAt = new Date("2026-07-28T16:00:00.000Z");
/** Five hours after `createdAt`. */
const asapExpiresAt = new Date("2026-07-28T21:00:00.000Z");

function canonicalAsap(overrides: Record<string, unknown> = {}) {
  return {
    vendor: "  Campus Market  ",
    food: "  Vegetable rice bowl  ",
    pickupName: "  Requester Private Name  ",
    email: "  REQUESTER@EXAMPLE.EDU  ",
    timing: "asap",
    ...overrides,
  };
}

function canonicalScheduled(overrides: Record<string, unknown> = {}) {
  return {
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName: "Requester Private Name",
    email: "requester@example.edu",
    timing: "scheduled",
    windowStart: "2026-07-28T17:00:00.000Z",
    windowEnd: "2026-07-28T18:00:00.000Z",
    ...overrides,
  };
}

function routeContext(body: unknown) {
  const req = { body } as Request;
  const res = {} as Response;
  const status = vi.fn().mockReturnValue(res);
  const json = vi.fn().mockReturnValue(res);
  res.status = status;
  res.json = json;
  return { req, res, status, json };
}

function persistedDocument(input: Record<string, unknown>) {
  return {
    _id: requestId,
    ...input,
    status: "open",
    createdAt,
    updatedAt: createdAt,
    // Deliberately no `expiresAt` override: the persisted document echoes
    // whatever the route wrote, so the response assertions prove the canonical
    // backend expiration rather than a fixture constant.
    pickupName: input.pickupName,
    email: input.email,
    claimToken: "private-claim-token",
    orderNumber: "private-order-number",
    notificationStatus: "private-notification-state",
    __v: 0,
  };
}

let countDocuments: ReturnType<typeof vi.spyOn>;
let createDocument: ReturnType<typeof vi.spyOn>;
let consoleError: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  // Only `Date` is faked, so the route's single backend creation-time value is
  // deterministic without a clock abstraction and without stalling timers.
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(createdAt);

  resendSend.mockReset();
  resendSend.mockResolvedValue({ data: { id: "email-id" }, error: null });
  notifySubscribersForRequest.mockReset();
  notifySubscribersForRequest.mockResolvedValue(undefined);

  countDocuments = vi
    .spyOn(MealRequest, "countDocuments")
    .mockResolvedValue(0 as never);
  createDocument = vi
    .spyOn(MealRequest, "create")
    .mockImplementation(async (input) =>
      persistedDocument(
        input as unknown as Record<string, unknown>
      ) as unknown as Awaited<ReturnType<typeof MealRequest.create>>
    ) as ReturnType<typeof vi.spyOn>;
  consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
});

describe("POST /api/request validation and persistence", () => {
  it("persists a valid canonical ASAP request with trimmed private input", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(createDocument).toHaveBeenCalledWith({
      vendor: "Campus Market",
      food: "Vegetable rice bowl",
      pickupName: "Requester Private Name",
      email: "requester@example.edu",
      pickupWindowText: "ASAP (within the next 5 hours)",
      windowStart: undefined,
      windowEnd: undefined,
      status: "open",
      expiresAt: asapExpiresAt,
      deleteAt: asapExpiresAt,
    });
    expect(context.status).toHaveBeenCalledWith(201);
  });

  it.each([
    {
      windowStart: "2026-07-28T17:00:00.000Z",
    },
    {
      windowEnd: "2026-07-28T18:00:00.000Z",
    },
    {
      windowStart: "2026-07-28T17:00:00.000Z",
      windowEnd: "2026-07-28T18:00:00.000Z",
    },
  ])("rejects canonical ASAP window fields", async (window) => {
    const context = routeContext(canonicalAsap(window));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "INVALID_REQUEST",
        message: "Invalid request payload",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("persists a valid canonical scheduled request and generates New York display text", async () => {
    const context = routeContext(canonicalScheduled());

    await createRequest(context.req, context.res);

    expect(createDocument).toHaveBeenCalledWith(
      expect.objectContaining({
        pickupWindowText: "Jul 28, 1:00 PM – 2:00 PM",
        windowStart: new Date("2026-07-28T17:00:00.000Z"),
        windowEnd: new Date("2026-07-28T18:00:00.000Z"),
      })
    );
    expect(context.status).toHaveBeenCalledWith(201);
  });

  it.each(["vendor", "food", "pickupName", "email"])(
    "rejects a missing or blank required %s",
    async (field) => {
      const context = routeContext(
        canonicalAsap({ [field]: field === "vendor" ? "   " : undefined })
      );

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(400);
      expect(context.json).toHaveBeenCalledWith({
        error: {
          code: "INVALID_REQUEST",
          message: "Invalid request payload",
        },
      });
      expect(createDocument).not.toHaveBeenCalled();
      expect(resendSend).not.toHaveBeenCalled();
      expect(notifySubscribersForRequest).not.toHaveBeenCalled();
    }
  );

  it("rejects an invalid email", async () => {
    const context = routeContext(canonicalAsap({ email: "not-an-email" }));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it.each(["soon", "", 7, null])(
    "rejects invalid canonical timing value %j",
    async (timing) => {
      const context = routeContext(canonicalAsap({ timing }));

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(400);
      expect(createDocument).not.toHaveBeenCalled();
    }
  );

  it.each([
    { windowStart: undefined },
    { windowEnd: undefined },
    { windowStart: undefined, windowEnd: undefined },
  ])("rejects a scheduled request without both window fields", async (window) => {
    const context = routeContext(canonicalScheduled(window));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it.each([
    {
      windowStart: "not-a-timestamp",
      windowEnd: "2026-07-28T18:00:00.000Z",
    },
    {
      windowStart: "2026-07-28T17:00:00.000Z",
      windowEnd: "not-a-timestamp",
    },
  ])("rejects invalid scheduled ISO timestamps", async (window) => {
    const context = routeContext(canonicalScheduled(window));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it.each([
    {
      windowStart: "2026-07-28T18:00:00.000Z",
      windowEnd: "2026-07-28T17:00:00.000Z",
    },
    {
      windowStart: "2026-07-28T17:00:00.000Z",
      windowEnd: "2026-07-28T17:00:00.000Z",
    },
  ])("rejects reversed or equal scheduled windows", async (window) => {
    const context = routeContext(canonicalScheduled(window));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it.each([
    ["id", "client-id"],
    ["_id", "64b000000000000000000002"],
    ["status", "placed"],
    ["createdAt", "2020-01-01T00:00:00.000Z"],
    ["updatedAt", "2020-01-01T00:00:00.000Z"],
    ["expiresAt", "2030-01-01T00:00:00.000Z"],
    ["claimToken", "client-claim"],
    ["orderNumber", "client-order"],
    ["pickupWindowText", "client display text"],
  ])("rejects canonical client-supplied field %s", async (field, value) => {
    const context = routeContext(canonicalAsap({ [field]: value }));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("returns a canonical public wrapper with backend values and no private fields", async () => {
    const context = routeContext(canonicalScheduled());

    await createRequest(context.req, context.res);

    const body = JSON.parse(
      JSON.stringify(context.json.mock.calls[0][0])
    ) as Record<string, Record<string, unknown>>;
    expect(Object.keys(body)).toEqual(["request"]);
    expect(body.request).toEqual({
      id: requestId.toString(),
      vendor: "Campus Market",
      food: "Vegetable rice bowl",
      pickupWindowText: "Jul 28, 1:00 PM – 2:00 PM",
      windowStart: "2026-07-28T17:00:00.000Z",
      windowEnd: "2026-07-28T18:00:00.000Z",
      status: "open",
      createdAt: "2026-07-28T16:00:00.000Z",
      expiresAt: "2026-07-28T18:00:00.000Z",
    });
    expect(body.request).not.toHaveProperty("email");
    expect(body.request).not.toHaveProperty("pickupName");
    expect(body.request).not.toHaveProperty("_id");
    expect(body.request).not.toHaveProperty("claimToken");
    expect(body.request).not.toHaveProperty("orderNumber");
    expect(body.request).not.toHaveProperty("notificationStatus");
    expect(body.request).not.toHaveProperty("deleteAt");
    expect(body.request).not.toHaveProperty("claimedAt");
    expect(body.request).not.toHaveProperty("claimExpiresAt");
    expect(body.request).not.toHaveProperty("claimExtendedAt");
    expect(body.request).not.toHaveProperty("claimTokenDigest");

    const persistedInput = createDocument.mock.calls[0][0] as Record<
      string,
      unknown
    >;
    expect(persistedInput).not.toHaveProperty("_id");
    expect(persistedInput.status).toBe("open");
    expect(persistedInput).not.toHaveProperty("createdAt");
    // `expiresAt` is written by the backend, unlike the fields above, which
    // stay owned by Mongo/Mongoose.
    expect(persistedInput.expiresAt).toEqual(
      new Date("2026-07-28T18:00:00.000Z")
    );
    expect(persistedInput.deleteAt).toEqual(persistedInput.expiresAt);
  });
});

describe("POST /api/request backend-owned expiration", () => {
  it("expires an ASAP request five hours after the backend creation time", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    const persistedInput = createDocument.mock.calls[0][0] as Record<
      string,
      unknown
    >;
    const persistedExpiration = persistedInput.expiresAt as Date;

    expect(persistedExpiration).toEqual(asapExpiresAt);
    expect(
      persistedExpiration.getTime() - createdAt.getTime()
    ).toBe(5 * 60 * 60 * 1000);
    expect(context.status).toHaveBeenCalledWith(201);
  });

  it("expires a scheduled request exactly at the validated windowEnd", async () => {
    const context = routeContext(canonicalScheduled());

    await createRequest(context.req, context.res);

    const persistedInput = createDocument.mock.calls[0][0] as Record<
      string,
      unknown
    >;

    expect(persistedInput.expiresAt).toEqual(
      new Date("2026-07-28T18:00:00.000Z")
    );
    expect(persistedInput.expiresAt).toEqual(persistedInput.windowEnd);
  });

  it("never leaves a created request on the schema's 24-hour fallback", async () => {
    const dayAfterCreation = new Date(
      createdAt.getTime() + 24 * 60 * 60 * 1000
    );

    for (const body of [canonicalAsap(), canonicalScheduled()]) {
      const context = routeContext(body);
      await createRequest(context.req, context.res);
    }

    for (const call of createDocument.mock.calls) {
      const persistedInput = call[0] as Record<string, unknown>;
      expect(persistedInput.expiresAt).toBeInstanceOf(Date);
      expect(
        (persistedInput.expiresAt as Date).getTime()
      ).toBeLessThan(dayAfterCreation.getTime());
    }
  });

  it("ignores a client-supplied expiration on both create shapes", async () => {
    const clientExpiration = "2030-01-01T00:00:00.000Z";

    const canonical = routeContext(
      canonicalAsap({ expiresAt: clientExpiration })
    );
    await createRequest(canonical.req, canonical.res);

    const legacy = routeContext({
      vendor: "Campus Market",
      food: "Vegetable rice bowl",
      pickupName: "Requester Private Name",
      email: "requester@example.edu",
      pickupWindowText: "Legacy display",
      expiresAt: clientExpiration,
    });
    await createRequest(legacy.req, legacy.res);

    expect(canonical.status).toHaveBeenCalledWith(400);
    expect(legacy.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("returns the canonical expiration in the successful public response", async () => {
    const asap = routeContext(canonicalAsap());
    await createRequest(asap.req, asap.res);

    const scheduled = routeContext(canonicalScheduled());
    await createRequest(scheduled.req, scheduled.res);

    const asapBody = JSON.parse(
      JSON.stringify(asap.json.mock.calls[0][0])
    ) as Record<string, Record<string, unknown>>;
    const scheduledBody = JSON.parse(
      JSON.stringify(scheduled.json.mock.calls[0][0])
    ) as Record<string, Record<string, unknown>>;

    expect(asapBody.request.expiresAt).toBe("2026-07-28T21:00:00.000Z");
    expect(scheduledBody.request.expiresAt).toBe("2026-07-28T18:00:00.000Z");
    expect(scheduledBody.request.expiresAt).toBe(
      scheduledBody.request.windowEnd
    );
  });

  it("rejects a scheduled window that has already ended", async () => {
    const context = routeContext(
      canonicalScheduled({
        windowStart: "2026-07-28T14:00:00.000Z",
        windowEnd: "2026-07-28T15:00:00.000Z",
      })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "INVALID_REQUEST",
        message: "Invalid request payload",
      },
    });
    expect(countDocuments).not.toHaveBeenCalled();
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("rejects a scheduled window ending exactly at the backend now", async () => {
    const context = routeContext(
      canonicalScheduled({
        windowStart: "2026-07-28T15:00:00.000Z",
        windowEnd: "2026-07-28T16:00:00.000Z",
      })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("accepts a window that has already started but has not ended", async () => {
    const context = routeContext(
      canonicalScheduled({
        windowStart: "2026-07-28T15:59:00.000Z",
        windowEnd: "2026-07-28T16:30:00.000Z",
      })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    const persistedInput = createDocument.mock.calls[0][0] as Record<
      string,
      unknown
    >;
    expect(persistedInput.expiresAt).toEqual(
      new Date("2026-07-28T16:30:00.000Z")
    );
  });

  it("accepts a fully future window and expires it at windowEnd", async () => {
    const context = routeContext(canonicalScheduled());

    await createRequest(context.req, context.res);

    const persistedInput = createDocument.mock.calls[0][0] as Record<
      string,
      unknown
    >;
    const body = JSON.parse(
      JSON.stringify(context.json.mock.calls[0][0])
    ) as Record<string, Record<string, unknown>>;

    expect(context.status).toHaveBeenCalledWith(201);
    expect(persistedInput.expiresAt).toEqual(
      new Date("2026-07-28T18:00:00.000Z")
    );
    expect(body.request.expiresAt).toBe("2026-07-28T18:00:00.000Z");
  });

  it("applies the same window rule to the legacy compatibility path", async () => {
    function legacy(windowStart: string, windowEnd: string) {
      return {
        vendor: "Campus Market",
        food: "Vegetable rice bowl",
        pickupName: "Requester Private Name",
        email: "requester@example.edu",
        pickupWindowText: "Legacy display",
        windowStart,
        windowEnd,
      };
    }

    const ended = routeContext(
      legacy("2026-07-28T14:00:00.000Z", "2026-07-28T15:00:00.000Z")
    );
    await createRequest(ended.req, ended.res);

    const endingNow = routeContext(
      legacy("2026-07-28T15:00:00.000Z", "2026-07-28T16:00:00.000Z")
    );
    await createRequest(endingNow.req, endingNow.res);

    expect(ended.status).toHaveBeenCalledWith(400);
    expect(endingNow.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();

    const stillOpen = routeContext(
      legacy("2026-07-28T15:59:00.000Z", "2026-07-28T16:30:00.000Z")
    );
    await createRequest(stillOpen.req, stillOpen.res);

    expect(stillOpen.status).toHaveBeenCalledWith(201);
    const persistedInput = createDocument.mock.calls[0][0] as Record<
      string,
      unknown
    >;
    expect(persistedInput.expiresAt).toEqual(
      new Date("2026-07-28T16:30:00.000Z")
    );
  });

  it("creates nothing and expires nothing for an invalid request", async () => {
    const context = routeContext(canonicalScheduled({ windowEnd: undefined }));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(countDocuments).not.toHaveBeenCalled();
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });
});

describe("POST /api/request narrow legacy web compatibility", () => {
  it("infers ASAP only when both window fields are absent and ignores legacy display text", async () => {
    const context = routeContext({
      vendor: "Campus Market",
      food: "Vegetable rice bowl",
      pickupName: "Requester Private Name",
      email: "requester@example.edu",
      pickupWindowText: "Client-owned text must be ignored",
    });

    await createRequest(context.req, context.res);

    expect(createDocument).toHaveBeenCalledWith(
      expect.objectContaining({
        pickupWindowText: "ASAP (within the next 5 hours)",
        windowStart: undefined,
        windowEnd: undefined,
      })
    );
    expect(context.status).toHaveBeenCalledWith(201);
  });

  it("infers scheduled only from two valid legacy timestamps and generates canonical text", async () => {
    const context = routeContext({
      vendor: "Campus Market",
      food: "Vegetable rice bowl",
      pickupName: "Requester Private Name",
      email: "requester@example.edu",
      pickupWindowText: "Wrong client display text",
      windowStart: "2026-07-28T17:00:00.000Z",
      windowEnd: "2026-07-28T18:00:00.000Z",
    });

    await createRequest(context.req, context.res);

    expect(createDocument).toHaveBeenCalledWith(
      expect.objectContaining({
        pickupWindowText: "Jul 28, 1:00 PM – 2:00 PM",
        windowStart: new Date("2026-07-28T17:00:00.000Z"),
        windowEnd: new Date("2026-07-28T18:00:00.000Z"),
      })
    );
  });

  it.each([
    {
      windowStart: "2026-07-28T17:00:00.000Z",
      windowEnd: undefined,
    },
    {
      windowStart: undefined,
      windowEnd: "2026-07-28T18:00:00.000Z",
    },
    {
      windowStart: "invalid",
      windowEnd: "2026-07-28T18:00:00.000Z",
    },
    {
      windowStart: "2026-07-28T18:00:00.000Z",
      windowEnd: "2026-07-28T17:00:00.000Z",
    },
  ])("rejects an invalid legacy window pair", async (window) => {
    const context = routeContext({
      vendor: "Campus Market",
      food: "Vegetable rice bowl",
      pickupName: "Requester Private Name",
      email: "requester@example.edu",
      pickupWindowText: "Legacy display",
      ...window,
    });

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("requires pickupWindowText when timing is absent and rejects extra fields", async () => {
    const missingCompatibilityMarker = routeContext({
      vendor: "Campus Market",
      food: "Vegetable rice bowl",
      pickupName: "Requester Private Name",
      email: "requester@example.edu",
    });
    await createRequest(
      missingCompatibilityMarker.req,
      missingCompatibilityMarker.res
    );

    const broadenedLegacyPayload = routeContext({
      vendor: "Campus Market",
      food: "Vegetable rice bowl",
      pickupName: "Requester Private Name",
      email: "requester@example.edu",
      pickupWindowText: "Legacy display",
      status: "requested",
    });
    await createRequest(broadenedLegacyPayload.req, broadenedLegacyPayload.res);

    expect(missingCompatibilityMarker.status).toHaveBeenCalledWith(400);
    expect(broadenedLegacyPayload.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });
});

describe("POST /api/request side-effect ordering and errors", () => {
  it("persists and shapes before requester email and helper notification", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(createDocument.mock.invocationCallOrder[0]).toBeLessThan(
      resendSend.mock.invocationCallOrder[0]
    );
    expect(resendSend.mock.invocationCallOrder[0]).toBeLessThan(
      notifySubscribersForRequest.mock.invocationCallOrder[0]
    );
    expect(context.status).toHaveBeenCalledWith(201);
  });

  it("describes later requester email as an attempt in both email bodies", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    const submission = resendSend.mock.calls[0][0] as {
      html: string;
      text: string;
    };
    for (const body of [submission.html, submission.text]) {
      expect(body).toContain("will attempt to email you the order details");
      expect(body).toContain(
        "Request creation does not guarantee that later email will be delivered"
      );
      expect(body).not.toContain("We'll notify you");
    }
  });

  it("keeps the persisted success when Resend returns { data, error } failure", async () => {
    resendSend.mockResolvedValue({
      data: null,
      error: { name: "validation_error", message: "recipient rejected" },
    });
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(createDocument).toHaveBeenCalledOnce();
    expect(notifySubscribersForRequest).toHaveBeenCalledOnce();
    expect(context.status).toHaveBeenCalledWith(201);
    expect(context.json).toHaveBeenCalledWith(
      expect.objectContaining({ request: expect.any(Object) })
    );
    expect(consoleError).toHaveBeenCalledWith(
      `[email] Request confirmation failed after persistence for request ${requestId}`
    );
    expect(JSON.stringify(consoleError.mock.calls)).not.toContain(
      "requester@example.edu"
    );
    expect(JSON.stringify(consoleError.mock.calls)).not.toContain(
      "Requester Private Name"
    );
  });

  it("keeps the persisted success when requester email throws", async () => {
    resendSend.mockRejectedValue(new Error("network failure"));
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(createDocument).toHaveBeenCalledOnce();
    expect(notifySubscribersForRequest).toHaveBeenCalledOnce();
    expect(context.status).toHaveBeenCalledWith(201);
  });

  it("keeps the persisted success when helper notification throws", async () => {
    notifySubscribersForRequest.mockRejectedValue(
      new Error("subscriber delivery failed")
    );
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(createDocument).toHaveBeenCalledOnce();
    expect(context.status).toHaveBeenCalledWith(201);
    expect(consoleError).toHaveBeenCalledWith(
      `[route] Helper notification failed after persistence for request ${requestId}`
    );
  });

  it("returns REQUEST_CREATION_FAILED only when persistence fails", async () => {
    createDocument.mockRejectedValue(new Error("database unavailable"));
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(500);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "REQUEST_CREATION_FAILED",
        message: "Unable to create request",
      },
    });
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("returns REQUEST_LIMIT_REACHED when a valid request exceeds the daily limit", async () => {
    countDocuments.mockResolvedValue(3);
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(429);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "REQUEST_LIMIT_REACHED",
        message: "You have reached the daily limit of 3 meal requests",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("creates no record and triggers no side effect for an invalid request", async () => {
    const context = routeContext(canonicalScheduled({ windowEnd: undefined }));

    await createRequest(context.req, context.res);

    expect(countDocuments).not.toHaveBeenCalled();
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });
});

describe("ASAP window text states the real five-hour lifetime", () => {
  /**
   * `ASAP_LIFETIME_MS` is five hours, and the iOS requester is told "It will
   * expire in 5 hours". The window text is what *helpers* read, on every
   * surface that renders a request, so a stale "within the next hour" made the
   * two sides of the same request disagree: a request posted at 1pm still
   * advertised the next hour at 5pm.
   */
  const PRODUCTION_SOURCES = [
    "src",
    "public",
    "ios/CommonPlateios/CommonPlateios",
  ];

  function productionFiles(directory: string): string[] {
    const root = new URL(`../${directory}/`, import.meta.url);
    return readdirSync(root, { recursive: true, encoding: "utf8" })
      .filter((entry) => /\.(ts|js|html|swift)$/.test(entry))
      // Tests and sourcemaps are not surfaces anyone reads a request on.
      .filter((entry) => !entry.includes(".test."))
      .map((entry) => `${directory}/${entry}`);
  }

  it("leaves no production occurrence of the one-hour phrasing", () => {
    const offenders = PRODUCTION_SOURCES.flatMap(productionFiles).filter(
      (file) =>
        readFileSync(new URL(`../${file}`, import.meta.url), "utf8").includes(
          "within the next hour"
        )
    );

    expect(offenders).toEqual([]);
  });

  it("keeps the five-hour expiration itself unchanged", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    const persisted = createDocument.mock.calls[0][0] as Record<string, unknown>;
    expect(persisted.pickupWindowText).toBe("ASAP (within the next 5 hours)");
    // The copy fix must not have moved the deadline it describes.
    expect(persisted.expiresAt).toEqual(asapExpiresAt);
    expect(persisted.deleteAt).toEqual(asapExpiresAt);
    expect(
      (asapExpiresAt.getTime() - createdAt.getTime()) / (60 * 60 * 1000)
    ).toBe(5);
  });
});

describe("POST /api/request rate limiting is a definitive pre-write refusal", () => {
  /**
   * Exercised over real HTTP because the limiter is middleware, not part of the
   * handler. What matters is the *shape* of the sixth response: iOS classifies
   * an undecodable failure on this non-idempotent POST as ambiguous, which
   * locks request creation for the rest of the process. A throttled attempt
   * never reaches validation or the write, so it must decode as a definitive
   * `RATE_LIMITED` envelope instead.
   */
  it("allows five creations, then refuses the sixth with the envelope and no write", async () => {
    vi.useRealTimers();

    const testApp = express();
    testApp.use(express.json());
    testApp.post("/api/request", createRequestRateLimiter, createRequest);
    const server = createServer(testApp);
    await new Promise<void>((resolve) =>
      server.listen(0, "127.0.0.1", resolve)
    );

    try {
      const { port } = server.address() as AddressInfo;
      const post = () =>
        fetch(`http://127.0.0.1:${port}/api/request`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(canonicalAsap()),
        });

      for (let attempt = 1; attempt <= 5; attempt += 1) {
        const allowed = await post();
        expect(allowed.status).toBe(201);
      }
      expect(createDocument).toHaveBeenCalledTimes(5);

      const refused = await post();

      expect(refused.status).toBe(429);
      await expect(refused.json()).resolves.toEqual({
        error: {
          code: "RATE_LIMITED",
          message: "Too many attempts. Please wait a moment and try again.",
          fields: null,
        },
      });
      // The refusal happened ahead of the handler entirely: no daily-limit
      // read, no document, no requester email, no subscriber notification.
      expect(createDocument).toHaveBeenCalledTimes(5);
      expect(countDocuments).toHaveBeenCalledTimes(5);
      expect(resendSend).toHaveBeenCalledTimes(5);
      expect(notifySubscribersForRequest).toHaveBeenCalledTimes(5);
    } finally {
      await new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve()))
      );
    }
  });
});
