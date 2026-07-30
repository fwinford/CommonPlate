import { describe, expect, it } from "vitest";
import {
  CLAIM_MINIMUM_REMAINING_MS,
  buildEffectiveAvailabilityFilter,
  buildMinimumRemainingTimeFilter,
  hasMinimumRemainingTime,
  isEffectivelyAvailable,
} from "./requestAvailability.js";

// One captured instant, as every caller supplies. Nothing here reads the clock,
// so the boundary cases cannot drift into flakiness.
const now = new Date("2026-07-30T16:00:00.000Z");
const exactlyFiveMinutesLeft = new Date(
  now.getTime() + CLAIM_MINIMUM_REMAINING_MS
);
const oneMillisecondShort = new Date(
  exactlyFiveMinutesLeft.getTime() - 1
);

describe("the shared minimum-remaining-time rule", () => {
  it("is five full minutes measured from the captured instant", () => {
    expect(CLAIM_MINIMUM_REMAINING_MS).toBe(5 * 60 * 1000);
    expect(buildMinimumRemainingTimeFilter(now)).toEqual({
      $gt: now,
      $gte: exactlyFiveMinutesLeft,
    });
  });

  it("accepts exactly five minutes and rejects one millisecond less", () => {
    expect(hasMinimumRemainingTime(exactlyFiveMinutesLeft, now)).toBe(true);
    expect(hasMinimumRemainingTime(oneMillisecondShort, now)).toBe(false);
  });

  it("keeps the in-memory rule identical to the database bound", () => {
    // Advertising and claiming disagree the moment these two drift apart.
    const bound = buildMinimumRemainingTimeFilter(now).$gte.getTime();

    for (const offset of [-1, 0, 1, 60_000, -60_000]) {
      const expiresAt = new Date(bound + offset);
      expect(hasMinimumRemainingTime(expiresAt, now)).toBe(
        expiresAt.getTime() >= bound
      );
    }
  });

  it("fails closed on a missing or unparseable expiration", () => {
    expect(hasMinimumRemainingTime(null, now)).toBe(false);
    expect(hasMinimumRemainingTime(undefined, now)).toBe(false);
    expect(hasMinimumRemainingTime("not a date", now)).toBe(false);
  });
});

describe("buildEffectiveAvailabilityFilter", () => {
  it("advertises only what a claim could still win", () => {
    expect(buildEffectiveAvailabilityFilter(now)).toEqual({
      expiresAt: { $gt: now, $gte: exactlyFiveMinutesLeft },
      $or: [
        { status: "open" },
        { status: "claimed", claimExpiresAt: { $lte: now } },
      ],
    });
  });

  it("derives both bounds from the instant the caller captured", () => {
    const other = new Date("2026-07-30T18:30:00.000Z");
    const filter = buildEffectiveAvailabilityFilter(other);

    expect(filter.expiresAt.$gte).toEqual(
      new Date(other.getTime() + CLAIM_MINIMUM_REMAINING_MS)
    );
    expect(filter.$or[1].claimExpiresAt.$lte).toEqual(other);
  });
});

describe("isEffectivelyAvailable", () => {
  it("advertises an open request with exactly the minimum remaining", () => {
    expect(
      isEffectivelyAvailable(
        { status: "open", expiresAt: exactlyFiveMinutesLeft },
        now
      )
    ).toBe(true);
  });

  it("withholds an open request one millisecond short of the minimum", () => {
    expect(
      isEffectivelyAvailable(
        { status: "open", expiresAt: oneMillisecondShort },
        now
      )
    ).toBe(false);
  });

  it("reopens an expired claim that still has the minimum remaining", () => {
    expect(
      isEffectivelyAvailable(
        {
          status: "claimed",
          expiresAt: exactlyFiveMinutesLeft,
          claimExpiresAt: new Date(now.getTime() - 1),
        },
        now
      )
    ).toBe(true);
  });

  it("does not reopen an expired claim that ran out of runway", () => {
    expect(
      isEffectivelyAvailable(
        {
          status: "claimed",
          expiresAt: oneMillisecondShort,
          claimExpiresAt: new Date(now.getTime() - 1),
        },
        now
      )
    ).toBe(false);
  });

  it("withholds an active claim regardless of remaining time", () => {
    expect(
      isEffectivelyAvailable(
        {
          status: "claimed",
          expiresAt: new Date(now.getTime() + 60 * 60 * 1000),
          claimExpiresAt: new Date(now.getTime() + 1),
        },
        now
      )
    ).toBe(false);
  });
});
