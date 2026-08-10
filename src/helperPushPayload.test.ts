import mongoose from "mongoose";
import { describe, expect, it } from "vitest";
import {
  HELPER_NEW_REQUEST_NOTIFICATION_TYPE,
  HELPER_NEW_REQUEST_THREAD_ID,
  HelperPushPayloadError,
  MAXIMUM_PUSH_TEXT_LENGTH,
  boundPushText,
  buildHelperNewRequestHeaders,
  buildHelperNewRequestPayload,
} from "./helperPushPayload.js";

const requestId = new mongoose.Types.ObjectId("64b000000000000000000001");
const expiresAt = new Date("2026-07-28T21:00:00.000Z");
const TOPIC = "org.commonplatenyu.CommonPlateios";

/**
 * A document carrying every private field the request lifecycle can hold, so
 * the allowlist is proved against real leakage rather than against a fixture
 * that never had anything to leak.
 */
function fullRequestDocument(overrides: Record<string, unknown> = {}) {
  return {
    _id: requestId,
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupWindowText: "Jul 28, 1:00 PM – 2:00 PM",
    pickupName: "Requester Private Name",
    email: "requester@nyu.edu",
    status: "open",
    claimTokenDigest: "private-claim-digest",
    claimedAt: new Date("2026-07-28T16:30:00.000Z"),
    claimExpiresAt: new Date("2026-07-28T17:30:00.000Z"),
    claimExtendedAt: null,
    fulfillerEmail: "helper@nyu.edu",
    contactMessage: "Private contact message",
    orderNumber: "PRIVATE-ORDER-9",
    notificationStatus: "sent",
    expiresAt,
    deleteAt: expiresAt,
    // Every request accepted since W3-C1 carries an integer 1-5, on every
    // accepted shape including the legacy web one, so an ordinary fixture
    // always supplies it.
    mealSwipes: 3,
    ...overrides,
  } as never;
}

describe("helper new-request payload public allowlist", () => {
  it("carries exactly vendor, food, pickup window, meal swipes, and the request id", () => {
    // A normal post-C1 request: every accepted shape requires a valid
    // quantity, so the ordinary fixture (default `mealSwipes: 3`) carries one
    // and the allowlist proof reflects that, rather than the malformed/pre-C1
    // absent-quantity case proved separately below.
    const payload = buildHelperNewRequestPayload(fullRequestDocument());

    expect(payload).toEqual({
      aps: {
        alert: {
          title: "New request at Campus Market",
          body: "Vegetable rice bowl · Jul 28, 1:00 PM – 2:00 PM · Meal swipes: 3",
        },
        sound: "default",
        "interruption-level": "active",
        "thread-id": HELPER_NEW_REQUEST_THREAD_ID,
      },
      type: HELPER_NEW_REQUEST_NOTIFICATION_TYPE,
      requestId: requestId.toString(),
    });
  });

  it("includes the meal-swipe quantity concisely in the alert body (W3-C1)", () => {
    const payload = buildHelperNewRequestPayload(
      fullRequestDocument({ mealSwipes: 3 })
    );

    expect(payload.aps.alert.body).toBe(
      "Vegetable rice bowl · Jul 28, 1:00 PM – 2:00 PM · Meal swipes: 3"
    );
  });

  it("defensively omits the meal-swipe segment for a malformed pre-C1 stored request with no quantity", () => {
    // Every shape `POST /api/request` accepts, including the legacy web one,
    // has required an integer 1-5 since W3-C1; a `Request` document with none
    // is not a supported representation of any accepted submission, only a
    // stale/malformed stored row. This proves the composer degrades safely
    // rather than fabricating a value for that impossible state.
    const payload = buildHelperNewRequestPayload(
      fullRequestDocument({ mealSwipes: undefined })
    );

    expect(payload.aps.alert.body).toBe(
      "Vegetable rice bowl · Jul 28, 1:00 PM – 2:00 PM"
    );
  });

  it("leaks no private field from a document that carries all of them", () => {
    const serialized = JSON.stringify(
      buildHelperNewRequestPayload(fullRequestDocument())
    );

    for (const secret of [
      "Requester Private Name",
      "requester@nyu.edu",
      "private-claim-digest",
      "helper@nyu.edu",
      "Private contact message",
      "PRIVATE-ORDER-9",
      "claimExpiresAt",
      "notificationStatus",
      "deleteAt",
    ]) {
      expect(serialized).not.toContain(secret);
    }
    // The APNs token and installation credential are never even in scope here:
    // the payload is built once per request, before any installation is read.
    expect(serialized).not.toMatch(/apnsToken|installationCredential/);
  });

  it("routes by the same public id the list and detail responses expose", () => {
    expect(
      buildHelperNewRequestPayload(fullRequestDocument()).requestId
    ).toBe(String(requestId));
  });

  it("is an alert push, never a silent content-available push", () => {
    // The accepted product behavior requires a visible notification, including
    // while CommonPlate is in the foreground.
    const payload = buildHelperNewRequestPayload(fullRequestDocument());

    expect(payload.aps).not.toHaveProperty("content-available");
    expect(payload.aps.alert.title).not.toBe("");
    expect(payload.aps.alert.body).not.toBe("");
  });

  it("bounds each requester-supplied field and stays far under the APNs limit", () => {
    const payload = buildHelperNewRequestPayload(
      fullRequestDocument({
        vendor: "V".repeat(4000),
        food: "F".repeat(4000),
        pickupWindowText: "W".repeat(4000),
      })
    );
    const size = Buffer.byteLength(JSON.stringify(payload), "utf8");

    expect(payload.aps.alert.title.length).toBeLessThanOrEqual(
      "New request at ".length + MAXIMUM_PUSH_TEXT_LENGTH
    );
    expect(size).toBeLessThan(4096);
    expect(size).toBeLessThan(1024);
  });

  it("collapses whitespace and truncates with an ellipsis", () => {
    expect(boundPushText("  Campus   Market \n")).toBe("Campus Market");
    expect(boundPushText(undefined)).toBe("");
    const long = boundPushText("x".repeat(MAXIMUM_PUSH_TEXT_LENGTH + 10));
    expect(long).toHaveLength(MAXIMUM_PUSH_TEXT_LENGTH);
    expect(long.endsWith("…")).toBe(true);
    expect(boundPushText("y".repeat(MAXIMUM_PUSH_TEXT_LENGTH))).toHaveLength(
      MAXIMUM_PUSH_TEXT_LENGTH
    );
  });
});

