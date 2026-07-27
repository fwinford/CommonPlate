import { describe, expect, it } from "vitest";
import { buildPublicRequestListResponse } from "./requestListResponse.js";

const serverNow = new Date("2026-07-26T19:00:00.000Z");

function requestDocument(overrides: Record<string, unknown> = {}) {
  return {
    _id: "request-1",
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName: "Requester Name",
    pickupWindowText: "1:00 PM – 2:00 PM",
    email: "requester@example.edu",
    requesterPhone: "555-0100",
    requesterPhoneNumber: "555-0101",
    phone: "555-0102",
    windowStart: new Date("2026-07-26T20:00:00.000Z"),
    windowEnd: new Date("2026-07-26T21:00:00.000Z"),
    status: "requested",
    createdAt: new Date("2026-07-26T18:00:00.000Z"),
    expiresAt: new Date("2026-07-26T22:00:00.000Z"),
    claimToken: "raw-token",
    claimTokenHash: "hashed-token",
    claimTokenDigest: "digested-token",
    claimExpiresAt: new Date("2026-07-26T19:15:00.000Z"),
    orderNumber: "private-order-number",
    eta: new Date("2026-07-26T20:30:00.000Z"),
    etaText: "30 minutes",
    fulfillerEmail: "helper@example.edu",
    contactMessage: "private message",
    note: "private note",
    notificationStatus: "pending_retry",
    __v: 0,
    ...overrides,
  };
}

describe("buildPublicRequestListResponse", () => {
  it("includes an available, unexpired request in the canonical wrapper", () => {
    const response = buildPublicRequestListResponse(
      [requestDocument()],
      serverNow
    );

    expect(response).toEqual({
      requests: [
        {
          id: "request-1",
          vendor: "Campus Market",
          food: "Vegetable rice bowl",
          pickupWindowText: "1:00 PM – 2:00 PM",
          windowStart: new Date("2026-07-26T20:00:00.000Z"),
          windowEnd: new Date("2026-07-26T21:00:00.000Z"),
          status: "requested",
          createdAt: new Date("2026-07-26T18:00:00.000Z"),
          expiresAt: new Date("2026-07-26T22:00:00.000Z"),
        },
      ],
    });
  });

  it("excludes a placed request", () => {
    const response = buildPublicRequestListResponse(
      [requestDocument({ status: "placed" })],
      serverNow
    );

    expect(response).toEqual({ requests: [] });
  });

  it("excludes a request expired according to server time", () => {
    const response = buildPublicRequestListResponse(
      [requestDocument({ expiresAt: serverNow })],
      serverNow
    );

    expect(response).toEqual({ requests: [] });
  });

  it("omits every requester-, claim-, fulfillment-, and database-private field", () => {
    const response = buildPublicRequestListResponse(
      [requestDocument()],
      serverNow
    );
    const serializedRequest = JSON.parse(
      JSON.stringify(response.requests[0])
    ) as Record<string, unknown>;

    expect(Object.keys(response)).toEqual(["requests"]);
    expect(Object.keys(serializedRequest)).toEqual([
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
    expect(serializedRequest).not.toHaveProperty("email");
    expect(serializedRequest).not.toHaveProperty("requesterPhone");
    expect(serializedRequest).not.toHaveProperty("requesterPhoneNumber");
    expect(serializedRequest).not.toHaveProperty("phone");
    expect(serializedRequest).not.toHaveProperty("pickupName");
    expect(serializedRequest).not.toHaveProperty("claimToken");
    expect(serializedRequest).not.toHaveProperty("claimTokenHash");
    expect(serializedRequest).not.toHaveProperty("claimTokenDigest");
    expect(serializedRequest).not.toHaveProperty("claimExpiresAt");
    expect(serializedRequest).not.toHaveProperty("orderNumber");
    expect(serializedRequest).not.toHaveProperty("eta");
    expect(serializedRequest).not.toHaveProperty("etaText");
    expect(serializedRequest).not.toHaveProperty("fulfillerEmail");
    expect(serializedRequest).not.toHaveProperty("contactMessage");
    expect(serializedRequest).not.toHaveProperty("note");
    expect(serializedRequest).not.toHaveProperty("notificationStatus");
    expect(serializedRequest).not.toHaveProperty("_id");
    expect(serializedRequest).not.toHaveProperty("__v");
  });
});
