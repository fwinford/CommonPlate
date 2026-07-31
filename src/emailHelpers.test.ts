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

function request(overrides: Record<string, unknown> = {}): IRequest {
  return {
    _id: "64b000000000000000000001",
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName,
    pickupWindowText: "1:00 PM – 2:00 PM",
    email: requesterEmail,
    requesterPhone,
    claimToken,
    status: "open",
    createdAt: new Date("2026-07-26T18:00:00.000Z"),
    updatedAt: new Date("2026-07-26T18:00:00.000Z"),
    expiresAt: new Date("2026-07-26T22:00:00.000Z"),
    ...overrides,
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

  it("renders requester markup as text without double escaping", async () => {
    resendSend.mockResolvedValue({});
    const injectedVendor = `Campus & <img src=x onerror="alert('vendor')">`;
    const injectedFood = `<a href="https://attacker.invalid">Free meal</a>`;
    const injectedPickupWindow = `5 < 6 & "soon"`;

    await sendNewRequestAlert(
      subscriber(),
      request({
        vendor: injectedVendor,
        food: injectedFood,
        pickupWindowText: injectedPickupWindow,
      })
    );

    const email = resendSend.mock.calls[0][0] as { html: string };
    expect(email.html).toContain(
      `Campus &amp; &lt;img src=x onerror=&quot;alert(&#39;vendor&#39;)&quot;&gt;`
    );
    expect(email.html).toContain(
      `&lt;a href=&quot;https://attacker.invalid&quot;&gt;Free meal&lt;/a&gt;`
    );
    expect(email.html).toContain(`5 &lt; 6 &amp; &quot;soon&quot;`);
    expect(email.html).not.toContain(injectedVendor);
    expect(email.html).not.toContain(injectedFood);
    expect(email.html).not.toContain(injectedPickupWindow);
    expect(email.html).not.toContain("&amp;amp;");
    expect(email.html).not.toContain("&amp;lt;");
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

    // Asserts the option name the Resend SDK actually reads. The SDK builds its
    // request body from `replyTo` alone, so asserting the wire name `reply_to`
    // here would pass while the sent email carried no Reply-To at all.
    const email = resendSend.mock.calls[0][0] as {
      to: string;
      html: string;
      text: string;
      replyTo: string;
      reply_to?: string;
    };

    expect(email.to).toBe(requesterEmail);
    expect(email.html).toContain(`Pickup name:</strong> ${pickupName}`);
    expect(email.html).toContain("Order number:</strong> ORDER123");
    expect(email.html).toContain("Pickup window:</strong> 1:00 PM – 2:00 PM");
    expect(email.html).toContain("ETA:</strong> 15 minutes");
    expect(email.html).toContain("Your meal is ready");
    expect(email.text).toContain(`Pickup name: ${pickupName}`);
    expect(email.text).toContain("Order number: ORDER123");
    expect(email.text).toContain("Pickup window: 1:00 PM – 2:00 PM");
    expect(email.text).toContain("ETA: 15 minutes");
    expect(email.text).toContain("Your meal is ready");
    expect(email.replyTo).toBe("helper@example.edu");
    expect(email.reply_to).toBeUndefined();
  });

  it("keeps requester confirmation pickup information intact", () => {
    const routeSource = readFileSync(
      new URL("./createRequestRoute.ts", import.meta.url),
      "utf8"
    );
    const confirmationStart = routeSource.indexOf(
      'subject: "Request Confirmed - CommonPlate"'
    );
    const confirmationEnd = routeSource.indexOf(
      "      });",
      confirmationStart
    );
    const requesterConfirmation = routeSource.slice(
      confirmationStart,
      confirmationEnd
    );

    expect(confirmationStart).toBeGreaterThan(-1);
    expect(confirmationEnd).toBeGreaterThan(confirmationStart);
    expect(requesterConfirmation).toContain(
      "<strong>Pickup Name:</strong> ${htmlPickupName}"
    );
    expect(requesterConfirmation).toContain(
      "Pickup Name: ${request.pickupName}"
    );
  });
});
