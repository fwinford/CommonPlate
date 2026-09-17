import express, { type Request, type Response } from "express";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { callScreenshotProvider } = vi.hoisted(() => ({
  callScreenshotProvider: vi.fn(),
}));

vi.mock("./screenshotProposalProvider.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./screenshotProposalProvider.js")>();
  return { ...actual, callScreenshotProvider };
});

import { Participant } from "../models/db.js";
import {
  handleScreenshotProposal,
  INVALID_IMAGE_CODE,
  INVALID_IMAGE_MESSAGE,
  PROPOSAL_FAILED_CODE,
  PROVIDER_UNAVAILABLE_CODE,
  registerScreenshotProposalRoute,
} from "./screenshotProposalRoute.js";
import {
  PARTICIPANT_AUTHORITY_HEADER,
  PARTICIPANT_VERIFICATION_REQUIRED_CODE,
} from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";

const participantId = new mongoose.Types.ObjectId("64f0000000000000000000c1");
const participantPrincipal = "screenshot-route-unit@nyu.edu";
const participantSecretText = "screenshot-proposal-route-unit-test-secret";
const participantSecret = Buffer.from(participantSecretText);
const participantAuthority = signParticipantAuthority(
  participantId,
  1,
  participantSecret
);

function stubVerifiedParticipant() {
  return vi.spyOn(Participant, "findOne").mockReturnValue({
    select: () => ({
      lean: () => ({
        exec: vi.fn().mockResolvedValue({
          _id: participantId,
          email: participantPrincipal,
        }),
      }),
    }),
  } as unknown as ReturnType<typeof Participant.findOne>);
}

// Smallest possible well-formed 1x1 PNG, so magic-byte validation passes
// without shipping a real screenshot fixture into a unit test.
const ONE_PIXEL_PNG_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";

/** Independent on-device Vision OCR evidence establishing the cart/bag
 * eligible category — the only thing that ever gates the provider call. */
const cartEvidenceText =
  "Your Pickup Order Order Instructions Cilantro on the side Continue to Checkout";
const historicalEvidenceText =
  "View order Order information 1 Create Your Own Bowl";
const ineligibleEvidenceText = "Your Orders Past Orders Reorder";

function routeContext(
  body: Record<string, unknown>,
  headers: Record<string, string | string[]> = {
    [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
  }
) {
  const req = { body, headers } as unknown as Request;
  const res = {} as Response;
  const status = vi.fn().mockReturnValue(res);
  const json = vi.fn().mockReturnValue(res);
  res.status = status;
  res.json = json;
  return { req, res, status, json };
}

/** Every case sends a well-formed image plus `localEvidenceText`; only the
 * evidence text varies per test. Overrides apply to that one image, so
 * existing single-image cases read exactly as they did before W4-R4 wrapped
 * the transport in an `images` array. */
function imageBody(localEvidenceText: string, overrides: Record<string, unknown> = {}) {
  return {
    images: [
      {
        imageBase64: ONE_PIXEL_PNG_BASE64,
        mimeType: "image/png",
        localEvidenceText,
        ...overrides,
      },
    ],
  };
}

/** W4-R4: several screenshots submitted as evidence for one logical order.
 * Each entry supplies its own independent on-device evidence text, exactly
 * as iOS sends it. */
function multiImageBody(
  images: { localEvidenceText: string; imageBase64?: string; mimeType?: string }[]
) {
  return {
    images: images.map((image) => ({
      imageBase64: image.imageBase64 ?? ONE_PIXEL_PNG_BASE64,
      mimeType: image.mimeType ?? "image/png",
      localEvidenceText: image.localEvidenceText,
    })),
  };
}

let consoleLog: ReturnType<typeof vi.spyOn>;
let consoleError: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  process.env[PARTICIPANT_SIGNING_SECRET_ENV] = participantSecretText;
  process.env.OPENAI_API_KEY = "test-key";
  stubVerifiedParticipant();
  callScreenshotProvider.mockReset();
  consoleLog = vi.spyOn(console, "log").mockImplementation(() => undefined);
  consoleError = vi.spyOn(console, "error").mockImplementation(() => undefined);
});

