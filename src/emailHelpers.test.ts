import { readFileSync } from "node:fs";
import type { IRequest, ISubscriber } from "../models/db.js";
import { afterEach, describe, expect, it, vi } from "vitest";

const { resendSend } = vi.hoisted(() => ({
  resendSend: vi.fn(),
}));

vi.mock("resend", () => ({
  Resend: class {
    emails = { send: resendSend };
  },
}));

import {
  sendFulfillmentEmail,
  sendNewRequestAlert,
} from "./emailHelpers.js";

const requesterEmail = "requester-private@example.edu";
const requesterPhone = "555-0100";
const pickupName = "Requester Private Name";
const claimToken = "private-claim-token";

function request(): IRequest {
  return {
    _id: "64b000000000000000000001",
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName,
    pickupWindowText: "1:00 PM – 2:00 PM",
    email: requesterEmail,
    requesterPhone,
    claimToken,
    status: "requested",
    createdAt: new Date("2026-07-26T18:00:00.000Z"),
    updatedAt: new Date("2026-07-26T18:00:00.000Z"),
    expiresAt: new Date("2026-07-26T22:00:00.000Z"),
  } as unknown as IRequest;
}

function subscriber(): ISubscriber {
  return {
    _id: "64b000000000000000000002",
    email: "helper@example.edu",
    status: "confirmed",
    unsubToken: "unsubscribe-token",
    dailyCount: 0,
    bounced: false,
  } as unknown as ISubscriber;
}

afterEach(() => {
  resendSend.mockReset();
});

describe("helper new-request alert email", () => {
  it("uses only public request fields and links to safe browsing", async () => {
    resendSend.mockResolvedValue({});

    await sendNewRequestAlert(subscriber(), request());

    const email = resendSend.mock.calls[0][0] as {
      subject: string;
      html: string;
      text: string;
    };
    const allHelperContent = JSON.stringify(email);
    const baseUrl = (
      process.env.BASE_URL || "https://commonplatenyu.org"
    ).replace(/\/+$/, "");

    expect(email.subject).toBe(
      "New meal request: Campus Market · 1:00 PM – 2:00 PM"
    );
    expect(email.html).toContain("<strong>Vendor:</strong> Campus Market");
    expect(email.html).toContain(
      "<strong>Food:</strong> Vegetable rice bowl"
    );
    expect(email.html).toContain(
      "<strong>Pickup Window:</strong> 1:00 PM – 2:00 PM"
    );
    expect(email.html).toContain(
      `<a href="${baseUrl}/">View meal request</a>`
    );
    expect(email.text).toContain(`View meal request: ${baseUrl}/`);
    expect(allHelperContent).not.toContain(pickupName);
    expect(allHelperContent).not.toContain(requesterEmail);
    expect(allHelperContent).not.toContain(requesterPhone);
    expect(allHelperContent).not.toContain(claimToken);
    expect(allHelperContent).not.toContain("/fulfill");
    expect(allHelperContent).not.toMatch(/order this|fulfill this|claim/i);
  });
});

describe("requester email separation", () => {
  it("retains pickup and order information in the requester fulfillment email", async () => {
    resendSend.mockResolvedValue({});

    await sendFulfillmentEmail(
      request(),
      "ORDER123",
      "15 minutes",
      "Your meal is ready",
      "helper@example.edu"
    );

    const email = resendSend.mock.calls[0][0] as {
      to: string;
      html: string;
      text: string;
      reply_to: string;
    };

    expect(email.to).toBe(requesterEmail);
    expect(email.html).toContain(`Pickup name:</strong> ${pickupName}`);
    expect(email.html).toContain("Order number:</strong> ORDER123");
    expect(email.text).toContain(`Pickup name: ${pickupName}`);
    expect(email.text).toContain("Order number: ORDER123");
    expect(email.reply_to).toBe("helper@example.edu");
  });

  it("keeps requester confirmation pickup information intact", () => {
    const appSource = readFileSync(
      new URL("../app.ts", import.meta.url),
      "utf8"
    );
    const confirmationStart = appSource.indexOf(
      'subject: "Request Confirmed - CommonPlate"'
    );
    const confirmationEnd = appSource.indexOf(
      "      });",
      confirmationStart
    );
    const requesterConfirmation = appSource.slice(
      confirmationStart,
      confirmationEnd
    );

    expect(confirmationStart).toBeGreaterThan(-1);
    expect(confirmationEnd).toBeGreaterThan(confirmationStart);
    expect(requesterConfirmation).toContain(
      "<strong>Pickup Name:</strong> ${sPickupName}"
    );
    expect(requesterConfirmation).toContain("Pickup Name: ${pickupName}");
  });
});
