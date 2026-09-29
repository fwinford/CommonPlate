/**
 * Deterministic W4-S1 eligibility gate (accident prevention, not authenticity
 * verification). Ported from the accepted `V1-C1-or-H5` rule recorded in
 * `eval/s1-eligibility-diagnosis/` — the cart/bag chrome sub-rule (C1) union
 * with the detailed-history core (H5): legible image, exact "View order"
 * title, "Order information" section heading, and a quantity-prefixed item
 * line. The eval harness computed these signals from local Tesseract OCR;
 * production computes them from `localEvidenceText` — on-device Apple Vision
 * OCR, produced on iOS and never derived from or trusted against the OpenAI
 * provider's own output (`screenshotProposalRoute.ts`) — instead, so the
 * service needs no OCR binary of its own. The rule and its regexes are
 * otherwise unchanged — this is evaluated against evidence, not a fixture id
 * or label.
 */

const LEGIBILITY_MIN_NON_WHITESPACE_CHARS = 20;

const RE_QUANTIFIED_ITEM =
  /(^|\s)(\d{1,2})\s?x?\s+[a-z][a-z'&()-]{2,}(\s+[a-z][a-z'&()-]+){0,6}/;
const RE_VIEW_ORDER = /\bview order\b(?! details)/;
const RE_ORDER_INFORMATION = /\border information\b/;

/** Cart/bag chrome phrases (C1). "review/place your ... order" is checkout,
 * not cart, and is deliberately excluded even though it contains the cart
 * phrase as a substring. */
const CART_CHROME_PHRASES = [
  "your pickup order",
  "your delivery order",
  "order instructions",
  "cilantro on the side",
  "continue to checkout",
  "add more items",
  "empty bag",
  "items subtotal",
] as const;

function normalize(text: string): string {
  return text.toLowerCase().replace(/\s+/g, " ").trim();
}

function nonWhitespaceCharCount(text: string): number {
  return text.replace(/\s+/g, "").length;
}

function cartChromeCount(normalized: string): number {
  let count = 0;
  for (const phrase of CART_CHROME_PHRASES) {
    if (!normalized.includes(phrase)) continue;
    if (
      phrase === "your pickup order" &&
      (normalized.includes("review your pickup order") ||
        normalized.includes("place your pickup order"))
    ) {
      continue;
    }
    if (
      phrase === "your delivery order" &&
      (normalized.includes("review your delivery order") ||
        normalized.includes("place your delivery order"))
    ) {
      continue;
    }
    count += 1;
  }
  return count;
}

export type EligibleCategory = "cart" | "historical";

export interface EligibilityResult {
  eligible: boolean;
  category: EligibleCategory | null;
}

/**
 * Evaluates the accepted V1-C1-or-H5 rule against literal evidence text.
 * Never sees a fixture id, filename, or ground-truth label — only the text.
 */
export function evaluateEligibility(evidenceText: string): EligibilityResult {
  const nonWhitespaceChars = nonWhitespaceCharCount(evidenceText);
  if (nonWhitespaceChars < LEGIBILITY_MIN_NON_WHITESPACE_CHARS) {
    return { eligible: false, category: null };
  }

  const normalized = normalize(evidenceText);
  if (cartChromeCount(normalized) >= 1) {
    return { eligible: true, category: "cart" };
  }

  const detailedHistoryCore =
    RE_VIEW_ORDER.test(normalized) &&
    RE_ORDER_INFORMATION.test(normalized) &&
    RE_QUANTIFIED_ITEM.test(normalized);
  if (detailedHistoryCore) {
    return { eligible: true, category: "historical" };
  }

  return { eligible: false, category: null };
}

/**
 * Independent "1M" meal-swipe corroboration signal (unchanged from the
 * qualification harness). A candidate `mealSwipes` value survives only when
 * the literal marker count in the independent evidence text equals the
 * candidate exactly — evidence, not a guess from item count or price, and
 * never counted against anything the provider itself returned.
 */
const MEAL_SWIPE_MARKER_PATTERN = /\b1\s?M\b/g;

/**
 * Explicit aggregate Grubhub resource notation. The leading guard prevents a
 * suffix of a decimal (for example `3.0M`) or a longer word/number from being
 * treated as a valid total. Uppercase `M` is intentional: this recognizes the
 * literal provider notation already covered by the contract, not arbitrary
 * prose containing the letter m.
 */
const EXPLICIT_MEAL_SWIPE_TOTAL_PATTERN = /(?<![\w.])(\d{1,2})\s?M\b/g;
const MIN_MEAL_SWIPE_TOTAL = 1;
const MAX_MEAL_SWIPE_TOTAL = 5;

export function countMealSwipeMarkers(evidenceText: string): number {
  return (evidenceText.match(MEAL_SWIPE_MARKER_PATTERN) || []).length;
}

/**
 * Resolves independent OCR evidence to one explicit meal-swipe count without
 * manufacturing a proposal. Literal `1M` markers retain the accepted S1
 * behavior: in the absence of an aggregate total, each marker represents one
 * swipe and the markers are counted. Numeric values above one are explicit
 * aggregate totals (`2M` ... `5M`): repeated observations of the same total
 * are overlap, not addition.
 *
 * Conflicting aggregate totals, or any explicit numeric M observation outside
 * the accepted 1...5 Meal Exchange bounds, fail closed. Per-item `1M` markers
 * may coexist with an aggregate total; the explicit aggregate is authoritative
 * evidence for the count rather than a value derived from those markers.
 */
export function corroboratedMealSwipeCount(evidenceText: string): number | null {
  const observedValues = Array.from(
    evidenceText.matchAll(EXPLICIT_MEAL_SWIPE_TOTAL_PATTERN),
    (match) => Number(match[1])
  );

  if (observedValues.length === 0) return null;
  if (
    observedValues.some(
      (value) => value < MIN_MEAL_SWIPE_TOTAL || value > MAX_MEAL_SWIPE_TOTAL
    )
  ) {
    return null;
  }

  const aggregateTotals = new Set(observedValues.filter((value) => value > 1));
  if (aggregateTotals.size > 1) return null;
  if (aggregateTotals.size === 1) return aggregateTotals.values().next().value ?? null;

  const markerCount = observedValues.length;
  return markerCount <= MAX_MEAL_SWIPE_TOTAL ? markerCount : null;
}