describe("helper new-request APNs headers", () => {
  it("builds the accepted header set", () => {
    const headers = buildHelperNewRequestHeaders(fullRequestDocument(), {
      topic: TOPIC,
    });

    expect(headers).toEqual({
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-topic": TOPIC,
      "apns-collapse-id": requestId.toString(),
      "apns-expiration": String(Math.floor(expiresAt.getTime() / 1000)),
      "content-type": "application/json",
    });
  });

  it("derives apns-expiration from the request's own availability deadline", () => {
    // A notification APNs could not deliver promptly is discarded rather than
    // surfacing after the request can no longer be helped.
    const headers = buildHelperNewRequestHeaders(
      fullRequestDocument({ expiresAt: "2026-07-28T18:00:00.000Z" }),
      { topic: TOPIC }
    );

    expect(headers["apns-expiration"]).toBe("1785261600");
    expect(Number(headers["apns-expiration"])).toBe(
      new Date("2026-07-28T18:00:00.000Z").getTime() / 1000
    );
  });

  it("uses the request id as the collapse id, within Apple's 64-byte limit", () => {
    const headers = buildHelperNewRequestHeaders(fullRequestDocument(), {
      topic: TOPIC,
    });

    expect(headers["apns-collapse-id"]).toBe(requestId.toString());
    expect(
      Buffer.byteLength(headers["apns-collapse-id"], "utf8")
    ).toBeLessThanOrEqual(64);
  });

  it("carries no authorization header, so no builder ever holds a secret", () => {
    const headers = buildHelperNewRequestHeaders(fullRequestDocument(), {
      topic: TOPIC,
    });

    expect(headers).not.toHaveProperty("authorization");
    expect(Object.keys(headers)).not.toContain("Authorization");
  });

  it.each([undefined, null, "not-a-date"])(
    "refuses to build headers without a usable expiresAt (%j)",
    (expiration) => {
      expect(() =>
        buildHelperNewRequestHeaders(
          fullRequestDocument({ expiresAt: expiration }),
          { topic: TOPIC }
        )
      ).toThrow(HelperPushPayloadError);
    }
  );

  it("refuses to build headers without a configured topic", () => {
    expect(() =>
      buildHelperNewRequestHeaders(fullRequestDocument(), { topic: "  " })
    ).toThrow(HelperPushPayloadError);
  });
});
