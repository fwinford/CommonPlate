import type { Request, Response } from "express";
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
import { createRequest } from "./createRequestRoute.js";

const requestId = new mongoose.Types.ObjectId("64b000000000000000000001");
const createdAt = new Date("2026-07-28T16:00:00.000Z");
const expiresAt = new Date("2026-07-29T16:00:00.000Z");

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
    status: "requested",
    createdAt,
    updatedAt: createdAt,
    expiresAt,
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
      persistedDocument(input as unknown as Record<string, unknown>)
    ) as ReturnType<typeof vi.spyOn>;
  consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
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
      pickupWindowText: "ASAP (within the next hour)",
      windowStart: undefined,
      windowEnd: undefined,
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
      status: "requested",
      createdAt: "2026-07-28T16:00:00.000Z",
      expiresAt: "2026-07-29T16:00:00.000Z",
    });
    expect(body.request).not.toHaveProperty("email");
    expect(body.request).not.toHaveProperty("pickupName");
    expect(body.request).not.toHaveProperty("_id");
    expect(body.request).not.toHaveProperty("claimToken");
    expect(body.request).not.toHaveProperty("orderNumber");
    expect(body.request).not.toHaveProperty("notificationStatus");

    const persistedInput = createDocument.mock.calls[0][0] as Record<
      string,
      unknown
    >;
    expect(persistedInput).not.toHaveProperty("_id");
    expect(persistedInput).not.toHaveProperty("status");
    expect(persistedInput).not.toHaveProperty("createdAt");
    expect(persistedInput).not.toHaveProperty("expiresAt");
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
        pickupWindowText: "ASAP (within the next hour)",
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
