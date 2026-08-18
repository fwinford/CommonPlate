import { describe, expect, it } from "vitest";
import {
  countMealSwipeMarkers,
  evaluateEligibility,
} from "./screenshotEligibility.js";

describe("evaluateEligibility", () => {
  it("rejects an illegible/near-empty transcription", () => {
    expect(evaluateEligibility("hi")).toEqual({
      eligible: false,
      category: null,
    });
  });

  it("accepts a Grubhub cart/bag screenshot via cart chrome", () => {
    const text =
      "Your Pickup Order Order Instructions Cilantro on the side Continue to Checkout";
    expect(evaluateEligibility(text)).toEqual({
      eligible: true,
      category: "cart",
    });
  });

  it("rejects review checkout screens even though they contain cart phrases as substrings", () => {
    const text =
      "Review your pickup order Review your delivery order please confirm this order today";
    expect(evaluateEligibility(text)).toEqual({
      eligible: false,
      category: null,
    });
  });

  it("rejects a place-your-delivery-order checkout screen", () => {
    const text =
      "Order total is $13.00 Place\nYOUR   delivery order: 2M + $2.50";
    expect(evaluateEligibility(text)).toEqual({
      eligible: false,
      category: null,
    });
  });

  it("rejects a place-your-pickup-order checkout screen", () => {
    const text = "Order total is $8.00 Place your pickup order to confirm";
    expect(evaluateEligibility(text)).toEqual({
      eligible: false,
      category: null,
    });
  });

  it("accepts a detailed historical order via the H5 core (view order + order information + quantified item)", () => {
    const text =
      "View order Order information 1 Create Your Own Bowl completed on July 4";
    expect(evaluateEligibility(text)).toEqual({
      eligible: true,
      category: "historical",
    });
  });

  it("rejects a historical screenshot missing the quantified item line", () => {
    const text = "View order Order information completed on July 4";
    expect(evaluateEligibility(text)).toEqual({
      eligible: false,
      category: null,
    });
  });

  it("rejects an Orders-list/index screen (no single-order detail heading)", () => {
    const text =
      "Your Orders Past Orders Completed Reorder 1 Create Your Own Bowl";
    expect(evaluateEligibility(text)).toEqual({
      eligible: false,
      category: null,
    });
  });

  it("rejects a menu/browse screen", () => {
    const text =
      "Popular items Chicken Bowl Vegetable Bowl Add to cart Free delivery over $12";
    expect(evaluateEligibility(text)).toEqual({
      eligible: false,
      category: null,
    });
  });

  it("rejects a non-Grubhub screenshot", () => {
    const text = "Uber Eats Your order has been delivered Rate your order";
    expect(evaluateEligibility(text)).toEqual({
      eligible: false,
      category: null,
    });
  });

  it("rejects adversarial vocabulary imitation that stays below legibility/rule thresholds", () => {
    const text = "view order order information";
    // Two required headings present but no quantified item line: still
    // rejected — the rule requires all three signals, not brand vocabulary
    // alone.
    expect(evaluateEligibility(text)).toEqual({
      eligible: false,
      category: null,
    });
  });
});

describe("countMealSwipeMarkers", () => {
  it("counts literal 1M markers", () => {
    expect(countMealSwipeMarkers("1M 1M 1M")).toBe(3);
    expect(countMealSwipeMarkers("Meals used (1M = $8.00)")).toBe(1);
  });

  it("returns zero when no marker is present", () => {
    expect(countMealSwipeMarkers("2 items, $14.00 total")).toBe(0);
  });

  it("does not count a numeric distractor that isn't the exact marker", () => {
    expect(countMealSwipeMarkers("Order #1234, 15 items")).toBe(0);
  });
});
