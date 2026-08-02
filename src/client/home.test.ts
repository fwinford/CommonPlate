import {
  afterAll,
  afterEach,
  beforeAll,
  describe,
  expect,
  it,
  vi,
} from "vitest";
import type { PublicMealRequest } from "./home.js";

let home: typeof import("./home.js");

beforeAll(async () => {
  vi.stubGlobal("document", {
    addEventListener: vi.fn(),
    createElement: () => {
      let innerHTML = "";

      return {
        get innerHTML() {
          return innerHTML;
        },
        set textContent(value: string) {
          innerHTML = value
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;")
            .replace(/'/g, "&#39;");
        },
      };
    },
  });

  home = await import("./home.js");
});

afterAll(() => {
  vi.unstubAllGlobals();
});

afterEach(() => {
  vi.restoreAllMocks();
});

function publicRequest(
  overrides: Partial<PublicMealRequest> = {}
): PublicMealRequest {
  return {
    id: "request-123",
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupWindowText: "ASAP (within the next 5 hours)",
    windowStart: null,
    windowEnd: null,
    status: "open",
    createdAt: "2026-07-26T18:00:00.000Z",
    expiresAt: "2026-07-26T22:00:00.000Z",
    ...overrides,
  };
}

describe("homepage subscription pause", () => {
  function heroRoot() {
    const subscribeBtn = { hidden: false };
    const subscribePanel = { hidden: false, style: { display: "block" } };
    const unavailable = { textContent: "", hidden: true };
    const elements: Record<string, unknown> = {
      "subscribe-cta-btn": subscribeBtn,
      "subscribe-panel": subscribePanel,
      "alerts-unavailable": unavailable,
    };

    return {
      subscribeBtn,
      subscribePanel,
      unavailable,
      root: {
        getElementById: (id: string) => elements[id] ?? null,
      } as unknown as Document,
    };
  }

  it("withholds the signup control and explains why", () => {
    const { subscribeBtn, subscribePanel, unavailable, root } = heroRoot();

    home.applySubscriptionPause(root);

    expect(subscribeBtn.hidden).toBe(true);
    expect(subscribePanel.hidden).toBe(true);
    expect(subscribePanel.style.display).toBe("none");
    expect(unavailable.textContent).toBe(home.ALERTS_UNAVAILABLE_MESSAGE);
    expect(unavailable.hidden).toBe(false);
  });

  it("fails closed when the pause state cannot be read", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("offline")));

    await expect(home.fetchPublicActionsPaused()).resolves.toBe(true);
  });

  it("restores the signup control only on an explicit false", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ paused: false }),
      })
    );

    await expect(home.fetchPublicActionsPaused()).resolves.toBe(false);
  });
});

describe("public request-list web contract", () => {
  it("decodes requests from the canonical response wrapper", () => {
    const request = publicRequest();

    expect(home.requestsFromResponse({ requests: [request] })).toEqual([
      request,
    ]);
  });

  it("renders a card with the public id and public display fields only", () => {
    const request = {
      ...publicRequest(),
      pickupName: "Requester Private Name",
      email: "requester@example.edu",
      claimToken: "private-token",
    };

    const html = home.renderPublicRequestCard(request);

    expect(html).toContain('data-request-id="request-123"');
    expect(html).toContain("Vegetable rice bowl");
    expect(html).toContain("Campus Market");
    expect(html).toContain(home.WEB_ORDERING_UNAVAILABLE_MESSAGE);
    expect(html).toContain("disabled");
    expect(html).not.toContain("Order This");
    expect(html).not.toContain("/fulfill");
    expect(html).not.toContain("Requester Private Name");
    expect(html).not.toContain("requester@example.edu");
    expect(html).not.toContain("private-token");
  });

  it("renders public request detail without expecting or displaying private fields", () => {
    const request = {
      ...publicRequest(),
      pickupName: "Requester Private Name",
      email: "requester@example.edu",
      claimToken: "private-token",
    };

    const html = home.renderPublicRequestDetail(request);

    expect(html).toContain('class="modal-body"');
    expect(html).toContain("ASAP (within the next 5 hours)");
    expect(html).toContain("Vegetable rice bowl");
    expect(html).toContain("Campus Market");
    expect(html).not.toContain("Requester Private Name");
    expect(html).not.toContain("requester@example.edu");
    expect(html).not.toContain("private-token");
    expect(html).not.toContain("Pickup Name");
  });

  it("does not render a homepage link or action to the legacy fulfillment route", () => {
    const cardHtml = home.renderPublicRequestCard(publicRequest());
    const modalHtml = home.renderPublicRequestModal(publicRequest());

    expect(modalHtml).toContain(home.WEB_ORDERING_UNAVAILABLE_MESSAGE);
    expect(modalHtml).toContain("disabled");
    expect(modalHtml).not.toContain("I'll Order This");
    expect(`${cardHtml}${modalHtml}`).not.toMatch(
      /href=|\/request\/.*\/fulfill/
    );
  });

  it("uses canonical timing display fields without consulting device time", () => {
    const dateNow = vi.spyOn(Date, "now").mockImplementation(() => {
      throw new Error("device time must not be consulted");
    });

    expect(home.publicRequestWindowText(publicRequest())).toBe(
      "ASAP (within the next 5 hours)"
    );
    expect(
      home.publicRequestWindowText(
        publicRequest({
          pickupWindowText: "Jul 26, 4:00 PM – 5:00 PM",
          windowStart: "2026-07-26T20:00:00.000Z",
          windowEnd: "2026-07-26T21:00:00.000Z",
        })
      )
    ).toBe("Jul 26, 4:00 PM – 5:00 PM");

    expect(dateNow).not.toHaveBeenCalled();
  });
});
