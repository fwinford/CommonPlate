import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  corroboratedMealSwipeCount,
  evaluateEligibility,
} from "./screenshotEligibility.js";
import { validateProviderOutput } from "./screenshotProposalValidation.js";

/**
 * W4-S3 drift guard. `shared/screenshot-conformance-vectors.json` holds
 * synthetic cases that this backend implementation and the iOS on-device
 * validator (`ScreenshotConformanceVectorTests.swift`) must both satisfy
 * exactly, so the accepted fail-closed eligibility/validation rules cannot
 * silently diverge between the two. A vector changes only by deliberate edit
 * reviewed against both suites — never by regenerating expectations from one
 * side alone.
 */
interface Vectors {
  version: number;
  eligibility: Array<{
    id: string;
    evidenceText: string;
    expected: { eligible: boolean; category: string | null };
  }>;
  mealSwipeCorroboration: Array<{
    id: string;
    evidenceText: string;
    expected: number | null;
  }>;
  providerOutput: Array<{
    id: string;
    raw: unknown;
    evidenceText: string;
    evidenceImageCount: number;
    expected: unknown;
  }>;
}

const vectors = JSON.parse(
  readFileSync(
    new URL("../shared/screenshot-conformance-vectors.json", import.meta.url),
    "utf8"
  )
) as Vectors;

describe("screenshot conformance vectors (backend side)", () => {
  it("declares a known vector version", () => {
    expect(vectors.version).toBe(1);
  });

  it.each(vectors.eligibility)("eligibility: $id", (vector) => {
    expect(evaluateEligibility(vector.evidenceText)).toEqual(vector.expected);
  });

  it.each(vectors.mealSwipeCorroboration)(
    "meal-swipe corroboration: $id",
    (vector) => {
      expect(corroboratedMealSwipeCount(vector.evidenceText)).toBe(
        vector.expected
      );
    }
  );

  it.each(vectors.providerOutput)("provider output: $id", (vector) => {
    expect(
      validateProviderOutput(
        vector.raw,
        vector.evidenceText,
        vector.evidenceImageCount
      )
    ).toEqual(vector.expected);
  });
});