describe("handleScreenshotProposal", () => {
  it("refuses an unverified caller before any image handling or provider call", async () => {
    const { req, res, status, json } = routeContext(imageBody(cartEvidenceText), {});
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(401);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({
        error: expect.objectContaining({
          code: PARTICIPANT_VERIFICATION_REQUIRED_CODE,
        }),
      })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("rejects a malformed body", async () => {
    const { req, res, status, json } = routeContext({ imageBase64: "" });
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({
        error: expect.objectContaining({ code: INVALID_IMAGE_CODE }),
      })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("rejects a body missing localEvidenceText", async () => {
    const { req, res, status, json } = routeContext({
      imageBase64: ONE_PIXEL_PNG_BASE64,
      mimeType: "image/png",
    });
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({
        error: expect.objectContaining({ code: INVALID_IMAGE_CODE }),
      })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("rejects an oversized image without calling the provider", async () => {
    const oversized = Buffer.alloc(6_000_000, 1).toString("base64");
    const { req, res, status, json } = routeContext(
      imageBody(cartEvidenceText, { imageBase64: oversized })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({
        error: expect.objectContaining({ code: INVALID_IMAGE_CODE }),
      })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("rejects a payload whose bytes don't match the claimed mimeType", async () => {
    const notAPng = Buffer.from("this is not a png").toString("base64");
    const { req, res, status, json } = routeContext(
      imageBody(cartEvidenceText, { imageBase64: notAPng })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({
        error: expect.objectContaining({ code: INVALID_IMAGE_CODE }),
      })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  // MARK: - Independent eligibility gates provider transmission

  it("never calls the provider for independently-ineligible evidence, regardless of provider configuration", async () => {
    delete process.env.OPENAI_API_KEY;
    const { req, res, status, json } = routeContext(imageBody(ineligibleEvidenceText));
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(200);
    expect(json).toHaveBeenCalledWith({ eligible: false, proposal: {} });
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("rejects Orders-list/checkout/tracking/non-Grubhub negatives from independent evidence alone", async () => {
    const negatives = [
      "Your Orders Past Orders Completed Reorder",
      "Review your pickup order Place your pickup order",
      "Your order is on the way Track your order",
      "Uber Eats Your order has been delivered",
    ];
    for (const evidence of negatives) {
      callScreenshotProvider.mockClear();
      const { req, res, status, json } = routeContext(imageBody(evidence));
      await handleScreenshotProposal(req, res);
      expect(status).toHaveBeenCalledWith(200);
      expect(json).toHaveBeenCalledWith({ eligible: false, proposal: {} });
      expect(callScreenshotProvider).not.toHaveBeenCalled();
    }
  });

  it("a provider response fabricating supported cart vocabulary in its own output cannot reverse an independent ineligible decision, because the provider is never even called", async () => {
    // The accepted schema no longer accepts a provider transcription field
    // at all, so this configures the mock to return an otherwise-eligible-
    // looking payload; it must never be reached.
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: {
        visibleVenueText: "Palladium",
        foodItems: [{ name: "Fries", quantity: 1, modifiers: [] }],
        mealSwipes: null,
      },
    });
    const { req, res, status, json } = routeContext(imageBody(ineligibleEvidenceText));
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(200);
    expect(json).toHaveBeenCalledWith({ eligible: false, proposal: {} });
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("calls the provider only once independent evidence establishes the cart/bag category", async () => {
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: { visibleVenueText: null, foodItems: [], mealSwipes: null },
    });
    const { req, res, status, json } = routeContext(imageBody(cartEvidenceText));
    await handleScreenshotProposal(req, res);
    expect(callScreenshotProvider).toHaveBeenCalledTimes(1);
    expect(status).toHaveBeenCalledWith(200);
    expect(json).toHaveBeenCalledWith({ eligible: true, proposal: {} });
  });

  it("calls the provider only once independent evidence establishes the detailed-historical-order category", async () => {
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: { visibleVenueText: null, foodItems: [], mealSwipes: null },
    });
    const { req, res, status, json } = routeContext(imageBody(historicalEvidenceText));
    await handleScreenshotProposal(req, res);
    expect(callScreenshotProvider).toHaveBeenCalledTimes(1);
    expect(status).toHaveBeenCalledWith(200);
    expect(json).toHaveBeenCalledWith({ eligible: true, proposal: {} });
  });

  it("fails closed with PROVIDER_UNAVAILABLE when independently eligible but no provider API key is configured", async () => {
    delete process.env.OPENAI_API_KEY;
    const { req, res, status, json } = routeContext(imageBody(cartEvidenceText));
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(503);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({
        error: expect.objectContaining({ code: PROVIDER_UNAVAILABLE_CODE }),
      })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("returns the allowlisted eligible proposal on a well-formed provider response", async () => {
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: {
        visibleVenueText: "Palladium",
        foodItems: [{ name: "Fries", quantity: 1, modifiers: [] }],
        mealSwipes: null,
      },
    });
    // Independent evidence must ground "Palladium" too, not only the
    // provider's own claim — see the venue-grounding suite below.
    const { req, res, status, json } = routeContext(
      imageBody(`${cartEvidenceText} Palladium`)
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(200);
    expect(json).toHaveBeenCalledWith({
      eligible: true,
      proposal: {
        selectedDiningSpot: {
          name: "Palladium",
          address: "Palladium Hall, 140 E 14th St",
        },
        mealItems: ["1 Fries"],
      },
    });
  });

  // MARK: - Vendor location grounded in independent evidence

  it("never selects a vendor from a provider-only short/generic fragment (Burger) when independent evidence names no vendor", async () => {
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: { visibleVenueText: "Burger", foodItems: [], mealSwipes: null },
    });
    const { req, res, status, json } = routeContext(imageBody(cartEvidenceText));
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(200);
    expect(json).toHaveBeenCalledWith({ eligible: true, proposal: {} });
  });

  it("never selects a vendor from a provider-only short/generic fragment (Coffee)", async () => {
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: { visibleVenueText: "Coffee", foodItems: [], mealSwipes: null },
    });
    const { req, res, status, json } = routeContext(imageBody(cartEvidenceText));
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(200);
    expect(json).toHaveBeenCalledWith({ eligible: true, proposal: {} });
  });

  it("omits an ambiguous generic Upstein venue even when independent evidence establishes eligibility and mentions it", async () => {
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: { visibleVenueText: "Upstein", foodItems: [], mealSwipes: null },
    });
    const { req, res, status, json } = routeContext(
      imageBody(`${historicalEvidenceText} Upstein`)
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(200);
    expect(json).toHaveBeenCalledWith({ eligible: true, proposal: {} });
  });

  it("resolves a valid unambiguous venue independently grounded by Vision OCR evidence", async () => {
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: { visibleVenueText: null, foodItems: [], mealSwipes: null },
    });
    const { req, res, status, json } = routeContext(
      imageBody(`${cartEvidenceText} Palladium`)
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(200);
    expect(json).toHaveBeenCalledWith({
      eligible: true,
      proposal: {
        selectedDiningSpot: {
          name: "Palladium",
          address: "Palladium Hall, 140 E 14th St",
        },
      },
    });
  });

  // MARK: - Independent meal-swipe corroboration

  it("drops a provider mealSwipes candidate that the independent evidence does not corroborate, even if the provider also claims a matching count elsewhere in its own output", async () => {
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: { visibleVenueText: null, foodItems: [], mealSwipes: 5 },
    });
    // Independent evidence establishes eligibility (cart) but contains zero
    // "1M" markers — the corroboration source, not the provider's claim.
    const { req, res, status, json } = routeContext(imageBody(cartEvidenceText));
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(200);
    expect(json).toHaveBeenCalledWith({ eligible: true, proposal: {} });
  });

  it("preserves mealSwipes for the real Crave two-swipe case: independent evidence carries exactly two 1M markers matching the provider's candidate", async () => {
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: { visibleVenueText: "Crave NYU", foodItems: [], mealSwipes: 2 },
    });
    const { req, res, status, json } = routeContext(
      imageBody("View order Order information 1 Bowl 1M 1M Crave NYU")
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(200);
    expect(json).toHaveBeenCalledWith({
      eligible: true,
      proposal: {
        selectedDiningSpot: { name: "Crave NYU", address: "John A. Paulson Center, 6th Floor" },
        mealSwipes: 2,
      },
    });
  });

  it("classifies a provider timeout as PROVIDER_UNAVAILABLE without leaking raw provider content", async () => {
    callScreenshotProvider.mockResolvedValue({ ok: false, errorKind: "timeout" });
    const { req, res, status, json } = routeContext(imageBody(cartEvidenceText));
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(503);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({
        error: expect.objectContaining({ code: PROVIDER_UNAVAILABLE_CODE }),
      })
    );
  });

  it("classifies a provider 429 as PROVIDER_UNAVAILABLE", async () => {
    callScreenshotProvider.mockResolvedValue({
      ok: false,
      httpStatus: 429,
      errorKind: "rate_limit",
    });
    const { req, res, status, json } = routeContext(imageBody(cartEvidenceText));
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(503);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({
        error: expect.objectContaining({ code: PROVIDER_UNAVAILABLE_CODE }),
      })
    );
  });

  it("classifies a provider 5xx as PROVIDER_UNAVAILABLE", async () => {
    callScreenshotProvider.mockResolvedValue({
      ok: false,
      httpStatus: 500,
      errorKind: "server",
    });
    const { req, res, status, json } = routeContext(imageBody(cartEvidenceText));
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(503);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({
        error: expect.objectContaining({ code: PROVIDER_UNAVAILABLE_CODE }),
      })
    );
  });

  it("refuses malformed/schema-invalid provider JSON without surfacing it", async () => {
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: { unexpected: "shape" },
    });
    const { req, res, status, json } = routeContext(imageBody(cartEvidenceText));
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(503);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({
        error: expect.objectContaining({ code: PROPOSAL_FAILED_CODE }),
      })
    );
  });

  it("refuses provider output attempting to smuggle a forbidden authority field", async () => {
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: {
        visibleVenueText: null,
        foodItems: [],
        mealSwipes: null,
        action: "submit",
      },
    });
    const { req, res, status, json } = routeContext(imageBody(cartEvidenceText));
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(503);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({
        error: expect.objectContaining({ code: PROPOSAL_FAILED_CODE }),
      })
    );
  });

  it("refuses provider output still carrying the removed visibleText transcription field", async () => {
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: {
        visibleText: "fabricated evidence",
        visibleVenueText: null,
        foodItems: [],
        mealSwipes: null,
      },
    });
    const { req, res, status, json } = routeContext(imageBody(cartEvidenceText));
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(503);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({
        error: expect.objectContaining({ code: PROPOSAL_FAILED_CODE }),
      })
    );
  });

  it("never logs raw provider content or local evidence text, only content-free classification", async () => {
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: {
        visibleVenueText: "Palladium — a very specific literal secret venue text",
        foodItems: [{ name: "Extremely Specific Food Item Name", quantity: 1, modifiers: [] }],
        mealSwipes: null,
      },
    });
    const { req, res } = routeContext(
      imageBody("A very specific literal secret evidence phrase " + cartEvidenceText)
    );
    await handleScreenshotProposal(req, res);
    const loggedText = consoleLog.mock.calls.flat().join(" ");
    const erroredText = consoleError.mock.calls.flat().join(" ");
    expect(loggedText).not.toContain("Extremely Specific Food Item Name");
    expect(loggedText).not.toContain("a very specific literal secret venue text");
    expect(loggedText).not.toContain("A very specific literal secret evidence phrase");
    expect(erroredText).not.toContain("Extremely Specific Food Item Name");
  });
});

