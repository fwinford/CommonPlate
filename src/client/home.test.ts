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
    pickupWindowText: "ASAP (within the next hour)",
    windowStart: null,
    windowEnd: null,
    status: "requested",
    createdAt: "2026-07-26T18:00:00.000Z",
    expiresAt: "2026-07-26T22:00:00.000Z",
    ...overrides,
  };
}

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
    expect(html).toContain('data-id="request-123"');
    expect(html).toContain("Vegetable rice bowl");
    expect(html).toContain("Campus Market");
    expect(html).not.toContain("Requester Private Name");
    expect(html).not.toContain("requester@example.edu");
    expect(html).not.toContain("private-token");
  });

  it("uses canonical timing display fields without consulting device time", () => {
    const dateNow = vi.spyOn(Date, "now").mockImplementation(() => {
      throw new Error("device time must not be consulted");
    });

    expect(home.publicRequestWindowText(publicRequest())).toBe(
      "ASAP (within the next hour)"
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
