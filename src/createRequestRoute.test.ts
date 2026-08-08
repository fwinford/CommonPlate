import express, { type Request, type Response } from "express";
import { readFileSync, readdirSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import mongoose from "mongoose";
import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";

const { resendSend, notifySubscribersForRequest } = vi.hoisted(() => ({
  resendSend: vi.fn(),
  notifySubscribersForRequest: vi.fn(),
}));

vi.mock("resend", () => ({
  Resend: class {
    emails = { send: resendSend };
  },
}));

vi.mock("./notifySubscribers.js", () => ({
  notifySubscribersForRequest,
}));

import { Installation, Request as MealRequest } from "../models/db.js";
import {
  createRequest,
  createRequestRateLimiter,
} from "./createRequestRoute.js";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
import { SUPPORTED_VENDORS } from "./supportedVendors.js";

const requestId = new mongoose.Types.ObjectId("64b000000000000000000001");
/** Frozen backend creation time; the route's `new Date()` resolves to this. */
const createdAt = new Date("2026-07-28T16:00:00.000Z");
/** Three hours after `createdAt` — the W3-R1 ASAP lifetime. */
const asapExpiresAt = new Date("2026-07-28T19:00:00.000Z");
/** The one timing value a scheduled canonical payload carries. */
const scheduledStart = new Date("2026-07-28T17:00:00.000Z");
/** Three hours after `scheduledStart`, derived by the backend. */
const scheduledExpiresAt = new Date("2026-07-28T20:00:00.000Z");

function canonicalAsap(overrides: Record<string, unknown> = {}) {
  return {
    vendor: "  Palladium  ",
    food: "  Vegetable rice bowl  ",
    pickupName: "  Requester Private Name  ",
    email: "  REQUESTER@NYU.EDU  ",
    timing: "asap",
    ...overrides,
  };
}

function canonicalScheduled(overrides: Record<string, unknown> = {}) {
  return {
    vendor: "Palladium",
    food: "Vegetable rice bowl",
    pickupName: "Requester Private Name",
    email: "requester@nyu.edu",
    timing: "scheduled",
    windowStart: "2026-07-28T17:00:00.000Z",
    ...overrides,
  };
}

function routeContext(body: unknown) {
  const req = { body } as Request;
  const res = {} as Response;
  const status = vi.fn().mockReturnValue(res);
  const json = vi.fn().mockReturnValue(res);
  res.status = status;
  res.json = json;
  return { req, res, status, json };
}

function persistedDocument(input: Record<string, unknown>) {
  return {
    _id: requestId,
    ...input,
    status: "open",
    createdAt,
    updatedAt: createdAt,
    // Deliberately no `expiresAt` override: the persisted document echoes
    // whatever the route wrote, so the response assertions prove the canonical
    // backend expiration rather than a fixture constant.
    pickupName: input.pickupName,
    email: input.email,
    claimToken: "private-claim-token",
    orderNumber: "private-order-number",
    notificationStatus: "private-notification-state",
    __v: 0,
  };
}

let countDocuments: ReturnType<typeof vi.spyOn>;
let createDocument: ReturnType<typeof vi.spyOn>;
let consoleError: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  // Only `Date` is faked, so the route's single backend creation-time value is
  // deterministic without a clock abstraction and without stalling timers.
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(createdAt);

  resendSend.mockReset();
  resendSend.mockResolvedValue({ data: { id: "email-id" }, error: null });
  notifySubscribersForRequest.mockReset();
  notifySubscribersForRequest.mockResolvedValue(undefined);

  countDocuments = vi
    .spyOn(MealRequest, "countDocuments")
    .mockResolvedValue(0 as never);
  createDocument = vi
    .spyOn(MealRequest, "create")
    .mockImplementation(async (input) =>
      persistedDocument(
        input as unknown as Record<string, unknown>
      ) as unknown as Awaited<ReturnType<typeof MealRequest.create>>
    ) as ReturnType<typeof vi.spyOn>;
  consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
});