describe("registerScreenshotProposalRoute malformed-body parser error handling", () => {
  /**
   * Exercised over real HTTP: `express.json()`'s parse failure is raised by
   * middleware ahead of `handleScreenshotProposal`, so a unit-level call to
   * the handler function alone can never reach `screenshotProposalParserError`
   * — the defect (an unsanitized parser error reaching the global handler,
   * which could log a slice of the raw body) only exists at the mounted-
   * route level.
   */
  let pausedBefore: string | undefined;

  beforeEach(() => {
    pausedBefore = process.env.PUBLIC_ACTIONS_PAUSED;
    // These tests exercise the real registered route, which is gated by
    // `pausePublicAction`; that is orthogonal to what this suite proves, so
    // it is explicitly resumed here rather than left to fail closed.
    process.env.PUBLIC_ACTIONS_PAUSED = "false";
  });

  afterEach(() => {
    if (pausedBefore === undefined) {
      delete process.env.PUBLIC_ACTIONS_PAUSED;
    } else {
      process.env.PUBLIC_ACTIONS_PAUSED = pausedBefore;
    }
  });

  it("answers malformed JSON with the structured INVALID_IMAGE envelope and never logs the sentinel body content", async () => {
    const testApp = express();
    registerScreenshotProposalRoute(testApp);
    const server = createServer(testApp);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));

    const sentinel = "SENTINEL-SCREENSHOT-OCR-CONTENT-MUST-NEVER-BE-LOGGED";
    try {
      const { port } = server.address() as AddressInfo;
      const response = await fetch(
        `http://127.0.0.1:${port}/api/request/screenshot-proposal`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
          },
          // Deliberately malformed: an unterminated JSON object. The
          // sentinel appears in the raw bytes exactly as it would if this
          // were a truncated/corrupted screenshot upload.
          body: `{"imageBase64":"${sentinel}`,
        }
      );

      expect(response.status).toBe(400);
      await expect(response.json()).resolves.toEqual({
        error: {
          code: INVALID_IMAGE_CODE,
          message: INVALID_IMAGE_MESSAGE,
          fields: null,
        },
      });

      const loggedText = consoleLog.mock.calls.flat().join(" ");
      const erroredText = consoleError.mock.calls.flat().join(" ");
      expect(loggedText).not.toContain(sentinel);
      expect(erroredText).not.toContain(sentinel);
      expect(callScreenshotProvider).not.toHaveBeenCalled();
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });

  it("answers an oversized body over the route's own limit the same sanitized way", async () => {
    const testApp = express();
    registerScreenshotProposalRoute(testApp);
    const server = createServer(testApp);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));

    try {
      const { port } = server.address() as AddressInfo;
      const response = await fetch(
        `http://127.0.0.1:${port}/api/request/screenshot-proposal`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            [PARTICIPANT_AUTHORITY_HEADER]: participantAuthority,
          },
          body: JSON.stringify({
            imageBase64: "A".repeat(8_000_000),
            mimeType: "image/png",
            localEvidenceText: "irrelevant",
          }),
        }
      );

      expect(response.status).toBe(400);
      await expect(response.json()).resolves.toEqual({
        error: {
          code: INVALID_IMAGE_CODE,
          message: INVALID_IMAGE_MESSAGE,
          fields: null,
        },
      });
      expect(callScreenshotProvider).not.toHaveBeenCalled();
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });
});

