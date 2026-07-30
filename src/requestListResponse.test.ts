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
          status: "open",
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

  it("excludes an active claim completely", () => {
    const response = buildPublicRequestListResponse(
      [
        requestDocument({
          status: "claimed",
          claimExpiresAt: new Date("2026-07-26T19:00:00.001Z"),
        }),
      ],
      serverNow
    );

    expect(response).toEqual({ requests: [] });
  });

  it("advertises a claim expiring at backend now as open", () => {
    const response = buildPublicRequestListResponse(
      [
        requestDocument({
          status: "claimed",
          claimExpiresAt: serverNow,
        }),
      ],
      serverNow
    );

    expect(response.requests).toHaveLength(1);
    expect(response.requests[0].status).toBe("open");
  });

  it("advertises an expired claim as open without altering the record", () => {
    const document = requestDocument({
      status: "claimed",
      claimExpiresAt: new Date("2026-07-26T18:45:00.000Z"),
    });

    const response = buildPublicRequestListResponse([document], serverNow);

    expect(response.requests).toHaveLength(1);
    expect(response.requests[0].status).toBe("open");
    // The persisted record keeps its claimed lifecycle state: projection is
    // derived per response, never written back.
    expect(document.status).toBe("claimed");
    expect(document.claimExpiresAt).toEqual(
      new Date("2026-07-26T18:45:00.000Z")
    );
  });

  it("never advertises a status other than open", () => {
    const response = buildPublicRequestListResponse(
      [
        requestDocument({ _id: "open-request" }),
        requestDocument({
          _id: "expired-claim",
          status: "claimed",
          claimExpiresAt: new Date("2026-07-26T18:45:00.000Z"),
        }),
        requestDocument({
          _id: "active-claim",
          status: "claimed",
          claimExpiresAt: new Date("2026-07-26T19:30:00.000Z"),
        }),
        requestDocument({ _id: "placed-request", status: "placed" }),
      ],
      serverNow
    );

    expect(response.requests).toHaveLength(2);
    expect(
      response.requests.map((request) => request.status)
    ).toEqual(["open", "open"]);
  });

  it("excludes a request expired according to server time", () => {
    const response = buildPublicRequestListResponse(
      [requestDocument({ expiresAt: serverNow })],
      serverNow
    );

    expect(response).toEqual({ requests: [] });
  });

  it("fails closed when an open document has no valid expiration", () => {
    const response = buildPublicRequestListResponse(
      [requestDocument({ expiresAt: undefined })],
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
    expect(serializedRequest).not.toHaveProperty("claimedAt");
    expect(serializedRequest).not.toHaveProperty("claimExtendedAt");
    expect(serializedRequest).not.toHaveProperty("deleteAt");
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
