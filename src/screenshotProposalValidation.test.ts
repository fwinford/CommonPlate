import { describe, expect, it } from "vitest";
import { validateProviderOutput } from "./screenshotProposalValidation.js";

/**
 * Independent on-device Vision OCR evidence text — never provider output.
 * By the time `validateProviderOutput` is called, `screenshotProposalRoute.ts`
 * has already established eligibility from this exact kind of text and the
 * provider has already been called; these fixtures represent that
 * independent evidence for the corroboration/grounding tests below.
 */
const cartEvidenceText =
  "Your Pickup Order Order Instructions Cilantro on the side Continue to Checkout";

describe("validateProviderOutput", () => {
  it("refuses a payload carrying a forbidden authority field ahead of schema validation", () => {
    const result = validateProviderOutput(
      {
        visibleVenueText: null,
        foodItems: [],
        mealSwipes: null,
        action: "submit",
      },
      cartEvidenceText,
      1
    );
    expect(result).toEqual({ ok: false, reason: "forbidden_fields" });
  });

  it("refuses a malformed/wrong-shape payload", () => {
    const result = validateProviderOutput(
      { foodItems: "not-an-array" },
      cartEvidenceText,
      1
    );
    expect(result).toEqual({ ok: false, reason: "schema_invalid" });
  });

  it("refuses provider output still attempting to smuggle a visibleText field (removed from the accepted schema)", () => {
    const result = validateProviderOutput(
      {
        visibleText: "fabricated evidence claiming eligibility/corroboration",
        visibleVenueText: null,
        foodItems: [],
        mealSwipes: null,
      },
      cartEvidenceText,
      1
    );
    expect(result).toEqual({ ok: false, reason: "schema_invalid" });
  });

  it("returns an empty proposal when nothing safe was extracted (no useful extraction)", () => {
    const result = validateProviderOutput(
      { visibleVenueText: null, foodItems: [], mealSwipes: null },
      cartEvidenceText,
      1
    );
    expect(result).toEqual({ ok: true, proposal: {} });
  });

  it("produces a partial proposal — food only — when location is absent", () => {
    const result = validateProviderOutput(
      {
        visibleVenueText: null,
        foodItems: [{ name: "Create Your Own Bowl", quantity: 1, modifiers: [] }],
        mealSwipes: null,
      },
      cartEvidenceText,
      1
    );
    expect(result).toEqual({
      ok: true,
      proposal: { mealItems: ["1 Create Your Own Bowl"] },
    });
  });

  it("formats multi-item quantity and labeled-modifier food lines literally", () => {
    const result = validateProviderOutput(
      {
        visibleVenueText: null,
        foodItems: [
          { name: "Create Your Own Bowl", quantity: 1, modifiers: ["No Cilantro"] },
          { name: "Soda", quantity: 2, modifiers: [] },
        ],
        mealSwipes: null,
      },
      cartEvidenceText,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.mealItems).toEqual([
        "1 Create Your Own Bowl (No Cilantro)",
        "2 Soda",
      ]);
    }
  });

  it("strips a bare unlabeled yes/no modifier but keeps genuinely labeled values", () => {
    const result = validateProviderOutput(
      {
        visibleVenueText: null,
        foodItems: [
          {
            name: "Burger",
            quantity: 1,
            modifiers: ["yes", "No Side", "No Bag", "Yes Bag", " NO "],
          },
        ],
        mealSwipes: null,
      },
      cartEvidenceText,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.mealItems).toEqual([
        "1 Burger (No Side, No Bag, Yes Bag)",
      ]);
    }
  });

  // MARK: - Meal-swipe corroboration (independent evidence only)

  it("keeps mealSwipes only when corroborated by an exact-matching count of literal 1M markers in the independent evidence text", () => {
    const result = validateProviderOutput(
      { visibleVenueText: null, foodItems: [], mealSwipes: 2 },
      `${cartEvidenceText} 1M 1M`,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.mealSwipes).toBe(2);
    }
  });

  it("drops mealSwipes when the 1M marker count in the independent evidence does not match the candidate", () => {
    const result = validateProviderOutput(
      { visibleVenueText: null, foodItems: [], mealSwipes: 2 },
      `${cartEvidenceText} 1M`,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.mealSwipes).toBeUndefined();
    }
  });

  it("drops mealSwipes when uncorroborated (no 1M marker at all in the independent evidence)", () => {
    const result = validateProviderOutput(
      { visibleVenueText: null, foodItems: [], mealSwipes: 3 },
      cartEvidenceText,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.mealSwipes).toBeUndefined();
    }
  });

  it("never accepts a mealSwipes candidate outside the 1...5 integer range even with marker corroboration", () => {
    const result = validateProviderOutput(
      { visibleVenueText: null, foodItems: [], mealSwipes: 6 },
      `${cartEvidenceText} 1M 1M 1M 1M 1M 1M`,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.mealSwipes).toBeUndefined();
    }
  });

  it("does not corroborate mealSwipes from provider-manufactured evidence — only real independent evidence text counts", () => {
    // The accepted schema no longer accepts a provider transcription field
    // at all, so this simply confirms a provider swipe claim is dropped when
    // the real independent evidence carries no corroborating markers.
    const result = validateProviderOutput(
      { visibleVenueText: null, foodItems: [], mealSwipes: 5 },
      cartEvidenceText, // zero "1M" markers
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.mealSwipes).toBeUndefined();
    }
  });

  // MARK: - Vendor location: grounded in independent evidence

  it("resolves an unambiguous canonical vendor grounded in independent evidence, provider text absent", () => {
    const result = validateProviderOutput(
      { visibleVenueText: null, foodItems: [], mealSwipes: null },
      `${cartEvidenceText} Palladium`,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.selectedDiningSpot).toEqual({
        name: "Palladium",
        address: "Palladium Hall, 140 E 14th St",
      });
    }
  });

  it("resolves an unambiguous canonical vendor when independent evidence and a consistent provider candidate agree", () => {
    const result = validateProviderOutput(
      { visibleVenueText: "Palladium", foodItems: [], mealSwipes: null },
      `${cartEvidenceText} Palladium`,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.selectedDiningSpot?.name).toBe("Palladium");
    }
  });

  it("resolves an unambiguous full canonical Upstein entry grounded in independent evidence", () => {
    const result = validateProviderOutput(
      {
        visibleVenueText: "Upstein - Vedge Craft & Smoothie Lab",
        foodItems: [],
        mealSwipes: null,
      },
      `${cartEvidenceText} Upstein - Vedge Craft & Smoothie Lab`,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.selectedDiningSpot?.name).toBe(
        "Upstein - Vedge Craft & Smoothie Lab"
      );
    }
  });

  it("omits location for a generic/historical 'Upstein' venue text ambiguous across the two current entries", () => {
    const result = validateProviderOutput(
      {
        visibleVenueText: "Upstein",
        foodItems: [{ name: "Smoothie", quantity: 1, modifiers: [] }],
        mealSwipes: null,
      },
      "View order Order information 1 Smoothie Upstein",
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.selectedDiningSpot).toBeUndefined();
      // Other safe fields still survive independently.
      expect(result.proposal.mealItems).toEqual(["1 Smoothie"]);
    }
  });

  it("omits location when venue text does not resolve to any current catalog entry", () => {
    const result = validateProviderOutput(
      {
        visibleVenueText: "Some Random Off-Campus Diner",
        foodItems: [],
        mealSwipes: null,
      },
      `${cartEvidenceText} Some Random Off-Campus Diner`,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.selectedDiningSpot).toBeUndefined();
    }
  });

  it("never resolves location from provider text alone when independent evidence names no vendor at all (Burger fragment)", () => {
    // The provider fragment "Burger" is a substring of the catalog entry
    // "True Burger at UHall", but nothing in independent evidence grounds
    // it — raw provider text is not visible-location evidence on its own.
    const result = validateProviderOutput(
      { visibleVenueText: "Burger", foodItems: [], mealSwipes: null },
      cartEvidenceText, // no vendor name anywhere in independent evidence
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.selectedDiningSpot).toBeUndefined();
    }
  });

  it("never resolves location from provider text alone for a short generic fragment (Coffee)", () => {
    const result = validateProviderOutput(
      { visibleVenueText: "Coffee", foodItems: [], mealSwipes: null },
      cartEvidenceText,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.selectedDiningSpot).toBeUndefined();
    }
  });

  it("never resolves location from a short/partial provider fragment even when independent evidence is otherwise present", () => {
    // Independent evidence establishes eligibility but never names any
    // vendor; the provider's short fragment cannot ground itself.
    const result = validateProviderOutput(
      { visibleVenueText: "Cafe", foodItems: [], mealSwipes: null },
      cartEvidenceText,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.selectedDiningSpot).toBeUndefined();
    }
  });

  it("omits location when independent evidence and provider text disagree on the vendor", () => {
    const result = validateProviderOutput(
      { visibleVenueText: "Palladium", foodItems: [], mealSwipes: null },
      `${cartEvidenceText} Crave NYU`,
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.selectedDiningSpot).toBeUndefined();
    }
  });

  it("corroborates using the real Crave two-swipe case: independent evidence establishes both the venue and exactly two markers", () => {
    const result = validateProviderOutput(
      { visibleVenueText: "Crave NYU", foodItems: [], mealSwipes: 2 },
      "Crave NYU View order Order information 1 Bowl 1M 1M",
      1
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.proposal.mealSwipes).toBe(2);
      expect(result.proposal.selectedDiningSpot?.name).toBe("Crave NYU");
    }
  });

  // MARK: - Repeated identical lines (W4-R4 multi-image ambiguity)

  const repeatedBurger = {
    visibleVenueText: null,
    foodItems: [
      { name: "Burger", quantity: 1, modifiers: ["No Bag"] },
      { name: "Fries", quantity: 1, modifiers: [] },
      { name: " burger ", quantity: 1, modifiers: ["no  bag"] },
    ],
    mealSwipes: 3,
  };

  it("keeps genuinely repeated identical lines from a single screenshot, which cannot overlap itself", () => {
    const result = validateProviderOutput(
      repeatedBurger,
      `${cartEvidenceText} Palladium 1M 1M 1M`,
      1
    );
    expect(result).toEqual({
      ok: true,
      proposal: {
        selectedDiningSpot: {
          name: "Palladium",
          address: "Palladium Hall, 140 E 14th St",
        },
        mealItems: ["1 Burger (No Bag)", "1 Fries", "1 burger (no  bag)"],
        mealSwipes: 3,
      },
    });
  });

  it("proposes neither meal items nor swipes when several screenshots repeat an identical line", () => {
    // Overlap (one burger seen twice) and a real repeat (two burgers) are
    // indistinguishable here, so neither one, two, nor a summed quantity is
    // proposed — for either the items or the swipe count that depends on
    // the same question.
    const result = validateProviderOutput(
      repeatedBurger,
      `${cartEvidenceText} Palladium 1M 1M 1M`,
      2
    );
    expect(result).toEqual({
      ok: true,
      proposal: {
        selectedDiningSpot: {
          name: "Palladium",
          address: "Palladium Hall, 140 E 14th St",
        },
      },
    });
  });

  it("keeps every line from several screenshots when no identity repeats", () => {
    const result = validateProviderOutput(
      {
        visibleVenueText: null,
        foodItems: [
          { name: "Burger", quantity: 1, modifiers: ["No Bag"] },
          { name: "Burger", quantity: 2, modifiers: ["No Bag"] },
          { name: "Burger", quantity: 1, modifiers: ["No Side"] },
          { name: "Burger", quantity: null, modifiers: ["No Bag"] },
        ],
        mealSwipes: 2,
      },
      `${cartEvidenceText} 1M 1M`,
      3
    );
    expect(result).toEqual({
      ok: true,
      proposal: {
        mealItems: [
          "1 Burger (No Bag)",
          "2 Burger (No Bag)",
          "1 Burger (No Side)",
          "Burger (No Bag)",
        ],
        mealSwipes: 2,
      },
    });
  });

  it("treats lines that repeat only after bare yes/no modifiers are removed as repeated", () => {
    const result = validateProviderOutput(
      {
        visibleVenueText: null,
        foodItems: [
          { name: "Bowl", quantity: 1, modifiers: ["yes"] },
          { name: "Bowl", quantity: 1, modifiers: [] },
        ],
        mealSwipes: null,
      },
      cartEvidenceText,
      2
    );
    expect(result).toEqual({ ok: true, proposal: {} });
  });
});