describe("POST /api/request validation and persistence", () => {
  it("persists a valid canonical ASAP request with trimmed private input", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(createDocument).toHaveBeenCalledWith({
      vendor: "Palladium",
      food: "Vegetable rice bowl",
      pickupName: "Requester Private Name",
      email: "requester@nyu.edu",
      pickupWindowText: "ASAP (available for the next 3 hours)",
      windowStart: undefined,
      windowEnd: undefined,
      status: "open",
      visibleFrom: createdAt,
      expiresAt: asapExpiresAt,
      deleteAt: asapExpiresAt,
    });
    expect(context.status).toHaveBeenCalledWith(201);
  });

  it.each([
    {
      windowStart: "2026-07-28T17:00:00.000Z",
    },
    {
      windowEnd: "2026-07-28T18:00:00.000Z",
    },
    {
      windowStart: "2026-07-28T17:00:00.000Z",
      windowEnd: "2026-07-28T18:00:00.000Z",
    },
  ])("rejects canonical ASAP window fields", async (window) => {
    const context = routeContext(canonicalAsap(window));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "INVALID_REQUEST",
        message: "Invalid request payload",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("persists a valid canonical scheduled request and generates New York display text", async () => {
    const context = routeContext(canonicalScheduled());

    await createRequest(context.req, context.res);

    expect(createDocument).toHaveBeenCalledWith(
      expect.objectContaining({
        // The advertised window is the availability window: one start, and an
        // end the backend derived rather than one a client asserted.
        pickupWindowText: "Jul 28, 1:00 PM – 4:00 PM",
        windowStart: scheduledStart,
        windowEnd: scheduledExpiresAt,
        visibleFrom: scheduledStart,
        expiresAt: scheduledExpiresAt,
        deleteAt: scheduledExpiresAt,
      })
    );
    expect(context.status).toHaveBeenCalledWith(201);
  });

  it("refuses a canonical scheduled payload that supplies its own windowEnd", async () => {
    // The requester chooses a start; the end is not theirs to state. `.strict()`
    // refuses it outright rather than accepting and quietly discarding it.
    const context = routeContext(
      canonicalScheduled({ windowEnd: "2026-07-28T18:00:00.000Z" })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "INVALID_REQUEST",
        message: "Invalid request payload",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
  });

  it.each(["vendor", "food", "pickupName", "email"])(
    "rejects a missing or blank required %s",
    async (field) => {
      const context = routeContext(
        canonicalAsap({ [field]: field === "vendor" ? "   " : undefined })
      );

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(400);
      expect(context.json).toHaveBeenCalledWith({
        error: {
          code: "INVALID_REQUEST",
          message: "Invalid request payload",
        },
      });
      expect(createDocument).not.toHaveBeenCalled();
      expect(resendSend).not.toHaveBeenCalled();
      expect(notifySubscribersForRequest).not.toHaveBeenCalled();
    }
  );

  it("rejects an invalid email", async () => {
    const context = routeContext(canonicalAsap({ email: "not-an-email" }));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("keeps the generic payload message for a missing or blank email", async () => {
    // A field that is absent or empty is a malformed payload, not an address
    // problem, so it stays with `vendor`, `food`, and `pickupName` rather than
    // being answered with advice about NYU domains.
    for (const email of [undefined, "   "]) {
      const context = routeContext(canonicalAsap({ email }));

      await createRequest(context.req, context.res);

      expect(context.json).toHaveBeenCalledWith({
        error: {
          code: "INVALID_REQUEST",
          message: "Invalid request payload",
        },
      });
    }

    expect(createDocument).not.toHaveBeenCalled();
  });

  it.each(["soon", "", 7, null])(
    "rejects invalid canonical timing value %j",
    async (timing) => {
      const context = routeContext(canonicalAsap({ timing }));

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(400);
      expect(createDocument).not.toHaveBeenCalled();
    }
  );

  it("rejects a scheduled request with no start", async () => {
    // `windowStart` is now the whole timing input, so its absence leaves the
    // backend nothing to derive visibility or expiration from.
    const context = routeContext(canonicalScheduled({ windowStart: undefined }));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it.each([
    { windowStart: "not-a-timestamp" },
    { windowStart: "2026-07-28T17:00:00.000" },
    { windowStart: 1_780_000_000_000 },
  ])("rejects a scheduled start that is not an offset ISO timestamp", async (window) => {
    const context = routeContext(canonicalScheduled(window));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it.each([
    ["id", "client-id"],
    ["_id", "64b000000000000000000002"],
    ["status", "placed"],
    ["createdAt", "2020-01-01T00:00:00.000Z"],
    ["updatedAt", "2020-01-01T00:00:00.000Z"],
    ["expiresAt", "2030-01-01T00:00:00.000Z"],
    ["claimToken", "client-claim"],
    ["orderNumber", "client-order"],
    ["pickupWindowText", "client display text"],
  ])("rejects canonical client-supplied field %s", async (field, value) => {
    const context = routeContext(canonicalAsap({ [field]: value }));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("returns a canonical public wrapper with backend values and no private fields", async () => {
    const context = routeContext(canonicalScheduled());

    await createRequest(context.req, context.res);

    const body = JSON.parse(
      JSON.stringify(context.json.mock.calls[0][0])
    ) as Record<string, Record<string, unknown>>;
    expect(Object.keys(body)).toEqual(["request"]);
    expect(body.request).toEqual({
      id: requestId.toString(),
      vendor: "Palladium",
      food: "Vegetable rice bowl",
      pickupWindowText: "Jul 28, 1:00 PM – 4:00 PM",
      windowStart: "2026-07-28T17:00:00.000Z",
      windowEnd: "2026-07-28T20:00:00.000Z",
      status: "open",
      createdAt: "2026-07-28T16:00:00.000Z",
      expiresAt: "2026-07-28T20:00:00.000Z",
    });
    expect(body.request).not.toHaveProperty("email");
    expect(body.request).not.toHaveProperty("pickupName");
    expect(body.request).not.toHaveProperty("_id");
    expect(body.request).not.toHaveProperty("claimToken");
    expect(body.request).not.toHaveProperty("orderNumber");
    expect(body.request).not.toHaveProperty("notificationStatus");
    expect(body.request).not.toHaveProperty("deleteAt");
    expect(body.request).not.toHaveProperty("claimedAt");
    expect(body.request).not.toHaveProperty("claimExpiresAt");
    expect(body.request).not.toHaveProperty("claimExtendedAt");
    expect(body.request).not.toHaveProperty("claimTokenDigest");

    const persistedInput = createDocument.mock.calls[0][0] as Record<
      string,
      unknown
    >;
    expect(persistedInput).not.toHaveProperty("_id");
    expect(persistedInput.status).toBe("open");
    expect(persistedInput).not.toHaveProperty("createdAt");
    // `visibleFrom` and `expiresAt` are written by the backend, unlike the
    // fields above, which stay owned by Mongo/Mongoose. Neither is projected
    // onto the public body beyond the instants already listed there.
    expect(persistedInput.visibleFrom).toEqual(scheduledStart);
    expect(persistedInput.expiresAt).toEqual(scheduledExpiresAt);
    expect(persistedInput.deleteAt).toEqual(persistedInput.expiresAt);
  });
});

describe("POST /api/request NYU requester-email allowlist", () => {
  /**
   * The helper matrix itself is proved once in `allowedEmailDomains.test.ts`.
   * These cases prove the route reaches that decision, on both create shapes,
   * with the accepted envelope, and strictly before any side effect.
   */
  const NYU_MESSAGE =
    "Enter an NYU email address ending in @nyu.edu or @stern.nyu.edu.";

  function legacyWeb(email: string) {
    return {
      vendor: "Palladium",
      food: "Vegetable rice bowl",
      pickupName: "Requester Private Name",
      email,
      pickupWindowText: "Legacy display",
    };
  }

  it.each([
    ["  REQUESTER@NYU.EDU  ", "requester@nyu.edu"],
    ["student@stern.nyu.edu", "student@stern.nyu.edu"],
    ["\tStudent@Stern.NYU.EDU\n", "student@stern.nyu.edu"],
    ["requester+food@nyu.edu", "requester+food@nyu.edu"],
  ])("accepts and normalizes %s", async (email, stored) => {
    const context = routeContext(canonicalAsap({ email }));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(createDocument).toHaveBeenCalledWith(
      expect.objectContaining({ email: stored })
    );
    // The normalized address is also what the daily abuse-control count and
    // the requester confirmation email use.
    expect(countDocuments).toHaveBeenCalledWith(
      expect.objectContaining({ email: stored })
    );
    expect(resendSend).toHaveBeenCalledWith(
      expect.objectContaining({ to: stored })
    );
  });

  it.each([
    "not-an-email",
    "requester@",
    "@nyu.edu",
    "requester@@nyu.edu",
    "requester @nyu.edu",
    "requester@gmail.com",
    "requester@example.edu",
    "requester@law.nyu.edu",
    "requester@sps.nyu.edu",
    "requester@nyu.edu.fake",
    "requester@fake-nyu.edu",
    "requester@nyu.edu.example.com",
    "requester@notnyu.edu",
    "requester@nyu.education",
  ])("refuses %s with the NYU envelope and no side effect", async (email) => {
    const context = routeContext(canonicalAsap({ email }));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: { code: "INVALID_EMAIL", message: NYU_MESSAGE },
    });
    // The refusal precedes every side effect: no daily-limit read, no
    // document, no requester email, no helper alert.
    expect(countDocuments).not.toHaveBeenCalled();
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("applies the same rule to the canonical scheduled and legacy web shapes", async () => {
    const scheduled = routeContext(
      canonicalScheduled({ email: "requester@gmail.com" })
    );
    await createRequest(scheduled.req, scheduled.res);

    const legacy = routeContext(legacyWeb("requester@law.nyu.edu"));
    await createRequest(legacy.req, legacy.res);

    for (const context of [scheduled, legacy]) {
      expect(context.status).toHaveBeenCalledWith(400);
      expect(context.json).toHaveBeenCalledWith({
        error: { code: "INVALID_EMAIL", message: NYU_MESSAGE },
      });
    }
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();

    const allowedLegacy = routeContext(legacyWeb("requester@stern.nyu.edu"));
    await createRequest(allowedLegacy.req, allowedLegacy.res);

    expect(allowedLegacy.status).toHaveBeenCalledWith(201);
  });

  it("does not match an allowed domain by suffix or substring", async () => {
    for (const email of [
      "requester@evil-nyu.edu",
      "requester@nyu.edu.evil.test",
      "requester@stern.nyu.edu.evil.test",
    ]) {
      const context = routeContext(canonicalAsap({ email }));

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(400);
      expect(context.json).toHaveBeenCalledWith({
        error: { code: "INVALID_EMAIL", message: NYU_MESSAGE },
      });
    }

    expect(createDocument).not.toHaveBeenCalled();
  });

  it("still reports another invalid field as a payload error", async () => {
    // Precedence is unchanged: the allowlist runs last and can only refuse a
    // payload that would otherwise have been created, so a request that is
    // wrong in more than one way keeps the message it has always returned.
    for (const body of [
      canonicalAsap({ email: "requester@gmail.com", vendor: "   " }),
      canonicalAsap({ email: "requester@gmail.com", timing: "soon" }),
      canonicalAsap({ email: "requester@gmail.com", status: "placed" }),
      canonicalScheduled({
        email: "requester@gmail.com",
        windowStart: "2026-07-28T14:00:00.000Z",
        windowEnd: "2026-07-28T15:00:00.000Z",
      }),
    ]) {
      const context = routeContext(body);

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(400);
      expect(context.json).toHaveBeenCalledWith({
        error: {
          code: "INVALID_REQUEST",
          message: "Invalid request payload",
        },
      });
    }

    expect(createDocument).not.toHaveBeenCalled();
  });

  it("leaves the daily limit unchanged for an allowed address", async () => {
    countDocuments.mockResolvedValue(3);
    const limited = routeContext(canonicalAsap());
    await createRequest(limited.req, limited.res);

    expect(limited.status).toHaveBeenCalledWith(429);
    expect(limited.json).toHaveBeenCalledWith({
      error: {
        code: "REQUEST_LIMIT_REACHED",
        message: "You have reached the daily limit of 3 meal requests",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
  });
});

describe("POST /api/request supported-vendor allowlist", () => {
  const UNSUPPORTED_VENDOR_MESSAGE =
    "Choose a supported CommonPlate dining location.";

  it.each(SUPPORTED_VENDORS.map((vendor) => [vendor.name]))(
    "accepts the supported vendor %s",
    async (name) => {
      const context = routeContext(canonicalAsap({ vendor: name }));

      await createRequest(context.req, context.res);

      expect(context.status).toHaveBeenCalledWith(201);
      expect(createDocument).toHaveBeenCalledWith(
        expect.objectContaining({ vendor: name })
      );
    }
  );

  it.each([
    "Off-Campus Diner",
    "Crave Nyu",
    "PALLADIUM",
    "palladium",
    "Cafe181",
    "Palladium Hall",
    "",
  ])("refuses unsupported vendor %j with INVALID_VENDOR and no side effect", async (vendor) => {
    const context = routeContext(canonicalAsap({ vendor }));

    await createRequest(context.req, context.res);

    if (vendor.trim().length === 0) {
      // A blank vendor is a structural failure, not a catalog mismatch: it
      // keeps the generic payload error rather than a vendor-specific one.
      expect(context.json).toHaveBeenCalledWith({
        error: {
          code: "INVALID_REQUEST",
          message: "Invalid request payload",
        },
      });
    } else {
      expect(context.json).toHaveBeenCalledWith({
        error: { code: "INVALID_VENDOR", message: UNSUPPORTED_VENDOR_MESSAGE },
      });
    }
    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("does not silently canonicalize a near-match variant", async () => {
    // "palladium" and "Palladium" are different strings; accepting one for
    // the other would be a case-fold the accepted contract explicitly rules
    // out, so the trimmed value must match a catalog entry exactly.
    const context = routeContext(canonicalAsap({ vendor: "palladium" }));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: { code: "INVALID_VENDOR", message: UNSUPPORTED_VENDOR_MESSAGE },
    });
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("applies the same catalog to the canonical scheduled and legacy web shapes", async () => {
    const scheduled = routeContext(
      canonicalScheduled({ vendor: "Off-Campus Diner" })
    );
    await createRequest(scheduled.req, scheduled.res);

    const legacy = routeContext({
      vendor: "Off-Campus Diner",
      food: "Vegetable rice bowl",
      pickupName: "Requester Private Name",
      email: "requester@nyu.edu",
      pickupWindowText: "Legacy display",
    });
    await createRequest(legacy.req, legacy.res);

    for (const context of [scheduled, legacy]) {
      expect(context.status).toHaveBeenCalledWith(400);
      expect(context.json).toHaveBeenCalledWith({
        error: { code: "INVALID_VENDOR", message: UNSUPPORTED_VENDOR_MESSAGE },
      });
    }
    expect(createDocument).not.toHaveBeenCalled();

    const allowedLegacy = routeContext({
      vendor: "Palladium",
      food: "Vegetable rice bowl",
      pickupName: "Requester Private Name",
      email: "requester@nyu.edu",
      pickupWindowText: "Legacy display",
    });
    await createRequest(allowedLegacy.req, allowedLegacy.res);

    expect(allowedLegacy.status).toHaveBeenCalledWith(201);
  });

  it("takes precedence over the email allowlist so it does not mask an unsupported vendor", async () => {
    // Both fields are wrong; the vendor check runs first, so this is the
    // envelope the requester sees rather than INVALID_EMAIL.
    const context = routeContext(
      canonicalAsap({ vendor: "Off-Campus Diner", email: "requester@gmail.com" })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: { code: "INVALID_VENDOR", message: UNSUPPORTED_VENDOR_MESSAGE },
    });
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("still reports an earlier structural error instead of INVALID_VENDOR", async () => {
    // Precedence is unchanged: an otherwise-malformed payload keeps the
    // generic message even when the vendor is also unsupported.
    const context = routeContext(
      canonicalAsap({ vendor: "Off-Campus Diner", timing: "soon" })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "INVALID_REQUEST",
        message: "Invalid request payload",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("keeps iOS's Picker sourced from the shared catalog instead of a second hardcoded list", () => {
    // The catalog used to be a Swift literal duplicated by hand; this proves
    // it now reads from the same `shared/vendors.json` the backend reads
    // (via a symlink at Resources/SupportedVendors.json), so there is one
    // vendor source, not two that can drift apart.
    const viewSource = readFileSync(
      new URL(
        "../ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift",
        import.meta.url
      ),
      "utf8"
    );

    expect(viewSource).not.toContain("Crave NYU");
    expect(viewSource).toContain("SupportedVendorCatalog.diningSpots");
  });
});

describe("POST /api/request backend-owned visibility and expiration", () => {
  it("makes an ASAP request visible at creation and expires it three hours later", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    const persistedInput = createDocument.mock.calls[0][0] as Record<
      string,
      unknown
    >;
    const persistedVisibility = persistedInput.visibleFrom as Date;
    const persistedExpiration = persistedInput.expiresAt as Date;

    expect(persistedVisibility).toEqual(createdAt);
    expect(persistedExpiration).toEqual(asapExpiresAt);
    expect(
      persistedExpiration.getTime() - persistedVisibility.getTime()
    ).toBe(3 * 60 * 60 * 1000);
    expect(context.status).toHaveBeenCalledWith(201);
  });

  it("makes a scheduled request visible at its start and expires it three hours after that", async () => {
    const context = routeContext(canonicalScheduled());

    await createRequest(context.req, context.res);

    const persistedInput = createDocument.mock.calls[0][0] as Record<
      string,
      unknown
    >;

    expect(persistedInput.visibleFrom).toEqual(scheduledStart);
    expect(persistedInput.expiresAt).toEqual(scheduledExpiresAt);
    expect(
      (persistedInput.expiresAt as Date).getTime() -
        (persistedInput.visibleFrom as Date).getTime()
    ).toBe(3 * 60 * 60 * 1000);
    // The advertised end and the availability end are one value, not two.
    expect(persistedInput.windowEnd).toEqual(persistedInput.expiresAt);
  });

  it("does not measure a scheduled request's lifetime from creation", async () => {
    // The distinction the whole Later timing rests on: creation decides
    // nothing about a scheduled request's window.
    const context = routeContext(canonicalScheduled());

    await createRequest(context.req, context.res);

    const persistedInput = createDocument.mock.calls[0][0] as Record<
      string,
      unknown
    >;

    expect(persistedInput.visibleFrom).not.toEqual(createdAt);
    expect(persistedInput.expiresAt).not.toEqual(asapExpiresAt);
  });

  it("never leaves a created request on the schema's 24-hour fallback", async () => {
    const dayAfterCreation = new Date(
      createdAt.getTime() + 24 * 60 * 60 * 1000
    );

    for (const body of [canonicalAsap(), canonicalScheduled()]) {
      const context = routeContext(body);
      await createRequest(context.req, context.res);
    }

    for (const call of createDocument.mock.calls) {
      const persistedInput = call[0] as Record<string, unknown>;
      expect(persistedInput.expiresAt).toBeInstanceOf(Date);
      expect(
        (persistedInput.expiresAt as Date).getTime()
      ).toBeLessThan(dayAfterCreation.getTime());
    }
  });

  it("ignores a client-supplied expiration on both create shapes", async () => {
    const clientExpiration = "2030-01-01T00:00:00.000Z";

    const canonical = routeContext(
      canonicalAsap({ expiresAt: clientExpiration })
    );
    await createRequest(canonical.req, canonical.res);

    const legacy = routeContext({
      vendor: "Palladium",
      food: "Vegetable rice bowl",
      pickupName: "Requester Private Name",
      email: "requester@nyu.edu",
      pickupWindowText: "Legacy display",
      expiresAt: clientExpiration,
    });
    await createRequest(legacy.req, legacy.res);

    expect(canonical.status).toHaveBeenCalledWith(400);
    expect(legacy.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("returns the canonical expiration in the successful public response", async () => {
    const asap = routeContext(canonicalAsap());
    await createRequest(asap.req, asap.res);

    const scheduled = routeContext(canonicalScheduled());
    await createRequest(scheduled.req, scheduled.res);

    const asapBody = JSON.parse(
      JSON.stringify(asap.json.mock.calls[0][0])
    ) as Record<string, Record<string, unknown>>;
    const scheduledBody = JSON.parse(
      JSON.stringify(scheduled.json.mock.calls[0][0])
    ) as Record<string, Record<string, unknown>>;

    expect(asapBody.request.expiresAt).toBe("2026-07-28T19:00:00.000Z");
    expect(scheduledBody.request.expiresAt).toBe("2026-07-28T20:00:00.000Z");
    expect(scheduledBody.request.expiresAt).toBe(
      scheduledBody.request.windowEnd
    );
    // The response exposes absolute instants throughout; no wall-clock
    // rendering and no `visibleFrom` field of its own — `windowStart` already
    // carries that instant for a scheduled request.
    expect(scheduledBody.request.windowStart).toBe("2026-07-28T17:00:00.000Z");
    expect(scheduledBody.request).not.toHaveProperty("visibleFrom");
    expect(asapBody.request).not.toHaveProperty("visibleFrom");
  });

  it("accepts a start exactly at the backend's own now", async () => {
    // The accepted boundary. `createdAt` is this handler's `now`, and a request
    // starting at that instant is visible from that instant — the same
    // inclusive bound `isVisibleNow` applies.
    const context = routeContext(
      canonicalScheduled({ windowStart: createdAt.toISOString() })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    const persistedInput = createDocument.mock.calls[0][0] as Record<
      string,
      unknown
    >;
    expect(persistedInput.visibleFrom).toEqual(createdAt);
    expect(persistedInput.expiresAt).toEqual(
      new Date("2026-07-28T19:00:00.000Z")
    );
  });

  it("rejects a start one millisecond before the backend's own now", async () => {
    const context = routeContext(
      canonicalScheduled({
        windowStart: new Date(createdAt.getTime() - 1).toISOString(),
      })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "INVALID_REQUEST",
        message: "Invalid request payload",
      },
    });
  });

  it("rejects an elapsed start even while its three hours have time left", async () => {
    // The case the earlier expiration-only rule accepted: one minute past, so
    // 2h59m of lifetime remained. It would have been written visible
    // immediately while advertising a pickup time that had already gone by.
    const context = routeContext(
      canonicalScheduled({ windowStart: "2026-07-28T15:59:00.000Z" })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "INVALID_REQUEST",
        message: "Invalid request payload",
      },
    });
  });

  it("performs no creation, email, or notification side effect for an elapsed start", async () => {
    const context = routeContext(
      canonicalScheduled({ windowStart: "2026-07-28T13:00:00.000Z" })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    // Refused in shape validation, ahead of the daily-limit read, so a rejected
    // create does not even consume a database round trip.
    expect(countDocuments).not.toHaveBeenCalled();
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("refuses an elapsed start outright rather than converting it to ASAP", async () => {
    // The requester chose Later. Silently posting an ASAP request they did not
    // ask for would be a different request under their name; the refusal hands
    // the choice back to them instead.
    const context = routeContext(
      canonicalScheduled({ windowStart: "2026-07-28T12:00:00.000Z" })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.status).not.toHaveBeenCalledWith(201);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("accepts a fully future start and holds it back until then", async () => {
    const context = routeContext(canonicalScheduled());

    await createRequest(context.req, context.res);

    const persistedInput = createDocument.mock.calls[0][0] as Record<
      string,
      unknown
    >;
    const body = JSON.parse(
      JSON.stringify(context.json.mock.calls[0][0])
    ) as Record<string, Record<string, unknown>>;

    expect(context.status).toHaveBeenCalledWith(201);
    expect((persistedInput.visibleFrom as Date).getTime()).toBeGreaterThan(
      createdAt.getTime()
    );
    expect(persistedInput.expiresAt).toEqual(scheduledExpiresAt);
    expect(body.request.expiresAt).toBe("2026-07-28T20:00:00.000Z");
  });

  it("applies the same start rule to the legacy compatibility path", async () => {
    function legacy(windowStart: string, windowEnd: string) {
      return {
        vendor: "Palladium",
        food: "Vegetable rice bowl",
        pickupName: "Requester Private Name",
        email: "requester@nyu.edu",
        pickupWindowText: "Legacy display",
        windowStart,
        windowEnd,
      };
    }

    // The legacy end is still shape-validated but no longer decides anything,
    // so each of these is judged on its start alone: anything before the
    // backend `now` is refused, however much of the client's own window it
    // claims is left.
    const longElapsed = routeContext(
      legacy("2026-07-28T12:00:00.000Z", "2026-07-28T15:00:00.000Z")
    );
    await createRequest(longElapsed.req, longElapsed.res);

    const justElapsed = routeContext(
      legacy("2026-07-28T15:59:00.000Z", "2026-07-28T16:30:00.000Z")
    );
    await createRequest(justElapsed.req, justElapsed.res);

    expect(longElapsed.status).toHaveBeenCalledWith(400);
    expect(justElapsed.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();

    const stillAhead = routeContext(
      legacy("2026-07-28T16:30:00.000Z", "2026-07-28T17:00:00.000Z")
    );
    await createRequest(stillAhead.req, stillAhead.res);

    expect(stillAhead.status).toHaveBeenCalledWith(201);
    const persistedInput = createDocument.mock.calls[0][0] as Record<
      string,
      unknown
    >;
    // Three hours from the start, not the client's 17:00 end.
    expect(persistedInput.visibleFrom).toEqual(
      new Date("2026-07-28T16:30:00.000Z")
    );
    expect(persistedInput.expiresAt).toEqual(
      new Date("2026-07-28T19:30:00.000Z")
    );
    expect(persistedInput.windowEnd).toEqual(persistedInput.expiresAt);
  });

  it("creates nothing and expires nothing for an invalid request", async () => {
    const context = routeContext(canonicalScheduled({ windowStart: undefined }));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(countDocuments).not.toHaveBeenCalled();
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });
});

describe("POST /api/request narrow legacy web compatibility", () => {
  it("infers ASAP only when both window fields are absent and ignores legacy display text", async () => {
    const context = routeContext({
      vendor: "Palladium",
      food: "Vegetable rice bowl",
      pickupName: "Requester Private Name",
      email: "requester@nyu.edu",
      pickupWindowText: "Client-owned text must be ignored",
    });

    await createRequest(context.req, context.res);

    expect(createDocument).toHaveBeenCalledWith(
      expect.objectContaining({
        pickupWindowText: "ASAP (available for the next 3 hours)",
        windowStart: undefined,
        windowEnd: undefined,
      })
    );
    expect(context.status).toHaveBeenCalledWith(201);
  });

  it("infers scheduled only from two valid legacy timestamps and generates canonical text", async () => {
    const context = routeContext({
      vendor: "Palladium",
      food: "Vegetable rice bowl",
      pickupName: "Requester Private Name",
      email: "requester@nyu.edu",
      pickupWindowText: "Wrong client display text",
      windowStart: "2026-07-28T17:00:00.000Z",
      windowEnd: "2026-07-28T18:00:00.000Z",
    });

    await createRequest(context.req, context.res);

    expect(createDocument).toHaveBeenCalledWith(
      expect.objectContaining({
        // Both the text and the persisted end come from the backend's own
        // three-hour window, not from the client's second timestamp.
        pickupWindowText: "Jul 28, 1:00 PM – 4:00 PM",
        windowStart: scheduledStart,
        windowEnd: scheduledExpiresAt,
        visibleFrom: scheduledStart,
        expiresAt: scheduledExpiresAt,
      })
    );
  });

  it.each([
    {
      windowStart: "2026-07-28T17:00:00.000Z",
      windowEnd: undefined,
    },
    {
      windowStart: undefined,
      windowEnd: "2026-07-28T18:00:00.000Z",
    },
    {
      windowStart: "invalid",
      windowEnd: "2026-07-28T18:00:00.000Z",
    },
    {
      windowStart: "2026-07-28T18:00:00.000Z",
      windowEnd: "2026-07-28T17:00:00.000Z",
    },
  ])("rejects an invalid legacy window pair", async (window) => {
    const context = routeContext({
      vendor: "Palladium",
      food: "Vegetable rice bowl",
      pickupName: "Requester Private Name",
      email: "requester@nyu.edu",
      pickupWindowText: "Legacy display",
      ...window,
    });

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("requires pickupWindowText when timing is absent and rejects extra fields", async () => {
    const missingCompatibilityMarker = routeContext({
      vendor: "Palladium",
      food: "Vegetable rice bowl",
      pickupName: "Requester Private Name",
      email: "requester@nyu.edu",
    });
    await createRequest(
      missingCompatibilityMarker.req,
      missingCompatibilityMarker.res
    );

    const broadenedLegacyPayload = routeContext({
      vendor: "Palladium",
      food: "Vegetable rice bowl",
      pickupName: "Requester Private Name",
      email: "requester@nyu.edu",
      pickupWindowText: "Legacy display",
      status: "requested",
    });
    await createRequest(broadenedLegacyPayload.req, broadenedLegacyPayload.res);

    expect(missingCompatibilityMarker.status).toHaveBeenCalledWith(400);
    expect(broadenedLegacyPayload.status).toHaveBeenCalledWith(400);
    expect(createDocument).not.toHaveBeenCalled();
  });
});

describe("POST /api/request side-effect ordering and errors", () => {
  it("persists and shapes before requester email; helper notification starts after the response", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(createDocument.mock.invocationCallOrder[0]).toBeLessThan(
      resendSend.mock.invocationCallOrder[0]
    );
    // Requester email is still awaited before the response; helper email
    // fan-out is started only after the response is sent (Slice 7C).
    expect(resendSend.mock.invocationCallOrder[0]).toBeLessThan(
      context.json.mock.invocationCallOrder[0]
    );
    expect(context.json.mock.invocationCallOrder[0]).toBeLessThan(
      notifySubscribersForRequest.mock.invocationCallOrder[0]
    );
    expect(context.status).toHaveBeenCalledWith(201);
    expect(countDocuments).toHaveBeenCalledOnce();
    expect(createDocument).toHaveBeenCalledOnce();
  });

  it("describes later requester email as an attempt in both email bodies", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    const submission = resendSend.mock.calls[0][0] as {
      html: string;
      text: string;
    };
    for (const body of [submission.html, submission.text]) {
      expect(body).toContain("will attempt to email you the order details");
      expect(body).toContain(
        "Request creation does not guarantee that later email will be delivered"
      );
      expect(body).not.toContain("We'll notify you");
    }
  });

  it("keeps the persisted success when Resend returns { data, error } failure", async () => {
    resendSend.mockResolvedValue({
      data: null,
      error: { name: "validation_error", message: "recipient rejected" },
    });
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(createDocument).toHaveBeenCalledOnce();
    expect(notifySubscribersForRequest).toHaveBeenCalledOnce();
    expect(context.status).toHaveBeenCalledWith(201);
    expect(context.json).toHaveBeenCalledWith(
      expect.objectContaining({ request: expect.any(Object) })
    );
    expect(consoleError).toHaveBeenCalledWith(
      `[email] Request confirmation failed after persistence for request ${requestId}`
    );
    expect(JSON.stringify(consoleError.mock.calls)).not.toContain(
      "requester@nyu.edu"
    );
    expect(JSON.stringify(consoleError.mock.calls)).not.toContain(
      "Requester Private Name"
    );
  });

  it("keeps the persisted success when requester email throws", async () => {
    resendSend.mockRejectedValue(new Error("network failure"));
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(createDocument).toHaveBeenCalledOnce();
    expect(notifySubscribersForRequest).toHaveBeenCalledOnce();
    expect(context.status).toHaveBeenCalledWith(201);
  });

  it("keeps the persisted success when helper notification throws", async () => {
    notifySubscribersForRequest.mockRejectedValue(
      new Error("subscriber delivery failed")
    );
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);
    // Helper email is detached (Slice 7C): the rejection settles on a
    // microtask after the response has already gone out.
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(createDocument).toHaveBeenCalledOnce();
    expect(context.status).toHaveBeenCalledWith(201);
    expect(consoleError).toHaveBeenCalledWith(
      `[notify] Helper email dispatch failed for request ${requestId}`,
      expect.any(Error)
    );
  });

  it("returns REQUEST_CREATION_FAILED only when persistence fails", async () => {
    createDocument.mockRejectedValue(new Error("database unavailable"));
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(500);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "REQUEST_CREATION_FAILED",
        message: "Unable to create request",
      },
    });
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("returns REQUEST_LIMIT_REACHED when the best-effort daily abuse-control count is at the limit", async () => {
    countDocuments.mockResolvedValue(3);
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(429);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "REQUEST_LIMIT_REACHED",
        message: "You have reached the daily limit of 3 meal requests",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("fails closed when the daily abuse-control count cannot be read", async () => {
    countDocuments.mockRejectedValue(new Error("count unavailable"));
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(500);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "REQUEST_CREATION_FAILED",
        message: "Unable to create request",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });

  it("creates no record and triggers no side effect for an invalid request", async () => {
    const context = routeContext(canonicalScheduled({ windowEnd: undefined }));

    await createRequest(context.req, context.res);

    expect(countDocuments).not.toHaveBeenCalled();
    expect(createDocument).not.toHaveBeenCalled();
    expect(resendSend).not.toHaveBeenCalled();
    expect(notifySubscribersForRequest).not.toHaveBeenCalled();
  });
});

describe("POST /api/request daily quota uses the NYU campus calendar day", () => {
  /**
   * W3-R1 correction: the quota's start-of-day boundary is the NYU campus
   * calendar day (`America/New_York`), not the Node process's local
   * timezone. These cases pin the exact `createdAt.$gte` the route computes
   * from a fixed backend `now`, so a regression to host-local midnight would
   * fail them regardless of where the test runner's own TZ is set.
   */
  it("counts from NYU midnight, not UTC midnight, for a request made after NYU midnight but before UTC midnight", async () => {
    // 2026-07-28T02:30:00Z is 2026-07-27, 10:30 PM EDT: already the next NYU
    // day relative to UTC's still-current 2026-07-27 calendar date.
    vi.setSystemTime(new Date("2026-07-28T02:30:00.000Z"));
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(countDocuments).toHaveBeenCalledWith(
      expect.objectContaining({
        createdAt: { $gte: new Date("2026-07-27T04:00:00.000Z") },
      })
    );
  });

  it("rolls the quota window over at NYU midnight, not at the host process's local midnight", async () => {
    // 2026-07-28T04:00:00Z is exactly 00:00:00 EDT: the first instant of the
    // new NYU campus day.
    vi.setSystemTime(new Date("2026-07-28T04:00:00.000Z"));
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(countDocuments).toHaveBeenCalledWith(
      expect.objectContaining({
        createdAt: { $gte: new Date("2026-07-28T04:00:00.000Z") },
      })
    );
  });

  it("computes the correct boundary across the DST fall-back transition", async () => {
    // Clocks fall back at 2 AM ET on 2026-11-01, so NYU midnight that day is
    // still EDT (UTC-4) while the following NYU midnight is EST (UTC-5).
    vi.setSystemTime(new Date("2026-11-01T20:00:00.000Z"));
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(countDocuments).toHaveBeenCalledWith(
      expect.objectContaining({
        createdAt: { $gte: new Date("2026-11-01T04:00:00.000Z") },
      })
    );
  });

  it("still blocks the fourth request of the NYU day with the unchanged 429 envelope", async () => {
    vi.setSystemTime(new Date("2026-07-28T04:00:00.000Z"));
    countDocuments.mockResolvedValue(3 as never);
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(429);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "REQUEST_LIMIT_REACHED",
        message: "You have reached the daily limit of 3 meal requests",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
  });

  it("still fails closed with the unchanged 500 envelope when the NYU-day count cannot be read", async () => {
    vi.setSystemTime(new Date("2026-07-28T04:00:00.000Z"));
    countDocuments.mockRejectedValue(new Error("count unavailable"));
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(500);
    expect(context.json).toHaveBeenCalledWith({
      error: {
        code: "REQUEST_CREATION_FAILED",
        message: "Unable to create request",
      },
    });
    expect(createDocument).not.toHaveBeenCalled();
  });
});

describe("POST /api/request helper push isolation", () => {
  /**
   * Push dispatch is started after the `201` is sent and is never awaited, so
   * the route cannot observe a dispatch outcome and these cases do not try to.
   * They prove the response is unaffected, that dispatch was started, and that
   * no push failure can reach the requester — dispatch behavior itself is
   * tested directly against `dispatchHelperNewRequestPush`.
   *
   * The real `startHelperNewRequestPush` runs here rather than a mock: its
   * totality is precisely what keeps an escaping throw out of `createRequest`'s
   * outer `catch`, which would otherwise attempt a second response on a
   * request whose headers are already flushed.
   */
  let pausedBefore: string | undefined;
  let requestExists: ReturnType<typeof vi.spyOn>;
  let installationFind: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    // The create route is guarded by `pausePublicAction` middleware in
    // `app.ts`; the dispatcher carries its own guard, and it must be off for
    // these cases to reach dispatch at all.
    pausedBefore = process.env[PUBLIC_ACTIONS_PAUSED_ENV];
    process.env[PUBLIC_ACTIONS_PAUSED_ENV] = "false";
    requestExists = vi
      .spyOn(MealRequest, "exists")
      .mockResolvedValue(null as never) as ReturnType<typeof vi.spyOn>;
    // Nothing may reach a real APNs submission from a route test.
    installationFind = vi
      .spyOn(Installation, "find")
      .mockReturnValue({
        select: () => ({ lean: () => ({ exec: async () => [] }) }),
      } as never) as ReturnType<typeof vi.spyOn>;
    vi.spyOn(console, "log").mockImplementation(() => {});
  });

  afterEach(() => {
    if (pausedBefore === undefined) {
      delete process.env[PUBLIC_ACTIONS_PAUSED_ENV];
    } else {
      process.env[PUBLIC_ACTIONS_PAUSED_ENV] = pausedBefore;
    }
  });

  it("starts helper push after the response, with the persisted document", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(requestExists).toHaveBeenCalledWith(
      expect.objectContaining({ _id: requestId })
    );
    // The response was built and sent before dispatch was started.
    expect(context.json.mock.invocationCallOrder[0]).toBeLessThan(
      requestExists.mock.invocationCallOrder[0]
    );
  });

  it("returns 201 without waiting on a dispatch that never settles", async () => {
    vi.useRealTimers();
    requestExists.mockReturnValue(new Promise(() => {}) as never);
    const context = routeContext(canonicalAsap());

    const started = Date.now();
    await createRequest(context.req, context.res);

    // The outstanding dispatch is still in flight; creation did not depend on
    // it, so the response is already sent.
    expect(context.status).toHaveBeenCalledWith(201);
    expect(context.json).toHaveBeenCalledOnce();
    expect(Date.now() - started).toBeLessThan(2_000);
  });

  it("returns 201 and answers once when the dispatcher's promise rejects", async () => {
    vi.useRealTimers();
    const rejections: unknown[] = [];
    const onRejection = (reason: unknown) => rejections.push(reason);
    process.on("unhandledRejection", onRejection);
    requestExists.mockRejectedValue(new Error("push selection failed") as never);
    const context = routeContext(canonicalAsap());

    try {
      await createRequest(context.req, context.res);
      await new Promise((resolve) => setTimeout(resolve, 20));
    } finally {
      process.off("unhandledRejection", onRejection);
    }

    expect(context.status).toHaveBeenCalledExactlyOnceWith(201);
    expect(context.json).toHaveBeenCalledOnce();
    // A rejecting dispatch must not reach the outer catch and attempt a
    // second response after the headers are flushed.
    expect(context.status).not.toHaveBeenCalledWith(500);
    expect(rejections).toEqual([]);
  });

  it("returns 201 when the start call itself throws synchronously", async () => {
    // A persisted document that stops being able to describe itself once the
    // response is out: every read the route needs succeeds, and only the start
    // call fails. Without a total start function this throw would land in the
    // outer `catch` and answer `500` on an already-sent response.
    const context = routeContext(canonicalAsap());
    createDocument.mockImplementation(async () => ({
      ...persistedDocument(canonicalAsap()),
      get _id() {
        if (context.json.mock.calls.length > 0) {
          throw new Error("identity unavailable");
        }
        return requestId;
      },
    }));

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledExactlyOnceWith(201);
    expect(context.status).not.toHaveBeenCalledWith(500);
    expect(context.json).toHaveBeenCalledOnce();
  });

  it("starts push even when the helper email path throws", async () => {
    // Email and push are independent channels; neither suppresses the other.
    notifySubscribersForRequest.mockRejectedValue(new Error("alert failed"));
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(requestExists).toHaveBeenCalled();
  });

  it("starts helper email fan-out after the response, detached (Slice 7C)", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(resendSend).toHaveBeenCalledOnce();
    expect(notifySubscribersForRequest).toHaveBeenCalledOnce();
    // Requester email is still awaited before the response.
    expect(resendSend.mock.invocationCallOrder[0]).toBeLessThan(
      context.json.mock.invocationCallOrder[0]
    );
    // Helper email fan-out starts only after the response is sent.
    expect(context.json.mock.invocationCallOrder[0]).toBeLessThan(
      notifySubscribersForRequest.mock.invocationCallOrder[0]
    );
  });

  it.each([
    ["a refused payload", () => canonicalAsap({ vendor: "   " })],
    ["a refused email", () => canonicalAsap({ email: "requester@gmail.com" })],
  ])("starts no push for %s", async (_label, body) => {
    const context = routeContext(body());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(requestExists).not.toHaveBeenCalled();
    expect(installationFind).not.toHaveBeenCalled();
  });

  it("starts no push when creation fails", async () => {
    createDocument.mockRejectedValue(new Error("database unavailable"));
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(500);
    expect(requestExists).not.toHaveBeenCalled();
    expect(installationFind).not.toHaveBeenCalled();
  });

  it("starts no push when the daily limit refuses the request", async () => {
    countDocuments.mockResolvedValue(3);
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(429);
    expect(requestExists).not.toHaveBeenCalled();
  });
});

describe("POST /api/request installation association (Slice 6E)", () => {
  /**
   * iOS sends its existing installation credential with request creation so
   * the backend can resolve/establish the originating installation for a
   * later best-effort fulfillment push. These cases prove the association is
   * resolved from the credential's digest (never the raw value), persisted
   * internally, never exposed publicly, and never allowed to block request
   * creation.
   */
  const validInstallationCredential = Buffer.alloc(32, 9).toString("base64url");
  const resolvedInstallationId = new mongoose.Types.ObjectId(
    "64e000000000000000000001"
  );

  let installationFindOneAndUpdate: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    installationFindOneAndUpdate = vi
      .spyOn(Installation, "findOneAndUpdate")
      .mockReturnValue({
        select: () => ({
          lean: () => ({
            exec: async () => ({ _id: resolvedInstallationId }),
          }),
        }),
      } as never) as ReturnType<typeof vi.spyOn>;
  });

  it("resolves the association and persists installationId when a valid credential is supplied", async () => {
    const context = routeContext(
      canonicalAsap({ installationCredential: validInstallationCredential })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(installationFindOneAndUpdate).toHaveBeenCalledOnce();
    expect(createDocument).toHaveBeenCalledWith(
      expect.objectContaining({ installationId: resolvedInstallationId })
    );
  });

  it("digests the raw credential and never persists or logs it", async () => {
    const context = routeContext(
      canonicalAsap({ installationCredential: validInstallationCredential })
    );

    await createRequest(context.req, context.res);

    const filter = installationFindOneAndUpdate.mock.calls[0][0] as Record<
      string,
      unknown
    >;
    expect(filter).not.toHaveProperty("installationCredential");
    expect(JSON.stringify(filter)).not.toContain(validInstallationCredential);
    expect(
      JSON.stringify(createDocument.mock.calls[0][0])
    ).not.toContain(validInstallationCredential);
  });

  it("resolves no association, and persists no installationId, when no credential is supplied", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(installationFindOneAndUpdate).not.toHaveBeenCalled();
    expect(createDocument).toHaveBeenCalledWith(
      expect.not.objectContaining({ installationId: expect.anything() })
    );
  });

  it.each([
    ["too short", "a".repeat(20)],
    ["too long", "a".repeat(60)],
    ["invalid characters", "!".repeat(43)],
    ["empty", ""],
    ["not a string", 12345],
  ])("rejects a malformed installationCredential (%s) as a structural failure", async (_name, value) => {
    const context = routeContext(
      canonicalAsap({ installationCredential: value })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(400);
    expect(context.json).toHaveBeenCalledWith({
      error: { code: "INVALID_REQUEST", message: "Invalid request payload" },
    });
    expect(createDocument).not.toHaveBeenCalled();
    expect(installationFindOneAndUpdate).not.toHaveBeenCalled();
  });

  it("accepts a scheduled canonical request with an installation credential too", async () => {
    const context = routeContext(
      canonicalScheduled({ installationCredential: validInstallationCredential })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(createDocument).toHaveBeenCalledWith(
      expect.objectContaining({ installationId: resolvedInstallationId })
    );
  });

  it("never exposes the association through the public create response", async () => {
    const context = routeContext(
      canonicalAsap({ installationCredential: validInstallationCredential })
    );

    await createRequest(context.req, context.res);

    const body = JSON.parse(JSON.stringify(context.json.mock.calls[0][0]));
    expect(JSON.stringify(body)).not.toMatch(
      /installationId|installationCredential/i
    );
  });

  it("still creates the request when resolving the association fails, with no installationId", async () => {
    installationFindOneAndUpdate.mockReturnValue({
      select: () => ({
        lean: () => ({
          exec: async () => {
            throw new Error("database unavailable");
          },
        }),
      }),
    } as never);
    const context = routeContext(
      canonicalAsap({ installationCredential: validInstallationCredential })
    );

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(createDocument).toHaveBeenCalledWith(
      expect.not.objectContaining({ installationId: expect.anything() })
    );
    expect(consoleError).toHaveBeenCalledWith(
      "[route] Could not resolve the request-installation association"
    );
  });

  it("legacy web requests remain valid without an installation credential", async () => {
    const context = routeContext({
      vendor: "Palladium",
      food: "Vegetable rice bowl",
      pickupName: "Requester Private Name",
      email: "requester@nyu.edu",
      pickupWindowText: "ASAP",
    });

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(installationFindOneAndUpdate).not.toHaveBeenCalled();
  });
});

describe("POST /api/request helper email isolation (Slice 7C)", () => {
  /**
   * Mirrors the push isolation suite above. Helper-email fan-out is started
   * after the `201` is sent and is never awaited, so these cases prove the
   * response is unaffected and that dispatch was started — not what the
   * dispatch itself does, which `notifySubscribers.test.ts` already covers.
   * `startNotifySubscribersForRequest` runs for real here (only the
   * `notifySubscribersForRequest` it wraps is mocked), because its totality is
   * exactly what keeps an escaping throw or rejection out of `createRequest`'s
   * outer `catch`.
   */
  it("starts helper email after the response, with the persisted document", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledWith(201);
    expect(notifySubscribersForRequest).toHaveBeenCalledWith(
      expect.objectContaining({ _id: requestId })
    );
    expect(context.json.mock.invocationCallOrder[0]).toBeLessThan(
      notifySubscribersForRequest.mock.invocationCallOrder[0]
    );
  });

  it("returns 201 without waiting on a helper-email dispatch that never settles", async () => {
    vi.useRealTimers();
    notifySubscribersForRequest.mockReturnValue(new Promise(() => {}));
    const context = routeContext(canonicalAsap());

    const started = Date.now();
    await createRequest(context.req, context.res);

    // The outstanding dispatch is still in flight; creation did not depend on
    // it, so the response is already sent.
    expect(context.status).toHaveBeenCalledWith(201);
    expect(context.json).toHaveBeenCalledOnce();
    expect(Date.now() - started).toBeLessThan(2_000);
  });

  it("returns 201 and answers once when the helper-email dispatch's promise rejects", async () => {
    vi.useRealTimers();
    const rejections: unknown[] = [];
    const onRejection = (reason: unknown) => rejections.push(reason);
    process.on("unhandledRejection", onRejection);
    notifySubscribersForRequest.mockRejectedValue(
      new Error("subscriber delivery failed")
    );
    const context = routeContext(canonicalAsap());

    try {
      await createRequest(context.req, context.res);
      await new Promise((resolve) => setTimeout(resolve, 20));
    } finally {
      process.off("unhandledRejection", onRejection);
    }

    expect(context.status).toHaveBeenCalledExactlyOnceWith(201);
    expect(context.json).toHaveBeenCalledOnce();
    // A rejecting dispatch must not reach the outer catch and attempt a
    // second response after the headers are flushed.
    expect(context.status).not.toHaveBeenCalledWith(500);
    expect(rejections).toEqual([]);
  });

  it("returns 201 when starting helper-email dispatch itself throws synchronously", async () => {
    // Without a total start function this throw would land in the outer
    // `catch` and answer `500` on an already-sent response.
    notifySubscribersForRequest.mockImplementation(() => {
      throw new Error("dispatch setup failed");
    });
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    expect(context.status).toHaveBeenCalledExactlyOnceWith(201);
    expect(context.status).not.toHaveBeenCalledWith(500);
    expect(context.json).toHaveBeenCalledOnce();
  });

});

describe("ASAP window text states the real three-hour lifetime", () => {
  /**
   * `REQUEST_VISIBLE_DURATION_MS` is three hours, and the iOS requester is told
   * "It will expire in 3 hours". The window text is what *helpers* read, on
   * every surface that renders a request, so a stale duration makes the two
   * sides of one request disagree — which is exactly what the earlier
   * "within the next hour" and "within the next 5 hours" phrasings did.
   */
  const PRODUCTION_SOURCES = [
    "src",
    "public",
    "ios/CommonPlateios/CommonPlateios",
  ];

  function productionFiles(directory: string): string[] {
    const root = new URL(`../${directory}/`, import.meta.url);
    return readdirSync(root, { recursive: true, encoding: "utf8" })
      .filter((entry) => /\.(ts|js|html|swift)$/.test(entry))
      // Tests and sourcemaps are not surfaces anyone reads a request on.
      .filter((entry) => !entry.includes(".test."))
      .map((entry) => `${directory}/${entry}`);
  }

  it.each(["within the next hour", "within the next 5 hours"])(
    "leaves no production occurrence of the superseded %s phrasing",
    (phrase) => {
      const offenders = PRODUCTION_SOURCES.flatMap(productionFiles).filter(
        (file) =>
          readFileSync(new URL(`../${file}`, import.meta.url), "utf8").includes(
            phrase
          )
      );

      expect(offenders).toEqual([]);
    }
  );

  it("states the same three hours the expiration enforces", async () => {
    const context = routeContext(canonicalAsap());

    await createRequest(context.req, context.res);

    const persisted = createDocument.mock.calls[0][0] as Record<string, unknown>;
    expect(persisted.pickupWindowText).toBe(
      "ASAP (available for the next 3 hours)"
    );
    // The copy must name the deadline the record actually carries.
    expect(persisted.expiresAt).toEqual(asapExpiresAt);
    expect(persisted.deleteAt).toEqual(asapExpiresAt);
    expect(
      (asapExpiresAt.getTime() - createdAt.getTime()) / (60 * 60 * 1000)
    ).toBe(3);
  });

  it("names no other duration on any production request surface", () => {
    // The requester-facing sentences and the helper-facing window text are
    // separate strings in separate languages; this is the guard that keeps
    // them describing one contract.
    const offenders = PRODUCTION_SOURCES.flatMap(productionFiles).filter(
      (file) => {
        const source = readFileSync(
          new URL(`../${file}`, import.meta.url),
          "utf8"
        );
        return /expire[sd]?\s+in\s+(?!3\s+hours)\d+\s+hours?/i.test(source);
      }
    );

    expect(offenders).toEqual([]);
  });
});

describe("POST /api/request rate limiting is a definitive pre-write refusal", () => {
  /**
   * Exercised over real HTTP because the limiter is middleware, not part of the
   * handler. What matters is the *shape* of the sixth response: iOS classifies
   * an undecodable failure on this non-idempotent POST as ambiguous, which
   * locks request creation for the rest of the process. A throttled attempt
   * never reaches validation or the write, so it must decode as a definitive
   * `RATE_LIMITED` envelope instead.
   */
  it("allows five creations, then refuses the sixth with the envelope and no write", async () => {
    vi.useRealTimers();

    const testApp = express();
    testApp.use(express.json());
    testApp.post("/api/request", createRequestRateLimiter, createRequest);
    const server = createServer(testApp);
    await new Promise<void>((resolve) =>
      server.listen(0, "127.0.0.1", resolve)
    );

    try {
      const { port } = server.address() as AddressInfo;
      const post = () =>
        fetch(`http://127.0.0.1:${port}/api/request`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(canonicalAsap()),
        });

      for (let attempt = 1; attempt <= 5; attempt += 1) {
        const allowed = await post();
        expect(allowed.status).toBe(201);
      }
      expect(createDocument).toHaveBeenCalledTimes(5);

      const refused = await post();

      expect(refused.status).toBe(429);
      await expect(refused.json()).resolves.toEqual({
        error: {
          code: "RATE_LIMITED",
          message: "Too many attempts. Please wait a moment and try again.",
          fields: null,
        },
      });
      // The refusal happened ahead of the handler entirely: no daily-limit
      // read, no document, no requester email, no subscriber notification.
      expect(createDocument).toHaveBeenCalledTimes(5);
      expect(countDocuments).toHaveBeenCalledTimes(5);
      expect(resendSend).toHaveBeenCalledTimes(5);
      expect(notifySubscribersForRequest).toHaveBeenCalledTimes(5);
    } finally {
      await new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve()))
      );
    }
  });
});
