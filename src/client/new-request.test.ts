import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";

let newRequest: typeof import("./new-request.js");

beforeAll(async () => {
  vi.stubGlobal("document", {
    addEventListener: vi.fn(),
  });

  newRequest = await import("./new-request.js");
});

afterAll(() => {
  vi.unstubAllGlobals();
});

afterEach(() => {
  vi.restoreAllMocks();
});

function formRoot() {
  const notice = { textContent: "", hidden: true };
  const submitBtn = {
    disabled: false,
    attributes: {} as Record<string, string>,
    setAttribute(name: string, value: string) {
      this.attributes[name] = value;
    },
  };
  const elements: Record<string, unknown> = {
    "pause-notice": notice,
    "submit-btn": submitBtn,
  };

  return {
    notice,
    submitBtn,
    root: {
      getElementById: (id: string) => elements[id] ?? null,
    } as unknown as Document,
  };
}

describe("web request form pause", () => {
  it("reveals the notice and removes the submit action", () => {
    const { notice, submitBtn, root } = formRoot();

    newRequest.applyRequestFormPause(root);

    expect(notice.textContent).toBe(
      newRequest.REQUEST_POSTING_PAUSED_MESSAGE
    );
    expect(notice.hidden).toBe(false);
    expect(submitBtn.disabled).toBe(true);
    expect(submitBtn.attributes["aria-disabled"]).toBe("true");
  });

  it("uses the same locked sentence the iOS form shows", () => {
    expect(newRequest.REQUEST_POSTING_PAUSED_MESSAGE).toBe(
      "Posting a meal request is temporarily unavailable."
    );
  });
});

describe("web request form reads the canonical create response", () => {
  it("takes the request id from the canonical wrapper", () => {
    expect(newRequest.submissionSuccessText("64b000000000000000000001")).toBe(
      "Request submitted successfully! Check your email for confirmation. Request ID: 64b000000000000000000001"
    );
  });

  it("never renders an undefined request id", () => {
    expect(newRequest.submissionSuccessText(undefined)).toBe(
      "Request submitted successfully! Check your email for confirmation."
    );
    expect(newRequest.submissionSuccessText(undefined)).not.toContain(
      "undefined"
    );
  });

  it("reads the message out of the structured error envelope", () => {
    expect(
      newRequest.errorMessage({
        code: "REQUEST_LIMIT_REACHED",
        message: "You have reached the daily limit of 3 meal requests",
      })
    ).toBe("You have reached the daily limit of 3 meal requests");
  });

  it("still reads the legacy flat error string", () => {
    expect(newRequest.errorMessage("missing fields")).toBe("missing fields");
    expect(newRequest.errorMessage(undefined)).toBeUndefined();
  });
});

describe("web request form pause probe", () => {
  it("reports paused when the server says so", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ paused: true }),
      })
    );

    await expect(newRequest.fetchPublicActionsPaused()).resolves.toBe(true);
  });

  it("reports resumed only on an explicit false", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ paused: false }),
      })
    );

    await expect(newRequest.fetchPublicActionsPaused()).resolves.toBe(false);
  });

  it("fails closed on an error status, malformed body, or network failure", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({ ok: false, json: () => Promise.resolve({}) })
    );
    await expect(newRequest.fetchPublicActionsPaused()).resolves.toBe(true);

    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({ ok: true, json: () => Promise.resolve({}) })
    );
    await expect(newRequest.fetchPublicActionsPaused()).resolves.toBe(true);

    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("offline")));
    await expect(newRequest.fetchPublicActionsPaused()).resolves.toBe(true);
  });
});
