import { readFileSync } from "node:fs";
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
  it("confirms submission and takes the request id from the canonical wrapper", () => {
    const message = newRequest.submissionSuccessText(
      "64b000000000000000000001"
    );

    expect(message).toBe(
      "Request submitted successfully! Request ID: 64b000000000000000000001"
    );
    expect(message).toContain("submitted successfully");
    expect(message).toContain("64b000000000000000000001");
  });

  it("never renders an undefined request id", () => {
    expect(newRequest.submissionSuccessText(undefined)).toBe(
      "Request submitted successfully!"
    );
    expect(newRequest.submissionSuccessText(undefined)).not.toContain(
      "undefined"
    );
  });

  /// Persistence succeeds independently of requester email delivery, so the
  /// success message must not promise a message that may never be sent.
  it("promises no email delivery", () => {
    for (const message of [
      newRequest.submissionSuccessText("64b000000000000000000001"),
      newRequest.submissionSuccessText(undefined),
    ]) {
      for (const forbidden of [
        "email",
        "e-mail",
        "confirmation",
        "confirm",
        "inbox",
        "sent",
        "send",
        "receive",
        "check your",
      ]) {
        expect(message.toLowerCase()).not.toContain(forbidden);
      }
    }
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

/**
 * The email hint is static markup, so it is asserted against the page source
 * rather than through the bundled script. The same sentence is asserted on
 * iOS in `RequestCreationViewTests`; both halves must exist or the two
 * requester forms can explain the same required field differently.
 */
describe("web request form explains why it needs an email", () => {
  const pageSource = readFileSync(
    new URL("../../public/new-request.html", import.meta.url),
    "utf8"
  );

  function emailHint(): string {
    const match = pageSource.match(
      /<input[^>]*id="email"[^>]*>\s*<small>([^<]*)<\/small>/
    );
    expect(match, "no <small> hint found after the email input").not.toBeNull();
    return match![1];
  }

  it("states the purpose and the privacy guarantee", () => {
    expect(emailHint()).toBe(
      "We use your email to coordinate updates about your request. Helpers never see it."
    );
  });

  /// Requester confirmation is sent after persistence and cannot undo it, so
  /// a `201` does not prove any message was sent.
  it("guarantees no email delivery", () => {
    const hint = emailHint().toLowerCase();

    for (const forbidden of [
      "we'll send",
      "we will send",
      "confirmation",
      "confirm",
      "notify",
      "inbox",
      "receipt",
      "check your",
    ]) {
      expect(hint).not.toContain(forbidden);
    }
  });
});

describe("web request form privacy disclosure", () => {
  const pageSource = readFileSync(
    new URL("../../public/new-request.html", import.meta.url),
    "utf8"
  );

  it("states the scoped data sharing and retention facts without an absolute", () => {
    for (const expected of [
      "Pickup name is shared only with the successful helper",
      "the helper’s email may be sent to the requester for coordination",
      "Placed Request data is retained for seven days",
      "Fulfillment records may be retained longer",
    ]) {
      expect(pageSource).toContain(expected);
    }
    expect(pageSource).not.toContain(
      "We never share your personal information"
    );
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
