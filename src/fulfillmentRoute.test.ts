import type { Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { generateClaimToken } from "./claimToken.js";
import { Fulfillment, Request as MealRequest } from "../models/db.js";

const sendFulfillmentEmail = vi.hoisted(() => vi.fn());
vi.mock("./emailHelpers.js", () => ({ sendFulfillmentEmail }));

import { fulfillRequest } from "./fulfillmentRoute.js";

const requestId = "64b000000000000000000001";

function validBody() {
  return {
    claimToken: generateClaimToken(),
    fulfillment: {
      fulfillerEmail: "helper@example.edu",
      orderNumber: "70154321",
      eta: "15 minutes",
      contactMessage: "Your meal is ready",
    },
  };
}

function routeContext(body: unknown, id = requestId) {
  const req = { params: { id }, body } as unknown as Request;
  const res = {} as Response;
  const status = vi.fn().mockReturnValue(res);
  const json = vi.fn().mockReturnValue(res);
  res.status = status;
  res.json = json;
  return { req, res, status, json };
}

function responseBody(context: ReturnType<typeof routeContext>) {
  return context.json.mock.calls[0][0] as Record<string, any>;
}

beforeEach(() => {
  vi.stubEnv(
    "CLAIM_TOKEN_HMAC_SECRET",
    "unit-test-claim-hmac-secret-material"
  );
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
  sendFulfillmentEmail.mockReset();
});

describe("POST /api/request/:id/fulfill validation", () => {
  it("rejects an invalid request id before starting a transaction", async () => {
    const startSession = vi.spyOn(mongoose, "startSession");
    const context = routeContext(validBody(), "not-an-object-id");

    await fulfillRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe("INVALID_REQUEST_ID");
    expect(startSession).not.toHaveBeenCalled();
  });

  it.each([
    undefined,
    {},
    { fulfillment: validBody().fulfillment },
    { claimToken: "not-a-canonical-token", fulfillment: validBody().fulfillment },
  ])("rejects a missing or malformed claim token", async (body) => {
    const startSession = vi.spyOn(mongoose, "startSession");
    const context = routeContext(body);

    await fulfillRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe("INVALID_CLAIM_TOKEN");
    expect(startSession).not.toHaveBeenCalled();
  });

  it.each([
    {
      name: "flat legacy payload",
      mutate: () => ({
        claimToken: generateClaimToken(),
        fulfillerEmail: "helper@example.edu",
        orderNumber: "70154321",
        eta: "15 minutes",
      }),
    },
    {
      name: "invalid helper email",
      mutate: () => ({
        ...validBody(),
        fulfillment: { ...validBody().fulfillment, fulfillerEmail: "invalid" },
      }),
    },
    {
      name: "unsafe order number",
      mutate: () => ({
        ...validBody(),
        fulfillment: { ...validBody().fulfillment, orderNumber: "7015 4321" },
      }),
    },
    {
      name: "blank ETA",
      mutate: () => ({
        ...validBody(),
        fulfillment: { ...validBody().fulfillment, eta: "   " },
      }),
    },
    {
      name: "removed note field",
      mutate: () => ({
        ...validBody(),
        fulfillment: { ...validBody().fulfillment, note: "legacy note" },
      }),
    },
    {
      name: "helper phone field",
      mutate: () => ({
        ...validBody(),
        fulfillment: { ...validBody().fulfillment, helperPhone: "555-0100" },
      }),
    },
    {
      name: "client-owned placement timestamp",
      mutate: () => ({
        ...validBody(),
        fulfillment: {
          ...validBody().fulfillment,
          placedAt: "2020-01-01T00:00:00.000Z",
        },
      }),
    },
    {
      name: "unexpected top-level field",
      mutate: () => ({ ...validBody(), unexpected: true }),
    },
  ])("rejects $name", async ({ mutate }) => {
    const startSession = vi.spyOn(mongoose, "startSession");
    const context = routeContext(mutate());

    await fulfillRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe(
      "INVALID_FULFILLMENT_PAYLOAD"
    );
    expect(startSession).not.toHaveBeenCalled();
  });

  // A CommonPlate Grubhub order number contains digits only. Every rejection
  // below stops before a session is opened, so nothing about an already-paid
  // real-world order is put at risk by a malformed value.
  it.each([
    ["one letter", "7015432A"],
    ["leading letter", "A70154321"],
    ["all letters", "ORDERNUMBER"],
    ["interior space", "7015 4321"],
    ["surrounding spaces only", "   "],
    ["dash", "7015-4321"],
    ["underscore", "7015_4321"],
    ["decimal point", "7015.4321"],
    ["plus sign", "+70154321"],
    ["minus sign", "-70154321"],
    ["punctuation", "70154321!"],
    ["51 digits", "7".repeat(51)],
    ["empty", ""],
  ])("rejects a %s order number", async (_name, orderNumber) => {
    const startSession = vi.spyOn(mongoose, "startSession");
    const context = routeContext({
      ...validBody(),
      fulfillment: { ...validBody().fulfillment, orderNumber },
    });

    await fulfillRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe(
      "INVALID_FULFILLMENT_PAYLOAD"
    );
    // The envelope shape is unchanged by the tightened rule.
    expect(responseBody(context).error.fields).toBeNull();
    expect(startSession).not.toHaveBeenCalled();
    expect(sendFulfillmentEmail).not.toHaveBeenCalled();
  });

  // Accepted values are asserted through the schema rather than the route so no
  // transaction is required: reaching `startSession` is itself the proof that
  // validation let the value through.
  it.each([
    ["a single digit", "7"],
    ["an ordinary order number", "70154321"],
    ["a leading zero", "070154321"],
    ["several leading zeroes", "00070154321"],
    ["all zeroes", "0000000000"],
    ["50 digits", "7".repeat(50)],
    ["surrounding whitespace that trims away", "  70154321  "],
  ])("accepts %s", async (_name, orderNumber) => {
    const startSession = vi
      .spyOn(mongoose, "startSession")
      .mockRejectedValue(new Error("stop after validation"));
    const context = routeContext({
      ...validBody(),
      fulfillment: { ...validBody().fulfillment, orderNumber },
    });

    await fulfillRequest(context.req, context.res);

    expect(startSession).toHaveBeenCalledOnce();
    expect(responseBody(context).error?.code).not.toBe(
      "INVALID_FULFILLMENT_PAYLOAD"
    );
  });

  it("keeps the payload shape unchanged and the order number a string", async () => {
    const body = validBody();
    expect(Object.keys(body).sort()).toEqual(["claimToken", "fulfillment"]);
    expect(Object.keys(body.fulfillment).sort()).toEqual([
      "contactMessage",
      "eta",
      "fulfillerEmail",
      "orderNumber",
    ]);
    expect(typeof body.fulfillment.orderNumber).toBe("string");

    // A JSON number is refused outright: the field is a string field, and
    // accepting a number would silently drop a leading zero and reshape a long
    // value the moment it round-tripped.
    const startSession = vi.spyOn(mongoose, "startSession");
    const context = routeContext({
      ...body,
      fulfillment: { ...body.fulfillment, orderNumber: 70154321 },
    });

    await fulfillRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(responseBody(context).error.code).toBe(
      "INVALID_FULFILLMENT_PAYLOAD"
    );
    expect(startSession).not.toHaveBeenCalled();
  });

  it("reports a standalone MongoDB deployment without downgrading writes", async () => {
    const unavailable = Object.assign(
      new Error(
        "Transaction numbers are only allowed on a replica set member or mongos"
      ),
      { code: 20 }
    );
    const session = {
      withTransaction: vi.fn().mockRejectedValue(unavailable),
      endSession: vi.fn().mockResolvedValue(undefined),
    };
    vi.spyOn(mongoose, "startSession").mockResolvedValue(session as any);
    const context = routeContext(validBody());

    await fulfillRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(503);
    expect(responseBody(context).error.code).toBe(
      "TRANSACTIONS_UNAVAILABLE"
    );
    expect(session.endSession).toHaveBeenCalledOnce();
    expect(sendFulfillmentEmail).not.toHaveBeenCalled();
  });

  it("answers in the structured envelope when no session can be opened", async () => {
    // The session is created inside the handler's try, so this failure must not
    // escape as a rejected promise into the generic error handler, and the
    // `finally` must not call endSession on a session that was never created.
    vi.spyOn(mongoose, "startSession").mockRejectedValue(
      new Error("no primary available")
    );
    const context = routeContext(validBody());

    await expect(
      fulfillRequest(context.req, context.res)
    ).resolves.toBeDefined();

    expect(context.status).toHaveBeenCalledWith(500);
    expect(responseBody(context)).toEqual({
      error: {
        code: "INTERNAL_FAILURE",
        message: "Unable to record this placement right now.",
        fields: null,
      },
    });
    expect(sendFulfillmentEmail).not.toHaveBeenCalled();
  });

  it("answers in the structured envelope when the HMAC secret is unusable", async () => {
    vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", "too-short");
    const startSession = vi.spyOn(mongoose, "startSession");
    const context = routeContext(validBody());

    await expect(
      fulfillRequest(context.req, context.res)
    ).resolves.toBeDefined();

    expect(context.status).toHaveBeenCalledWith(500);
    expect(responseBody(context).error.code).toBe("INTERNAL_FAILURE");
    expect(startSession).not.toHaveBeenCalled();
    expect(sendFulfillmentEmail).not.toHaveBeenCalled();
  });

  it("continues the committed placement response path when session cleanup fails", async () => {
    const placedRequest = {
      _id: new mongoose.Types.ObjectId(requestId),
      vendor: "Campus Market",
      food: "Vegetable rice bowl",
      pickupWindowText: "ASAP",
      status: "placed",
      createdAt: new Date("2026-08-02T12:00:00.000Z"),
      expiresAt: new Date("2026-08-02T17:00:00.000Z"),
    };
    const update = vi.fn().mockReturnValue({ exec: vi.fn().mockResolvedValue({}) });
    const placement = vi.fn().mockReturnValue({
      exec: vi.fn().mockResolvedValue(placedRequest),
    });
    const ledger = vi.spyOn(Fulfillment, "create").mockResolvedValue([] as never);
    vi.spyOn(MealRequest, "findOneAndUpdate").mockImplementation(placement as never);
    vi.spyOn(MealRequest, "updateOne").mockImplementation(update as never);
    const session = {
      withTransaction: vi.fn().mockImplementation(async (operation) => operation()),
      endSession: vi.fn().mockRejectedValue(new Error("cleanup unavailable")),
    };
    vi.spyOn(mongoose, "startSession").mockResolvedValue(session as any);
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    const context = routeContext(validBody());

    await fulfillRequest(context.req, context.res);

    expect(session.withTransaction).toHaveBeenCalledOnce();
    expect(session.endSession).toHaveBeenCalledOnce();
    expect(placement).toHaveBeenCalledOnce();
    expect(ledger).toHaveBeenCalledOnce();
    expect(context.status).not.toHaveBeenCalled();
    expect(responseBody(context)).toEqual({
      request: expect.objectContaining({ id: requestId, status: "placed" }),
      notification: { status: "sent" },
    });
    expect(consoleError).toHaveBeenCalledWith(
      "[fulfillment] MongoDB session cleanup failed after placement attempt"
    );
    expect(JSON.stringify(consoleError.mock.calls)).not.toContain("helper@example.edu");
    expect(JSON.stringify(consoleError.mock.calls)).not.toContain("70154321");
  });
});
