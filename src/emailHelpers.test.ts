import { readFileSync } from "node:fs";
import type { IRequest, ISubscriber } from "../models/db.js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { resendSend } = vi.hoisted(() => ({
  resendSend: vi.fn(),
}));

vi.mock("resend", () => ({
  Resend: class {
    emails = { send: resendSend };
  },
}));

import {
  EmailProviderTimeoutError,
  confirmationBaseUrl,
  sendFulfillmentEmail,
  sendNewRequestAlert,
  sendSubscriptionConfirmationEmail,
} from "./emailHelpers.js";
import {
  UNSUBSCRIBE_CREDENTIAL_PARAMETER,
  UNSUBSCRIBE_ROUTE_PATH,
  verifyUnsubscribeCredential,
} from "./unsubscribeCredential.js";

// A fixed injected secret rather than a stubbed environment variable, so these
// cases do not depend on process-wide state another suite could change.
const SIGNING_SECRET = Buffer.alloc(32, 5);
const SUBSCRIBER_ID = "64b000000000000000000002";

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

function subscriber(overrides: Record<string, unknown> = {}): ISubscriber {
  return {
    _id: SUBSCRIBER_ID,
    email: "helper@example.edu",
    status: "confirmed",
    unsubscribeCredentialVersion: 1,
    dailyCount: 0,
    bounced: false,
    ...overrides,
  } as unknown as ISubscriber;
}

/** The single `credential` query parameter carried by an emailed link. */
function credentialFrom(url: string): string | null {
  return new URL(url).searchParams.get(UNSUBSCRIBE_CREDENTIAL_PARAMETER);
}

function unsubscribeUrlIn(text: string): string {
  const match = text.match(
    new RegExp(`https?://[^\\s"'<>]*${UNSUBSCRIBE_ROUTE_PATH}\\?credential=[^\\s"'<>]+`)
  );
  expect(match).not.toBeNull();
  return match![0];
}

afterEach(() => {
  resendSend.mockReset();
  vi.unstubAllEnvs();
});

