import type { IRequest, ISubscriber } from "../models/db.js";
import { afterEach, describe, expect, it, vi } from "vitest";

const { sendEmailSafe } = vi.hoisted(() => ({
  sendEmailSafe: vi.fn(),
}));

vi.mock("./emailHelpers.js", () => ({
  sendEmailSafe,
}));

import { sendDigestEmail } from "./sendDigestEmail.js";

function request(
  id: string,
  privatePickupName: string,
  privateRequesterEmail: string
): IRequest {
  return {
    _id: id,
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName: privatePickupName,
    pickupWindowText: "1:00 PM – 2:00 PM",
    email: privateRequesterEmail,
    requesterPhone: "555-0100",
    claimToken: "private-claim-token",
    status: "requested",
    createdAt: new Date("2026-07-26T18:00:00.000Z"),
    updatedAt: new Date("2026-07-26T18:00:00.000Z"),
    expiresAt: new Date("2026-07-26T22:00:00.000Z"),
  } as unknown as IRequest;
}

function subscriber(): ISubscriber {
  return {
    _id: "64b000000000000000000003",
    email: "helper@example.edu",
    status: "confirmed",
    unsubToken: "unsubscribe-token",
    dailyCount: 0,
    bounced: false,
  } as unknown as ISubscriber;
}

afterEach(() => {
  sendEmailSafe.mockReset();
});

describe("helper digest email", () => {
  it("uses only public request fields and safe homepage links", async () => {
    sendEmailSafe.mockResolvedValue({ success: true });
    const privateValues = [
      "First Private Pickup",
      "Second Private Pickup",
      "first-requester@example.edu",
      "second-requester@example.edu",
      "555-0100",
      "private-claim-token",
    ];

    await sendDigestEmail(subscriber(), [
      request(
        "64b000000000000000000001",
        privateValues[0],
        privateValues[2]
      ),
      request(
        "64b000000000000000000002",
        privateValues[1],
        privateValues[3]
      ),
    ]);

    const email = sendEmailSafe.mock.calls[0][0] as {
      subject: string;
      html: string;
      text: string;
    };
    const allHelperContent = JSON.stringify(email);
    const baseUrl = (
      process.env.BASE_URL || "https://commonplatenyu.org"
    ).replace(/\/+$/, "");

    expect(email.subject).toBe("2 new meal requests in the last hour");
    expect(email.html).toContain(
      "<strong>Campus Market</strong> — Vegetable rice bowl"
    );
    expect(email.html).toContain("<em>1:00 PM – 2:00 PM</em>");
    expect(email.html).toContain(
      `<a href="${baseUrl}/">View meal request</a>`
    );
    expect(email.text).toContain(`View meal request: ${baseUrl}/`);
    for (const privateValue of privateValues) {
      expect(allHelperContent).not.toContain(privateValue);
    }
    expect(allHelperContent).not.toContain("/fulfill");
    expect(allHelperContent).not.toMatch(/order this|fulfill this|claim/i);
  });
});
