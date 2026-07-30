import type { IRequest, ISubscriber } from "../models/db.js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";

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
  privateRequesterEmail: string,
  overrides: Record<string, unknown> = {}
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
    status: "open",
    createdAt: new Date("2026-07-26T18:00:00.000Z"),
    updatedAt: new Date("2026-07-26T18:00:00.000Z"),
    expiresAt: new Date("2026-07-26T22:00:00.000Z"),
    ...overrides,
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

// These cases describe the resumed send path; the paused case is asserted
// separately below.
beforeEach(() => {
  vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
});

afterEach(() => {
  sendEmailSafe.mockReset();
  vi.unstubAllEnvs();
});

describe("helper digest email while public actions are paused", () => {
  it("refuses to send rather than returning as if delivered", async () => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");
    sendEmailSafe.mockResolvedValue({ success: true });

    await expect(
      sendDigestEmail(subscriber(), [
        request("64b000000000000000000001", "Private Name", "private@example.edu"),
      ])
    ).rejects.toThrow(PUBLIC_ACTIONS_PAUSED_ENV);

    expect(sendEmailSafe).not.toHaveBeenCalled();
  });
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

  it("renders requester markup as text without double escaping", async () => {
    sendEmailSafe.mockResolvedValue({ success: true });
    const injectedVendor = `Campus & <img src=x onerror="alert('vendor')">`;
    const injectedFood = `<a href="https://attacker.invalid">Free meal</a>`;
    const injectedPickupWindow = `5 < 6 & "soon"`;

    await sendDigestEmail(subscriber(), [
      request(
        "64b000000000000000000001",
        "Private Pickup",
        "requester@example.edu",
        {
          vendor: injectedVendor,
          food: injectedFood,
          pickupWindowText: injectedPickupWindow,
        }
      ),
    ]);

    const email = sendEmailSafe.mock.calls[0][0] as { html: string };
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