describe("handleScreenshotProposal malformed/truncated image structural validation", () => {
  function pngWithGarbageAfterMagic(): string {
    // Real 4-byte PNG magic, followed by bytes that do not form a valid
    // IHDR chunk header — the "valid prefix + garbage" case a bare
    // magic-byte check cannot catch.
    return Buffer.concat([
      Buffer.from([0x89, 0x50, 0x4e, 0x47]),
      Buffer.from("not a real IHDR chunk, just garbage bytes here"),
    ]).toString("base64");
  }

  function truncatedPng(): string {
    // The real 8-byte PNG signature with nothing after it — far short of a
    // complete IHDR chunk.
    return Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).toString(
      "base64"
    );
  }

  function truncatedJpeg(): string {
    // A real JPEG SOI marker with only a few trailing bytes and, crucially,
    // no EOI trailer — a genuinely truncated stream.
    return Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]).toString("base64");
  }

  /** A complete, correctly-shaped, CRC-valid PNG chunk stream (signature,
   * IHDR, IDAT, IEND) — the same real minimal PNG used elsewhere in this
   * file, reused here as the base for the corruption regressions below. */
  const VALID_PNG_BASE64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";

  /**
   * Test-local CRC-32, independent of the route's own implementation, so
   * these regressions prove the route's semantic IHDR checks actually catch
   * a payload with a *correctly* recomputed CRC — exactly the rereview's
   * point ("an attacker can always recompute a valid CRC for whatever 13
   * bytes they choose") — rather than merely a CRC mismatch.
   */
  const CRC32_TABLE_FOR_TESTS: Uint32Array = (() => {
    const table = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) {
        c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      }
      table[n] = c >>> 0;
    }
    return table;
  })();

  function crc32For(buffer: Buffer): number {
    let crc = 0xffffffff;
    for (let i = 0; i < buffer.length; i++) {
      crc = CRC32_TABLE_FOR_TESTS[(crc ^ buffer[i]!) & 0xff]! ^ (crc >>> 8);
    }
    return (crc ^ 0xffffffff) >>> 0;
  }

  function pngWithCorrectShapeButTamperedIHDRBody(): string {
    // Every structural check a shape-only validator performs still passes:
    // real 8-byte signature, IHDR with the exact required length and type,
    // a following IDAT and terminating IEND. Only the IHDR chunk's 13-byte
    // body has been tampered with, which no real PNG encoder would ever
    // produce alongside its original stored CRC — exactly the case a
    // shape-only ("has the right chunk headers") check cannot catch, and
    // CRC-32 verification does.
    const buffer = Buffer.from(VALID_PNG_BASE64, "base64");
    const tampered = Buffer.from(buffer);
    tampered[20] = tampered[20]! ^ 0xff; // one byte inside the IHDR payload
    return tampered.toString("base64");
  }

  function jpegWithoutFrameOrScanStructure(): string {
    // SOI + APP0 + padding + EOI: passes a bare prefix/suffix/size check,
    // but contains no Start-Of-Frame or Start-Of-Scan segment at all — no
    // real JPEG encoder produces image data without them. This is what the
    // prior implementation incorrectly accepted as "genuinely valid."
    return Buffer.concat([
      Buffer.from([0xff, 0xd8]), // SOI
      Buffer.from([0xff, 0xe0, 0x00, 0x10]), // APP0 marker + length
      Buffer.from("JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"), // APP0 payload (14 bytes)
      Buffer.alloc(80, 0x00), // padding, still no SOF/SOS anywhere
      Buffer.from([0xff, 0xd9]), // EOI
    ]).toString("base64");
  }

  /**
   * A structurally plausible but hand-assembled JPEG: real SOI, APP0, SOF0
   * (1x1 grayscale baseline) frame header, SOS scan header, arbitrary scan
   * bytes, and EOI — with correct marker/length framing throughout, but no
   * Huffman tables (`DHT`) and scan bytes that are not real entropy-coded
   * data. This is deliberately NOT claimed to be decodable by a real JPEG
   * decoder (rereview finding: an earlier version of this fixture was
   * mislabeled "genuinely valid" while failing to decode in ImageIO). It
   * exists only as a byte-level tamperable base for the malformed-SOF/SOS
   * regressions below, which need precise control over specific field
   * values — the actual "accepts a real image" proof uses
   * `REAL_DECODABLE_JPEG_BASE64` instead, further down.
   */
  function syntheticallyShapedJpeg(overrides: {
    sof0?: Buffer;
    sos?: Buffer;
  } = {}): Buffer {
    const soi = Buffer.from([0xff, 0xd8]);
    const app0 = Buffer.from([
      0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00,
      0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
    ]);
    // SOF0: precision 8, height 1, width 1, 1 component (id 1, sampling
    // 1x1, quant table 0).
    const sof0 =
      overrides.sof0 ??
      Buffer.from([0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00]);
    // SOS: 1 component (selector 1, DC/AC table 0), spectral 0..63, approx 0.
    const sos =
      overrides.sos ??
      Buffer.from([0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00]);
    const scanData = Buffer.alloc(60, 0x00);
    const eoi = Buffer.from([0xff, 0xd9]);
    return Buffer.concat([soi, app0, sof0, sos, scanData, eoi]);
  }

  /**
   * A genuinely valid, real, decodable JPEG — not a hand-assembled marker
   * skeleton. Produced by round-tripping the same 1x1 PNG fixture used
   * elsewhere in this file through macOS's real ImageIO-backed encoder:
   *
   *   sips -s format jpeg tiny.png --out tiny.jpg
   *
   * `sips` itself confirmed the result decodes (`pixelWidth`/`pixelHeight`
   * both report 1), so this fixture is decodable by the same ImageIO stack
   * a real device/simulator uses — not merely structurally plausible bytes.
   * It carries the encoder's normal APP1 (Exif) and APP2 (ICC profile)
   * segments, which this route's walker treats as opaque length-prefixed
   * segments it skips over on the way to the real SOF0/SOS it also
   * contains, exactly as it would for a real screenshot.
   */
  const REAL_DECODABLE_JPEG_BASE64 =
    "/9j/4AAQSkZJRgABAQAASABIAAD/4QBARXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAAAaADAAQAAAABAAAAAQAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/+IRrElDQ19QUk9GSUxFAAEBAAARnGFwcGwCAAAAbW50ckdSQVlYWVogB9wACAAXAA8ALgAPYWNzcEFQUEwAAAAAbm9uZQAAAAAAAAAAAAAAAAAAAAAAAPbWAAEAAAAA0y1hcHBsAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFZGVzYwAAAMAAAAB5ZHNjbQAAATwAAAgaY3BydAAACVgAAAAjd3RwdAAACXwAAAAUa1RSQwAACZAAAAgMZGVzYwAAAAAAAAAfR2VuZXJpYyBHcmF5IEdhbW1hIDIuMiBQcm9maWxlAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAG1sdWMAAAAAAAAAHwAAAAxza1NLAAAALgAAAYRkYURLAAAAOgAAAbJjYUVTAAAAOAAAAex2aVZOAAAAQAAAAiRwdEJSAAAASgAAAmR1a1VBAAAALAAAAq5mckZVAAAAPgAAAtpodUhVAAAANAAAAxh6aFRXAAAAGgAAA0xrb0tSAAAAIgAAA2ZuYk5PAAAAOgAAA4hjc0NaAAAAKAAAA8JoZUlMAAAAJAAAA+pyb1JPAAAAKgAABA5kZURFAAAATgAABDhpdElUAAAATgAABIZzdlNFAAAAOAAABNR6aENOAAAAGgAABQxqYUpQAAAAJgAABSZlbEdSAAAAKgAABUxwdFBPAAAAUgAABXZubE5MAAAAQAAABchlc0VTAAAATAAABgh0aFRIAAAAMgAABlR0clRSAAAAJAAABoZmaUZJAAAARgAABqpockhSAAAAPgAABvBwbFBMAAAASgAABy5hckVHAAAALAAAB3hydVJVAAAAOgAAB6RlblVTAAAAPAAAB94AVgFhAGUAbwBiAGUAYwBuAOEAIABzAGkAdgDhACAAZwBhAG0AYQAgADIALAAyAEcAZQBuAGUAcgBpAHMAawAgAGcAcgDlACAAMgAsADIAIABnAGEAbQBtAGEALQBwAHIAbwBmAGkAbABHAGEAbQBtAGEAIABkAGUAIABnAHIAaQBzAG8AcwAgAGcAZQBuAOgAcgBpAGMAYQAgADIALgAyAEMepQB1ACAAaADsAG4AaAAgAE0A4AB1ACAAeADhAG0AIABDAGgAdQBuAGcAIABHAGEAbQBtAGEAIAAyAC4AMgBQAGUAcgBmAGkAbAAgAEcAZQBuAOkAcgBpAGMAbwAgAGQAYQAgAEcAYQBtAGEAIABkAGUAIABDAGkAbgB6AGEAcwAgADIALAAyBBcEMAQzBDAEOwRMBD0EMAAgAEcAcgBhAHkALQQzBDAEPAQwACAAMgAuADIAUAByAG8AZgBpAGwAIABnAOkAbgDpAHIAaQBxAHUAZQAgAGcAcgBpAHMAIABnAGEAbQBtAGEAIAAyACwAMgDBAGwAdABhAGwA4QBuAG8AcwAgAHMAegD8AHIAawBlACAAZwBhAG0AbQBhACAAMgAuADKQGnUocHCWjlFJXqYAMgAuADKCcl9pY8+P8Md8vBgAINaMwMkAIKwQucgAIAAyAC4AMgAg1QS4XNMMx3wARwBlAG4AZQByAGkAcwBrACAAZwByAOUAIABnAGEAbQBtAGEAIAAyACwAMgAtAHAAcgBvAGYAaQBsAE8AYgBlAGMAbgDhACABYQBlAGQA4QAgAGcAYQBtAGEAIAAyAC4AMgXSBdAF3gXUACAF0AXkBdUF6AAgBdsF3AXcBdkAIAAyAC4AMgBHAGEAbQBhACAAZwByAGkAIABnAGUAbgBlAHIAaQBjAQMAIAAyACwAMgBBAGwAbABnAGUAbQBlAGkAbgBlAHMAIABHAHIAYQB1AHMAdAB1AGYAZQBuAC0AUAByAG8AZgBpAGwAIABHAGEAbQBtAGEAIAAyACwAMgBQAHIAbwBmAGkAbABvACAAZwByAGkAZwBpAG8AIABnAGUAbgBlAHIAaQBjAG8AIABkAGUAbABsAGEAIABnAGEAbQBtAGEAIAAyACwAMgBHAGUAbgBlAHIAaQBzAGsAIABnAHIA5QAgADIALAAyACAAZwBhAG0AbQBhAHAAcgBvAGYAaQBsZm6QGnBwXqZ8+2VwADIALgAyY8+P8GWHTvZOAIIsMLAw7DCkMKww8zDeACAAMgAuADIAIDDXMO0w1TChMKQw6wOTA7UDvQO5A7oDzAAgA5MDugPBA7kAIAOTA6wDvAO8A7EAIAAyAC4AMgBQAGUAcgBmAGkAbAAgAGcAZQBuAOkAcgBpAGMAbwAgAGQAZQAgAGMAaQBuAHoAZQBuAHQAbwBzACAAZABhACAARwBhAG0AbQBhACAAMgAsADIAQQBsAGcAZQBtAGUAZQBuACAAZwByAGkAagBzACAAZwBhAG0AbQBhACAAMgAsADIALQBwAHIAbwBmAGkAZQBsAFAAZQByAGYAaQBsACAAZwBlAG4A6QByAGkAYwBvACAAZABlACAAZwBhAG0AbQBhACAAZABlACAAZwByAGkAcwBlAHMAIAAyACwAMg4jDjEOBw4qDjUOQQ4BDiEOIQ4yDkAOAQ4jDiIOTA4XDjEOSA4nDkQOGwAgADIALgAyAEcAZQBuAGUAbAAgAEcAcgBpACAARwBhAG0AYQAgADIALAAyAFkAbABlAGkAbgBlAG4AIABoAGEAcgBtAGEAYQBuACAAZwBhAG0AbQBhACAAMgAsADIAIAAtAHAAcgBvAGYAaQBpAGwAaQBHAGUAbgBlAHIAaQENAGsAaQAgAEcAcgBhAHkAIABHAGEAbQBtAGEAIAAyAC4AMgAgAHAAcgBvAGYAaQBsAFUAbgBpAHcAZQByAHMAYQBsAG4AeQAgAHAAcgBvAGYAaQBsACAAcwB6AGEAcgBvAVsAYwBpACAAZwBhAG0AbQBhACAAMgAsADIGOgYnBkUGJwAgADIALgAyACAGRAZIBkYAIAYxBkUGJwYvBkoAIAY5BicGRQQeBDEESQQwBE8AIARBBDUEQAQwBE8AIAQzBDAEPAQ8BDAAIAAyACwAMgAtBD8EQAQ+BEQEOAQ7BEwARwBlAG4AZQByAGkAYwAgAEcAcgBhAHkAIABHAGEAbQBtAGEAIAAyAC4AMgAgAFAAcgBvAGYAaQBsAGUAAHRleHQAAAAAQ29weXJpZ2h0IEFwcGxlIEluYy4sIDIwMTIAAFhZWiAAAAAAAADzUQABAAAAARbMY3VydgAAAAAAAAQAAAAABQAKAA8AFAAZAB4AIwAoAC0AMgA3ADsAQABFAEoATwBUAFkAXgBjAGgAbQByAHcAfACBAIYAiwCQAJUAmgCfAKQAqQCuALIAtwC8AMEAxgDLANAA1QDbAOAA5QDrAPAA9gD7AQEBBwENARMBGQEfASUBKwEyATgBPgFFAUwBUgFZAWABZwFuAXUBfAGDAYsBkgGaAaEBqQGxAbkBwQHJAdEB2QHhAekB8gH6AgMCDAIUAh0CJgIvAjgCQQJLAlQCXQJnAnECegKEAo4CmAKiAqwCtgLBAssC1QLgAusC9QMAAwsDFgMhAy0DOANDA08DWgNmA3IDfgOKA5YDogOuA7oDxwPTA+AD7AP5BAYEEwQgBC0EOwRIBFUEYwRxBH4EjASaBKgEtgTEBNME4QTwBP4FDQUcBSsFOgVJBVgFZwV3BYYFlgWmBbUFxQXVBeUF9gYGBhYGJwY3BkgGWQZqBnsGjAadBq8GwAbRBuMG9QcHBxkHKwc9B08HYQd0B4YHmQesB78H0gflB/gICwgfCDIIRghaCG4IggiWCKoIvgjSCOcI+wkQCSUJOglPCWQJeQmPCaQJugnPCeUJ+woRCicKPQpUCmoKgQqYCq4KxQrcCvMLCwsiCzkLUQtpC4ALmAuwC8gL4Qv5DBIMKgxDDFwMdQyODKcMwAzZDPMNDQ0mDUANWg10DY4NqQ3DDd4N+A4TDi4OSQ5kDn8Omw62DtIO7g8JDyUPQQ9eD3oPlg+zD88P7BAJECYQQxBhEH4QmxC5ENcQ9RETETERTxFtEYwRqhHJEegSBxImEkUSZBKEEqMSwxLjEwMTIxNDE2MTgxOkE8UT5RQGFCcUSRRqFIsUrRTOFPAVEhU0FVYVeBWbFb0V4BYDFiYWSRZsFo8WshbWFvoXHRdBF2UXiReuF9IX9xgbGEAYZRiKGK8Y1Rj6GSAZRRlrGZEZtxndGgQaKhpRGncanhrFGuwbFBs7G2MbihuyG9ocAhwqHFIcexyjHMwc9R0eHUcdcB2ZHcMd7B4WHkAeah6UHr4e6R8THz4faR+UH78f6iAVIEEgbCCYIMQg8CEcIUghdSGhIc4h+yInIlUigiKvIt0jCiM4I2YjlCPCI/AkHyRNJHwkqyTaJQklOCVoJZclxyX3JicmVyaHJrcm6CcYJ0kneierJ9woDSg/KHEooijUKQYpOClrKZ0p0CoCKjUqaCqbKs8rAis2K2krnSvRLAUsOSxuLKIs1y0MLUEtdi2rLeEuFi5MLoIuty7uLyQvWi+RL8cv/jA1MGwwpDDbMRIxSjGCMbox8jIqMmMymzLUMw0zRjN/M7gz8TQrNGU0njTYNRM1TTWHNcI1/TY3NnI2rjbpNyQ3YDecN9c4FDhQOIw4yDkFOUI5fzm8Ofk6Njp0OrI67zstO2s7qjvoPCc8ZTykPOM9Ij1hPaE94D4gPmA+oD7gPyE/YT+iP+JAI0BkQKZA50EpQWpBrEHuQjBCckK1QvdDOkN9Q8BEA0RHRIpEzkUSRVVFmkXeRiJGZ0arRvBHNUd7R8BIBUhLSJFI10kdSWNJqUnwSjdKfUrESwxLU0uaS+JMKkxyTLpNAk1KTZNN3E4lTm5Ot08AT0lPk0/dUCdQcVC7UQZRUFGbUeZSMVJ8UsdTE1NfU6pT9lRCVI9U21UoVXVVwlYPVlxWqVb3V0RXklfgWC9YfVjLWRpZaVm4WgdaVlqmWvVbRVuVW+VcNVyGXNZdJ114XcleGl5sXr1fD19hX7NgBWBXYKpg/GFPYaJh9WJJYpxi8GNDY5dj62RAZJRk6WU9ZZJl52Y9ZpJm6Gc9Z5Nn6Wg/aJZo7GlDaZpp8WpIap9q92tPa6dr/2xXbK9tCG1gbbluEm5rbsRvHm94b9FwK3CGcOBxOnGVcfByS3KmcwFzXXO4dBR0cHTMdSh1hXXhdj52m3b4d1Z3s3gReG54zHkqeYl553pGeqV7BHtje8J8IXyBfOF9QX2hfgF+Yn7CfyN/hH/lgEeAqIEKgWuBzYIwgpKC9INXg7qEHYSAhOOFR4Wrhg6GcobXhzuHn4gEiGmIzokziZmJ/opkisqLMIuWi/yMY4zKjTGNmI3/jmaOzo82j56QBpBukNaRP5GokhGSepLjk02TtpQglIqU9JVflcmWNJaflwqXdZfgmEyYuJkkmZCZ/JpomtWbQpuvnByciZz3nWSd0p5Anq6fHZ+Ln/qgaaDYoUehtqImopajBqN2o+akVqTHpTilqaYapoum/adup+CoUqjEqTepqaocqo+rAqt1q+msXKzQrUStuK4trqGvFq+LsACwdbDqsWCx1rJLssKzOLOutCW0nLUTtYq2AbZ5tvC3aLfguFm40blKucK6O7q1uy67p7whvJu9Fb2Pvgq+hL7/v3q/9cBwwOzBZ8Hjwl/C28NYw9TEUcTOxUvFyMZGxsPHQce/yD3IvMk6ybnKOMq3yzbLtsw1zLXNNc21zjbOts83z7jQOdC60TzRvtI/0sHTRNPG1EnUy9VO1dHWVdbY11zX4Nhk2OjZbNnx2nba+9uA3AXcit0Q3ZbeHN6i3ynfr+A24L3hROHM4lPi2+Nj4+vkc+T85YTmDeaW5x/nqegy6LzpRunQ6lvq5etw6/vshu0R7ZzuKO6070DvzPBY8OXxcvH/8ozzGfOn9DT0wvVQ9d72bfb794r4Gfio+Tj5x/pX+uf7d/wH/Jj9Kf26/kv+3P9t////wAALCAABAAEBAREA/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/9sAQwACAgICAgIDAgIDBQMDAwUGBQUFBQYIBgYGBgYICggICAgICAoKCgoKCgoKDAwMDAwMDg4ODg4PDw8PDw8PDw8P/90ABAAB/9oACAEBAAA/APwDr//Z";

  it("rejects a valid PNG magic prefix followed by structural garbage", async () => {
    const { req, res, status, json } = routeContext(
      imageBody(cartEvidenceText, { imageBase64: pngWithGarbageAfterMagic() })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ error: expect.objectContaining({ code: INVALID_IMAGE_CODE }) })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("rejects a truncated PNG (signature only, no IHDR chunk)", async () => {
    const { req, res, status, json } = routeContext(
      imageBody(cartEvidenceText, { imageBase64: truncatedPng() })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ error: expect.objectContaining({ code: INVALID_IMAGE_CODE }) })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("rejects a truncated JPEG (SOI marker present, no EOI trailer, too short)", async () => {
    const { req, res, status, json } = routeContext(
      imageBody(cartEvidenceText, {
        imageBase64: truncatedJpeg(),
        mimeType: "image/jpeg",
      })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ error: expect.objectContaining({ code: INVALID_IMAGE_CODE }) })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("rejects a PNG that has the exact right chunk shape (signature, IHDR length/type, IDAT, IEND) but a CRC-invalid IHDR body — a shape-only check previously accepted this", async () => {
    const { req, res, status, json } = routeContext(
      imageBody(cartEvidenceText, { imageBase64: pngWithCorrectShapeButTamperedIHDRBody() })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ error: expect.objectContaining({ code: INVALID_IMAGE_CODE }) })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("rejects a JPEG with SOI/APP0/padding/EOI but no real frame (SOF) or scan (SOS) structure — a prefix/suffix-only check previously accepted this", async () => {
    const { req, res, status, json } = routeContext(
      imageBody(cartEvidenceText, {
        imageBase64: jpegWithoutFrameOrScanStructure(),
        mimeType: "image/jpeg",
      })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ error: expect.objectContaining({ code: INVALID_IMAGE_CODE }) })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("rejects invalid base64 (characters outside the base64 alphabet)", async () => {
    const { req, res, status, json } = routeContext(
      imageBody(cartEvidenceText, { imageBase64: "not-valid-base64!!! ***" })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ error: expect.objectContaining({ code: INVALID_IMAGE_CODE }) })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("rejects an unsupported image type even with a well-formed body", async () => {
    const { req, res, status, json } = routeContext(
      imageBody(cartEvidenceText, { mimeType: "image/gif" })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ error: expect.objectContaining({ code: INVALID_IMAGE_CODE }) })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  // MARK: - PNG IHDR semantics

  function pngWithTamperedIhdrField(mutate: (ihdr: Buffer) => void): string {
    const buffer = Buffer.from(VALID_PNG_BASE64, "base64");
    const tampered = Buffer.from(buffer);
    // IHDR's 13-byte payload starts at offset 16 (8 signature + 4 length + 4 type).
    const ihdr = tampered.subarray(16, 29);
    mutate(ihdr);
    // Recompute the CRC over the mutated type+data (offset 12..29) so the
    // chunk-shape/CRC checks pass and only the semantic check can catch this.
    const newCrc = crc32For(tampered.subarray(12, 29));
    tampered.writeUInt32BE(newCrc, 29);
    return tampered.toString("base64");
  }

  it("rejects a CRC-valid PNG whose IHDR declares zero width — the exact rereview proof-of-concept", async () => {
    const imageBase64 = pngWithTamperedIhdrField((ihdr) => ihdr.writeUInt32BE(0, 0));
    const { req, res, status, json } = routeContext(
      imageBody(cartEvidenceText, { imageBase64 })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ error: expect.objectContaining({ code: INVALID_IMAGE_CODE }) })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("rejects a CRC-valid PNG whose IHDR declares zero height", async () => {
    const imageBase64 = pngWithTamperedIhdrField((ihdr) => ihdr.writeUInt32BE(0, 4));
    const { req, res, status, json } = routeContext(
      imageBody(cartEvidenceText, { imageBase64 })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ error: expect.objectContaining({ code: INVALID_IMAGE_CODE }) })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("rejects a CRC-valid PNG with an invalid bit-depth/color-type combination (bit depth 1 with truecolor)", async () => {
    const imageBase64 = pngWithTamperedIhdrField((ihdr) => {
      ihdr[8] = 1; // bit depth
      ihdr[9] = 2; // color type: truecolor (only 8/16 are valid bit depths)
    });
    const { req, res, status, json } = routeContext(
      imageBody(cartEvidenceText, { imageBase64 })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ error: expect.objectContaining({ code: INVALID_IMAGE_CODE }) })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("rejects a CRC-valid PNG with a non-zero compression method", async () => {
    const imageBase64 = pngWithTamperedIhdrField((ihdr) => {
      ihdr[10] = 1;
    });
    const { req, res, status, json } = routeContext(
      imageBody(cartEvidenceText, { imageBase64 })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ error: expect.objectContaining({ code: INVALID_IMAGE_CODE }) })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("rejects a CRC-valid PNG with a non-zero filter method", async () => {
    const imageBase64 = pngWithTamperedIhdrField((ihdr) => {
      ihdr[11] = 1;
    });
    const { req, res, status, json } = routeContext(
      imageBody(cartEvidenceText, { imageBase64 })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ error: expect.objectContaining({ code: INVALID_IMAGE_CODE }) })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("rejects a CRC-valid PNG with an out-of-range interlace method", async () => {
    const imageBase64 = pngWithTamperedIhdrField((ihdr) => {
      ihdr[12] = 7;
    });
    const { req, res, status, json } = routeContext(
      imageBody(cartEvidenceText, { imageBase64 })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ error: expect.objectContaining({ code: INVALID_IMAGE_CODE }) })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  // MARK: - JPEG SOF/SOS payload semantics

  it("rejects a JPEG with an empty (length-2) SOF segment — the exact rereview proof-of-concept", async () => {
    const buffer = Buffer.concat([
      Buffer.from([0xff, 0xd8]), // SOI
      Buffer.from([0xff, 0xc0, 0x00, 0x02]), // SOF, length 2 (no payload)
      Buffer.from([0xff, 0xda, 0x00, 0x02]), // SOS, length 2 (no payload)
      Buffer.alloc(90, 0x00),
      Buffer.from([0xff, 0xd9]), // EOI
    ]);
    const { req, res, status, json } = routeContext(
      imageBody(cartEvidenceText, { imageBase64: buffer.toString("base64"), mimeType: "image/jpeg" })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ error: expect.objectContaining({ code: INVALID_IMAGE_CODE }) })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("rejects a JPEG with an empty (length-2) SOS segment following an otherwise-valid SOF", async () => {
    const buffer = syntheticallyShapedJpeg({
      sos: Buffer.from([0xff, 0xda, 0x00, 0x02]),
    });
    const { req, res, status, json } = routeContext(
      imageBody(cartEvidenceText, { imageBase64: buffer.toString("base64"), mimeType: "image/jpeg" })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ error: expect.objectContaining({ code: INVALID_IMAGE_CODE }) })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("rejects a JPEG whose SOF declares zero width/height", async () => {
    const zeroDimSof = Buffer.from([
      0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00,
    ]); // height = 0
    const buffer = syntheticallyShapedJpeg({ sof0: zeroDimSof });
    const { req, res, status, json } = routeContext(
      imageBody(cartEvidenceText, { imageBase64: buffer.toString("base64"), mimeType: "image/jpeg" })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ error: expect.objectContaining({ code: INVALID_IMAGE_CODE }) })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("rejects a JPEG whose SOF segment length is inconsistent with its declared component count", async () => {
    // Declares 2 components (byte after precision/height/width) but keeps
    // the length field at 11 — only enough room for 1 component descriptor.
    const malformedSof = Buffer.from([
      0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x01, 0x00, 0x01, 0x02, 0x01, 0x11, 0x00,
    ]);
    const buffer = syntheticallyShapedJpeg({ sof0: malformedSof });
    const { req, res, status, json } = routeContext(
      imageBody(cartEvidenceText, { imageBase64: buffer.toString("base64"), mimeType: "image/jpeg" })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ error: expect.objectContaining({ code: INVALID_IMAGE_CODE }) })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("rejects a JPEG whose SOS references more scan components than the frame declared", async () => {
    // SOF declares 1 component; SOS claims 2 scan components.
    const sosTooManyComponents = Buffer.from([
      0xff, 0xda, 0x00, 0x0a, 0x02, 0x01, 0x00, 0x02, 0x00, 0x00, 0x3f, 0x00,
    ]);
    const buffer = syntheticallyShapedJpeg({ sos: sosTooManyComponents });
    const { req, res, status, json } = routeContext(
      imageBody(cartEvidenceText, { imageBase64: buffer.toString("base64"), mimeType: "image/jpeg" })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ error: expect.objectContaining({ code: INVALID_IMAGE_CODE }) })
    );
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  // MARK: - Positive controls

  it("accepts a genuinely valid, complete PNG and proceeds to the provider", async () => {
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: { visibleVenueText: null, foodItems: [], mealSwipes: null },
    });
    const { req, res, status } = routeContext(imageBody(cartEvidenceText));
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(200);
    expect(callScreenshotProvider).toHaveBeenCalledTimes(1);
  });

  it("accepts a genuinely valid, real, ImageIO-decodable JPEG (not a hand-assembled marker skeleton) and proceeds to the provider", async () => {
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: { visibleVenueText: null, foodItems: [], mealSwipes: null },
    });
    const { req, res, status } = routeContext(
      imageBody(cartEvidenceText, {
        imageBase64: REAL_DECODABLE_JPEG_BASE64,
        mimeType: "image/jpeg",
      })
    );
    await handleScreenshotProposal(req, res);
    expect(status).toHaveBeenCalledWith(200);
    expect(callScreenshotProvider).toHaveBeenCalledTimes(1);
  });
});

describe("W4-R4 multi-screenshot evidence for one logical order", () => {
  it.each([1, 2, 3, 4, 5])(
    "accepts %d eligible screenshots and analyzes them in one provider call",
    async (count) => {
      process.env.OPENAI_API_KEY = "test-key";
      callScreenshotProvider.mockResolvedValue({
        ok: true,
        rawJson: {
          visibleVenueText: null,
          foodItems: [{ name: "Fries", quantity: 1, modifiers: [] }],
          mealSwipes: null,
        },
      });
      const context = routeContext(
        multiImageBody(
          Array.from({ length: count }, () => ({
            localEvidenceText: cartEvidenceText,
          }))
        )
      );

      await handleScreenshotProposal(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(200);
      // One order, one analysis — never one call per screenshot.
      expect(callScreenshotProvider).toHaveBeenCalledTimes(1);
      const [options] = callScreenshotProvider.mock.calls[0] as [
        { images: unknown[] },
      ];
      expect(options.images).toHaveLength(count);
    }
  );

  it("refuses a sixth screenshot deterministically, before any provider transfer", async () => {
    process.env.OPENAI_API_KEY = "test-key";
    const context = routeContext(
      multiImageBody(
        Array.from({ length: 6 }, () => ({
          localEvidenceText: cartEvidenceText,
        }))
      )
    );

    await handleScreenshotProposal(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    // Refused outright rather than silently trimmed to five, so a requester
    // is never told an analysis covered evidence it never received.
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("refuses an empty image set", async () => {
    const context = routeContext({ images: [] });

    await handleScreenshotProposal(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("forwards only the independently eligible screenshots, and their evidence", async () => {
    process.env.OPENAI_API_KEY = "test-key";
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: {
        visibleVenueText: null,
        foodItems: [{ name: "Fries", quantity: 1, modifiers: [] }],
        mealSwipes: null,
      },
    });
    const eligibleImage = ONE_PIXEL_PNG_BASE64;
    const context = routeContext({
      images: [
        {
          imageBase64: eligibleImage,
          mimeType: "image/png",
          localEvidenceText: cartEvidenceText,
        },
        {
          imageBase64: eligibleImage,
          mimeType: "image/png",
          localEvidenceText: ineligibleEvidenceText,
        },
        {
          imageBase64: eligibleImage,
          mimeType: "image/png",
          localEvidenceText: historicalEvidenceText,
        },
      ],
    });

    await handleScreenshotProposal(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(200);
    const [options] = callScreenshotProvider.mock.calls[0] as [
      { images: unknown[] },
    ];
    // The ineligible screenshot's bytes never reach the provider, exactly as
    // W4-S1's single-image gate already guaranteed.
    expect(options.images).toHaveLength(2);
  });

  it("answers ineligible, and calls no provider, when no screenshot is eligible", async () => {
    process.env.OPENAI_API_KEY = "test-key";
    const context = routeContext(
      multiImageBody([
        { localEvidenceText: ineligibleEvidenceText },
        { localEvidenceText: ineligibleEvidenceText },
      ])
    );

    await handleScreenshotProposal(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(200);
    expect(context.json).toHaveBeenCalledWith({
      eligible: false,
      proposal: {},
    });
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("refuses the whole set when any one image is structurally malformed", async () => {
    process.env.OPENAI_API_KEY = "test-key";
    const context = routeContext({
      images: [
        {
          imageBase64: ONE_PIXEL_PNG_BASE64,
          mimeType: "image/png",
          localEvidenceText: cartEvidenceText,
        },
        {
          imageBase64: "not-valid-base64!!! ***",
          mimeType: "image/png",
          localEvidenceText: cartEvidenceText,
        },
      ],
    });

    await handleScreenshotProposal(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(callScreenshotProvider).not.toHaveBeenCalled();
  });

  it("proposes an item once when overlapping screenshots are reported once", async () => {
    process.env.OPENAI_API_KEY = "test-key";
    // Two overlapping screenshots of one cart, reported by the provider as
    // the one order they describe.
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: {
        visibleVenueText: null,
        foodItems: [
          { name: "Burger", quantity: 1, modifiers: ["No Bag"] },
          { name: "Fries", quantity: 1, modifiers: [] },
        ],
        mealSwipes: null,
      },
    });
    const context = routeContext(
      multiImageBody([
        { localEvidenceText: cartEvidenceText },
        { localEvidenceText: cartEvidenceText },
      ])
    );

    await handleScreenshotProposal(context.req, context.res);

    const [body] = context.json.mock.calls[0] as [
      { eligible: boolean; proposal: { mealItems?: string[] } },
    ];
    expect(body.eligible).toBe(true);
    expect(body.proposal.mealItems).toEqual(["1 Burger (No Bag)", "1 Fries"]);
  });

  it("does not duplicate or collapse an identical line repeated across several screenshots", async () => {
    process.env.OPENAI_API_KEY = "test-key";
    // The same burger line twice from two screenshots: overlap of one burger
    // and an order of two burgers look exactly alike, so no meal items and
    // no swipe count are proposed — never two burgers, never one.
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: {
        visibleVenueText: null,
        foodItems: [
          { name: "Burger", quantity: 1, modifiers: ["No Bag"] },
          { name: "Fries", quantity: 1, modifiers: [] },
          { name: " burger ", quantity: 1, modifiers: ["no bag"] },
        ],
        mealSwipes: 2,
      },
    });
    const context = routeContext(
      multiImageBody([
        { localEvidenceText: `${cartEvidenceText} Palladium 1M` },
        { localEvidenceText: `${cartEvidenceText} Palladium 1M` },
      ])
    );

    await handleScreenshotProposal(context.req, context.res);

    const [body] = context.json.mock.calls[0] as [
      {
        eligible: boolean;
        proposal: {
          mealItems?: string[];
          mealSwipes?: number;
          selectedDiningSpot?: { name: string };
        };
      },
    ];
    expect(body.eligible).toBe(true);
    expect(body.proposal.mealItems).toBeUndefined();
    expect(body.proposal.mealSwipes).toBeUndefined();
    // Location does not depend on the item question and still survives.
    expect(body.proposal.selectedDiningSpot?.name).toBe("Palladium");
  });

  it("keeps genuinely repeated identical lines when only one screenshot is analyzed", async () => {
    process.env.OPENAI_API_KEY = "test-key";
    // One screenshot cannot overlap itself: two identical lines on it are two
    // ordered burgers. An ineligible second image is filtered before the
    // provider and does not count as evidence.
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: {
        visibleVenueText: null,
        foodItems: [
          { name: "Burger", quantity: 1, modifiers: ["No Bag"] },
          { name: "Burger", quantity: 1, modifiers: ["No Bag"] },
        ],
        mealSwipes: 2,
      },
    });
    const context = routeContext(
      multiImageBody([
        { localEvidenceText: `${cartEvidenceText} 1M 1M` },
        { localEvidenceText: ineligibleEvidenceText },
      ])
    );

    await handleScreenshotProposal(context.req, context.res);

    const [options] = callScreenshotProvider.mock.calls[0] as [
      { images: unknown[] },
    ];
    expect(options.images).toHaveLength(1);
    const [body] = context.json.mock.calls[0] as [
      { proposal: { mealItems?: string[]; mealSwipes?: number } },
    ];
    expect(body.proposal.mealItems).toEqual([
      "1 Burger (No Bag)",
      "1 Burger (No Bag)",
    ]);
    expect(body.proposal.mealSwipes).toBe(2);
  });

  it("keeps genuinely different items that merely resemble each other", async () => {
    process.env.OPENAI_API_KEY = "test-key";
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: {
        visibleVenueText: null,
        foodItems: [
          { name: "Burger", quantity: 1, modifiers: ["No Bag"] },
          { name: "Burger", quantity: 2, modifiers: ["No Bag"] },
          { name: "Burger", quantity: 1, modifiers: ["No Side"] },
        ],
        mealSwipes: null,
      },
    });
    const context = routeContext(
      multiImageBody([{ localEvidenceText: cartEvidenceText }])
    );

    await handleScreenshotProposal(context.req, context.res);

    const [body] = context.json.mock.calls[0] as [
      { proposal: { mealItems?: string[] } },
    ];
    // Deduplication is exact-identity, never fuzzy: a different quantity or a
    // different modifier is a different item, and collapsing them would be a
    // guess about what the requester meant.
    expect(body.proposal.mealItems).toEqual([
      "1 Burger (No Bag)",
      "2 Burger (No Bag)",
      "1 Burger (No Side)",
    ]);
  });

  it("drops a meal-swipe candidate that overlapping evidence double-counts", async () => {
    process.env.OPENAI_API_KEY = "test-key";
    // Both screenshots show the same single `1M` marker. Combined evidence
    // therefore carries two markers against a candidate of one.
    const oneMarkerEvidence = `${cartEvidenceText} 1M`;
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: {
        visibleVenueText: null,
        foodItems: [{ name: "Burger", quantity: 1, modifiers: [] }],
        mealSwipes: 1,
      },
    });
    const context = routeContext(
      multiImageBody([
        { localEvidenceText: oneMarkerEvidence },
        { localEvidenceText: oneMarkerEvidence },
      ])
    );

    await handleScreenshotProposal(context.req, context.res);

    const [body] = context.json.mock.calls[0] as [
      { proposal: { mealSwipes?: number; mealItems?: string[] } },
    ];
    // Ambiguous cross-screenshot evidence stays ambiguous: the requester
    // chooses the count rather than receiving a guessed one.
    expect(body.proposal.mealSwipes).toBeUndefined();
    // The safe part of the proposal still survives independently.
    expect(body.proposal.mealItems).toEqual(["1 Burger"]);
  });

  it("omits location when screenshots ground conflicting venues", async () => {
    process.env.OPENAI_API_KEY = "test-key";
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: {
        visibleVenueText: null,
        foodItems: [{ name: "Burger", quantity: 1, modifiers: [] }],
        mealSwipes: null,
      },
    });
    const context = routeContext(
      multiImageBody([
        { localEvidenceText: `${cartEvidenceText} Palladium` },
        { localEvidenceText: `${cartEvidenceText} Cafe 370` },
      ])
    );

    await handleScreenshotProposal(context.req, context.res);

    const [body] = context.json.mock.calls[0] as [
      { proposal: { selectedDiningSpot?: unknown } },
    ];
    // Two screenshots naming two different dining spots is a conflict, not a
    // majority vote: the proposal omits location rather than picking one.
    expect(body.proposal.selectedDiningSpot).toBeUndefined();
  });

  it("never proposes a menu path, order details, or a Dining Dollar amount", async () => {
    process.env.OPENAI_API_KEY = "test-key";
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: {
        visibleVenueText: null,
        foodItems: [{ name: "Burger", quantity: 1, modifiers: [] }],
        mealSwipes: null,
        menuPath: "dining-dollars",
        estimatedDiningDollarsCents: 1_850,
      },
    });
    const context = routeContext(
      multiImageBody([{ localEvidenceText: cartEvidenceText }])
    );

    await handleScreenshotProposal(context.req, context.res);

    // A provider attempting to select the requester's menu path or invent an
    // amount is refused wholesale by the forbidden-field gate — the proposal
    // is not merely stripped of those keys.
    expect(context.status).toHaveBeenCalledWith(503);
    const [body] = context.json.mock.calls[0] as [
      { error: { code: string } },
    ];
    expect(body.error.code).toBe("SCREENSHOT_PROPOSAL_FAILED");
  });

  it("creates no request, consumes no quota, and sends no notification on the multi-image path", async () => {
    process.env.OPENAI_API_KEY = "test-key";
    callScreenshotProvider.mockResolvedValue({
      ok: true,
      rawJson: {
        visibleVenueText: null,
        foodItems: [{ name: "Burger", quantity: 1, modifiers: [] }],
        mealSwipes: null,
      },
    });
    const context = routeContext(
      multiImageBody([
        { localEvidenceText: cartEvidenceText },
        { localEvidenceText: historicalEvidenceText },
      ])
    );

    await handleScreenshotProposal(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(200);
    // The route's module graph can never reach request creation or D1; this
    // asserts the response vocabulary stays analysis-only alongside it.
    const [body] = context.json.mock.calls[0] as [Record<string, unknown>];
    expect(Object.keys(body).sort()).toEqual(["eligible", "proposal"]);
    expect(JSON.stringify(body)).not.toMatch(
      /operationId|requestId|createRequest|claimToken/
    );
  });
});