describe("helper new-request alert email", () => {
  it("uses only public request fields and links to safe browsing", async () => {
    resendSend.mockResolvedValue({});

    await sendNewRequestAlert(subscriber(), request(), {
      unsubscribeSigningSecret: SIGNING_SECRET,
    });

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
      }),
      { unsubscribeSigningSecret: SIGNING_SECRET }
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

describe("helper alert unsubscribe link", () => {
  // Vitest supplies its own `BASE_URL`, so the configured origin is stated
  // here rather than inherited from whatever the runner happens to set.
  beforeEach(() => {
    vi.stubEnv("BASE_URL", "https://commonplate.test/");
  });

  it("carries a correctly formed unsubscribe URL in both bodies", async () => {
    resendSend.mockResolvedValue({});

    await sendNewRequestAlert(subscriber(), request(), {
      unsubscribeSigningSecret: SIGNING_SECRET,
    });

    const email = resendSend.mock.calls[0][0] as {
      html: string;
      text: string;
    };
    const htmlUrl = unsubscribeUrlIn(email.html);
    const textUrl = unsubscribeUrlIn(email.text);

    expect(htmlUrl).toBe(textUrl);
    // Configured origin, accepted path, one `credential` parameter, and no
    // doubled separator from the trailing slash in `BASE_URL`.
    expect(htmlUrl.startsWith(`https://commonplate.test${UNSUBSCRIBE_ROUTE_PATH}?`)).toBe(true);
    expect([...new URL(htmlUrl).searchParams.keys()]).toEqual([
      UNSUBSCRIBE_CREDENTIAL_PARAMETER,
    ]);
  });

  it("emails a credential that verifies for exactly this subscriber", async () => {
    resendSend.mockResolvedValue({});

    await sendNewRequestAlert(subscriber(), request(), {
      unsubscribeSigningSecret: SIGNING_SECRET,
    });

    const email = resendSend.mock.calls[0][0] as { html: string };
    const credential = credentialFrom(unsubscribeUrlIn(email.html));

    expect(
      verifyUnsubscribeCredential(credential, SIGNING_SECRET)
    ).toEqual({ subscriberId: SUBSCRIBER_ID, credentialVersion: 1 });
  });

  it("needs no stored raw unsubscribe token to build the link", async () => {
    resendSend.mockResolvedValue({});
    // Neither a raw token nor a stored digest exists on this document, and a
    // subscriber written before the version field carries no version either.
    const withoutStoredCredential = subscriber({
      unsubscribeCredentialVersion: undefined,
    });

    await sendNewRequestAlert(withoutStoredCredential, request(), {
      unsubscribeSigningSecret: SIGNING_SECRET,
    });

    const email = resendSend.mock.calls[0][0] as { html: string };
    expect(
      verifyUnsubscribeCredential(
        credentialFrom(unsubscribeUrlIn(email.html)),
        SIGNING_SECRET
      )
    ).toEqual({ subscriberId: SUBSCRIBER_ID, credentialVersion: 1 });
  });

  it("reflects a raised credential version in the emailed link", async () => {
    resendSend.mockResolvedValue({});

    await sendNewRequestAlert(
      subscriber({ unsubscribeCredentialVersion: 4 }),
      request(),
      { unsubscribeSigningSecret: SIGNING_SECRET }
    );

    const email = resendSend.mock.calls[0][0] as { html: string };
    expect(
      verifyUnsubscribeCredential(
        credentialFrom(unsubscribeUrlIn(email.html)),
        SIGNING_SECRET
      )
    ).toEqual({ subscriberId: SUBSCRIBER_ID, credentialVersion: 4 });
  });
});

describe("subscription confirmation email", () => {
  it("places the raw token only in the submitted confirmation URL", async () => {
    vi.stubEnv("BASE_URL", "https://commonplate.test/");
    resendSend.mockResolvedValue({ data: { id: "email-id" }, error: null });
    const rawToken = Buffer.alloc(32, 7).toString("base64url");

    await sendSubscriptionConfirmationEmail("helper@example.edu", rawToken);

    const email = resendSend.mock.calls[0][0] as {
      to: string;
      subject: string;
      html: string;
      text: string;
    };
    const expectedUrl = `https://commonplate.test/api/subscribe/confirm?token=${rawToken}`;
    expect(email.to).toBe("helper@example.edu");
    expect(email.subject).toBe("Confirm your CommonPlate subscription");
    expect(email.html).toContain(expectedUrl);
    expect(email.text).toContain(expectedUrl);
  });

  it("builds the confirmation URL only from trusted configuration", () => {
    vi.stubEnv("BASE_URL", "https://commonplate.test");
    expect(confirmationBaseUrl()).toBe("https://commonplate.test");

    // No request is reachable from here at all, so no `Host`,
    // `X-Forwarded-Host`, or forwarded protocol can reach a bearer-token link.
    const source = readFileSync(
      new URL("./emailHelpers.ts", import.meta.url),
      "utf8"
    );
    const confirmationStart = source.indexOf(
      "export async function sendSubscriptionConfirmationEmail"
    );
    expect(confirmationStart).toBeGreaterThanOrEqual(0);
    const confirmationEnd = source.indexOf(
      "export async function sendNewRequestAlert",
      confirmationStart
    );
    expect(confirmationEnd).toBeGreaterThan(confirmationStart);
    const confirmationSource = source.slice(confirmationStart, confirmationEnd);
    expect(confirmationSource).not.toMatch(/req\b|host|protocol|forwarded/i);
  });

  it.each([
    ["returned error", () => resendSend.mockResolvedValue({ error: { message: "rejected" } })],
    ["thrown error", () => resendSend.mockRejectedValue(new Error("offline"))],
  ])("rejects a provider %s", async (_label, arrange) => {
    arrange();

    await expect(
      sendSubscriptionConfirmationEmail(
        "helper@example.edu",
        Buffer.alloc(32, 8).toString("base64url")
      )
    ).rejects.toThrow();
  });

  it("hands the provider a real abort signal and cancels it at the deadline", async () => {
    vi.useFakeTimers();
    try {
      let capturedSignal: AbortSignal | undefined;
      // Never settles on its own: only a genuine abort can end this call, so a
      // racing promise that left the request in flight would time the test out.
      resendSend.mockImplementation(
        (_payload: unknown, options: { signal?: AbortSignal }) =>
          new Promise((_resolve, reject) => {
            capturedSignal = options?.signal;
            options?.signal?.addEventListener("abort", () =>
              reject(new Error("The operation was aborted"))
            );
          })
      );

      const pending = sendSubscriptionConfirmationEmail(
        "helper@example.edu",
        Buffer.alloc(32, 9).toString("base64url"),
        1_000
      );
      const settled = expect(pending).rejects.toBeInstanceOf(
        EmailProviderTimeoutError
      );

      expect(capturedSignal).toBeInstanceOf(AbortSignal);
      expect(capturedSignal!.aborted).toBe(false);
      await vi.advanceTimersByTimeAsync(1_000);
      expect(capturedSignal!.aborted).toBe(true);

      await settled;
      // Pinned: `subscribeRoute.mongo.test.ts` drives the compensation path
      // with an error carrying exactly this name.
      await expect(pending).rejects.toMatchObject({
        name: "EmailProviderTimeoutError",
      });
    } finally {
      vi.useRealTimers();
    }
  });

  it("clears its deadline once the provider answers", async () => {
    vi.useFakeTimers();
    try {
      resendSend.mockResolvedValue({ data: { id: "email-id" }, error: null });

      await sendSubscriptionConfirmationEmail(
        "helper@example.edu",
        Buffer.alloc(32, 10).toString("base64url")
      );

      expect(vi.getTimerCount()).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("requester email separation", () => {
  it("retains pickup and order information in the requester fulfillment email", async () => {
    resendSend.mockResolvedValue({});

    await sendFulfillmentEmail(
      request(),
      "70154321",
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
    expect(email.html).toContain("Order number:</strong> 70154321");
    expect(email.html).toContain("Pickup window:</strong> 1:00 PM – 2:00 PM");
    expect(email.html).toContain("ETA:</strong> 15 minutes");
    expect(email.html).toContain("Your meal is ready");
    expect(email.text).toContain(`Pickup name: ${pickupName}`);
    expect(email.text).toContain("Order number: 70154321");
    expect(email.text).toContain("Pickup window: 1:00 PM – 2:00 PM");
    expect(email.text).toContain("ETA: 15 minutes");
    expect(email.text).toContain("Your meal is ready");
    expect(email.replyTo).toBe("helper@example.edu");
    expect(email.reply_to).toBeUndefined();
  });

  // The helper types their address into the fulfillment form, so the one way
  // this notification can go wrong without failing is by treating that address
  // as the destination. The student is the recipient; the helper is only ever
  // the Reply-To.
  it("never lets the helper become the recipient of the fulfillment email", async () => {
    resendSend.mockResolvedValue({});
    const helperEmail = "helper@example.edu";

    await sendFulfillmentEmail(
      request(),
      "70154321",
      "ASAP",
      undefined,
      helperEmail
    );

    const email = resendSend.mock.calls[0][0] as {
      to: string;
      replyTo?: string;
    };
    expect(email.to).toBe(requesterEmail);
    expect(email.to).not.toBe(helperEmail);
    expect(email.replyTo).toBe(helperEmail);
  });

  // A request with no stored student address cannot be notified. Failing loudly
  // keeps the route's post-commit catch honest — placement stays recorded and
  // the response reports `failed` — instead of silently sending nowhere.
  it("refuses to send when the request carries no student email", async () => {
    resendSend.mockResolvedValue({});

    await expect(
      sendFulfillmentEmail(
        request({ email: undefined }),
        "70154321",
        "ASAP",
        undefined,
        "helper@example.edu"
      )
    ).rejects.toThrow();
    expect(resendSend).not.toHaveBeenCalled();
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
