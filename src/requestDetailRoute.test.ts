import type { NextFunction, Request, Response } from "express";
import mongoose from "mongoose";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Request as MealRequest } from "../models/db.js";
import { getPublicRequestDetail } from "./requestDetailRoute.js";

function requestDocument(overrides: Record<string, unknown> = {}) {
  return {
    _id: new mongoose.Types.ObjectId("64b000000000000000000001"),
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName: "Requester Private Name",
    pickupWindowText: "1:00 PM – 2:00 PM",
    email: "requester@example.edu",
    requesterPhone: "555-0100",
    requesterPhoneNumber: "555-0101",
    phone: "555-0102",
    windowStart: new Date("2026-07-26T20:00:00.000Z"),
    windowEnd: new Date("2026-07-26T21:00:00.000Z"),
    status: "open",
    createdAt: new Date("2026-07-26T18:00:00.000Z"),
    expiresAt: new Date("2026-07-26T22:00:00.000Z"),
    claimToken: "raw-token",
    claimTokenHash: "hashed-token",
    claimTokenDigest: "digested-token",
    claimExpiresAt: new Date("2026-07-26T19:15:00.000Z"),
    claimedAt: new Date("2026-07-26T19:00:00.000Z"),
    claimExtendedAt: null,
    deleteAt: new Date("2026-07-26T22:00:00.000Z"),
    orderNumber: "private-order-number",
    eta: new Date("2026-07-26T20:30:00.000Z"),
    etaText: "30 minutes",
    placedAt: new Date("2026-07-26T20:15:00.000Z"),
    fulfillerEmail: "helper@example.edu",
    contactMessage: "private message",
    note: "private note",
    notificationStatus: "pending_retry",
    notificationAttemptedAt: new Date("2026-07-26T20:16:00.000Z"),
    __v: 0,
    ...overrides,
  };
}

function mockFindById(result: unknown): void {
  vi.spyOn(MealRequest, "findById").mockReturnValue({
    lean: () => ({
      exec: vi.fn().mockResolvedValue(result),
    }),
  } as ReturnType<typeof MealRequest.findById>);
}

function routeContext(id = "64b000000000000000000001") {
  const req = { params: { id } } as unknown as Request;
  const json = vi.fn();
  const status = vi.fn().mockReturnValue({ json });
  const res = { json, status } as unknown as Response;
  const next = vi.fn() as unknown as NextFunction;

  return { req, res, next, json, status };
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("GET /api/request/:id", () => {
  it("returns the canonical public detail wrapper without private fields", async () => {
    mockFindById(requestDocument());
    const context = routeContext();

    await getPublicRequestDetail(context.req, context.res, context.next);

    expect(context.json).toHaveBeenCalledWith({
      request: {
        id: "64b000000000000000000001",
        vendor: "Campus Market",
        food: "Vegetable rice bowl",
        pickupWindowText: "1:00 PM – 2:00 PM",
        windowStart: new Date("2026-07-26T20:00:00.000Z"),
        windowEnd: new Date("2026-07-26T21:00:00.000Z"),
        status: "open",
        createdAt: new Date("2026-07-26T18:00:00.000Z"),
        expiresAt: new Date("2026-07-26T22:00:00.000Z"),
      },
    });

    const serializedResponse = JSON.parse(
      JSON.stringify(context.json.mock.calls[0][0])
    ) as { request: Record<string, unknown> };
    expect(Object.keys(serializedResponse)).toEqual(["request"]);
    expect(Object.keys(serializedResponse.request)).toEqual([
      "id",
      "vendor",
      "food",
      "pickupWindowText",
      "windowStart",
      "windowEnd",
      "status",
      "createdAt",
      "expiresAt",
    ]);
    expect(serializedResponse.request).not.toHaveProperty("email");
    expect(serializedResponse.request).not.toHaveProperty("requesterPhone");
    expect(serializedResponse.request).not.toHaveProperty(
      "requesterPhoneNumber"
    );
    expect(serializedResponse.request).not.toHaveProperty("phone");
    expect(serializedResponse.request).not.toHaveProperty("pickupName");
    expect(serializedResponse.request).not.toHaveProperty("claimToken");
    expect(serializedResponse.request).not.toHaveProperty("claimTokenHash");
    expect(serializedResponse.request).not.toHaveProperty("claimTokenDigest");
    expect(serializedResponse.request).not.toHaveProperty("claimExpiresAt");
    expect(serializedResponse.request).not.toHaveProperty("claimedAt");
    expect(serializedResponse.request).not.toHaveProperty("claimExtendedAt");
    expect(serializedResponse.request).not.toHaveProperty("deleteAt");
    expect(serializedResponse.request).not.toHaveProperty("orderNumber");
    expect(serializedResponse.request).not.toHaveProperty("eta");
    expect(serializedResponse.request).not.toHaveProperty("etaText");
    expect(serializedResponse.request).not.toHaveProperty("placedAt");
    expect(serializedResponse.request).not.toHaveProperty("fulfillerEmail");
    expect(serializedResponse.request).not.toHaveProperty("contactMessage");
    expect(serializedResponse.request).not.toHaveProperty("note");
    expect(serializedResponse.request).not.toHaveProperty(
      "notificationStatus"
    );
    expect(serializedResponse.request).not.toHaveProperty(
      "notificationAttemptedAt"
    );
    expect(serializedResponse.request).not.toHaveProperty("_id");
    expect(serializedResponse.request).not.toHaveProperty("__v");
    expect(context.next).not.toHaveBeenCalled();
  });

  it("preserves the existing not-found response", async () => {
    mockFindById(null);
    const context = routeContext();

    await getPublicRequestDetail(context.req, context.res, context.next);

    expect(context.status).toHaveBeenCalledWith(404);
    expect(
      (context.status.mock.results[0].value as { json: typeof context.json })
        .json
    ).toHaveBeenCalledWith({ error: "Request not found" });
    expect(context.next).not.toHaveBeenCalled();
  });

  it("does not apply list-only status or expiration filtering", async () => {
    mockFindById(
      requestDocument({
        status: "placed",
        expiresAt: new Date("2020-01-01T00:00:00.000Z"),
      })
    );
    const context = routeContext();

    await getPublicRequestDetail(context.req, context.res, context.next);

    expect(context.json).toHaveBeenCalledWith(
      expect.objectContaining({
        request: expect.objectContaining({
          status: "placed",
          expiresAt: new Date("2020-01-01T00:00:00.000Z"),
        }),
      })
    );
    expect(context.status).not.toHaveBeenCalled();
  });

  it("preserves the existing invalid-id response", async () => {
    const context = routeContext("not-an-object-id");

    await getPublicRequestDetail(context.req, context.res, context.next);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(
      (context.status.mock.results[0].value as { json: typeof context.json })
        .json
    ).toHaveBeenCalledWith({ error: "Invalid request id" });
    expect(context.next).not.toHaveBeenCalled();
  });

  it("preserves error delegation to the repository error handler", async () => {
    const databaseError = new Error("database unavailable");
    vi.spyOn(MealRequest, "findById").mockReturnValue({
      lean: () => ({
        exec: vi.fn().mockRejectedValue(databaseError),
      }),
    } as ReturnType<typeof MealRequest.findById>);
    const context = routeContext();

    await getPublicRequestDetail(context.req, context.res, context.next);

    expect(context.next).toHaveBeenCalledWith(databaseError);
    expect(context.status).not.toHaveBeenCalled();
    expect(context.json).not.toHaveBeenCalled();
  });
});
