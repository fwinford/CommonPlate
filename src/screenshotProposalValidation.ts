import { SUPPORTED_VENDORS, type SupportedVendor } from "./supportedVendors.js";
import { countMealSwipeMarkers } from "./screenshotEligibility.js";
import {
  FORBIDDEN_PROVIDER_FIELDS,
  ScreenshotProviderOutputSchema,
  type ScreenshotFoodItem,
  type ScreenshotProposal,
} from "./screenshotProposalTypes.js";

export type ProviderValidationFailure =
  | "forbidden_fields"
  | "schema_invalid";

export type ProviderValidationResult =
  | { ok: true; proposal: ScreenshotProposal }
  | { ok: false; reason: ProviderValidationFailure };

/**
 * A modifier consisting of only a bare affirmative/negative token, with no
 * other visible label attached, cannot be attributed to a parent item — the
 * screenshot may show a lone "yes"/"no" beside a prompt whose own label was
 * not captured as a modifier string. Genuinely labeled selections ("No
 * Side", "No Bag", "Yes Bag") are unaffected: this matches only an exact
 * standalone token after trim/case-fold.
 */
const BARE_AMBIGUOUS_MODIFIER_TOKENS = new Set(["yes", "no"]);

function isBareAmbiguousModifier(modifier: string): boolean {
  return BARE_AMBIGUOUS_MODIFIER_TOKENS.has(modifier.trim().toLowerCase());
}

function sanitizeModifiers(
  foodItems: ScreenshotFoodItem[]
): ScreenshotFoodItem[] {
  return foodItems.map((item) => ({
    ...item,
    modifiers: item.modifiers.filter((mod) => !isBareAmbiguousModifier(mod)),
  }));
}

function formatFoodRequest(foodItems: ScreenshotFoodItem[]): string | undefined {
  const lines = foodItems
    .map((item) => {
      const name = item.name.trim();
      if (!name) return null;
      const quantityPrefix =
        item.quantity !== null && item.quantity > 0 ? `${item.quantity} ` : "";
      const modifierSuffix = item.modifiers.length
        ? ` (${item.modifiers.join(", ")})`
        : "";
      return `${quantityPrefix}${name}${modifierSuffix}`;
    })
    .filter((line): line is string => line !== null);
  return lines.length ? lines.join("; ") : undefined;
}

function normalizeVenueText(text: string): string {
  return text.toLowerCase().replace(/\s+/g, " ").trim();
}

/**
 * Whether normalized observed text names `vendor`. Deliberately narrow:
 *
 * - `normalized === full` / `normalized === base` — an exact match to the
 *   complete catalog name, or to its base label before " - " (the only
 *   accepted abbreviation: the two current Upstein entries share exactly
 *   this base, which is what makes a bare "Upstein" ambiguous rather than a
 *   match — see `resolveVendor` below).
 * - `normalized.includes(full)` — the complete canonical name appears
 *   verbatim somewhere within longer observed text (a real screenshot's OCR
 *   naturally carries surrounding chrome/labels around the venue name).
 *
 * Deliberately NOT `full.includes(normalized)`: that direction would let any
 * short or generic fragment ("Burger", "Coffee", "Cafe") match merely
 * because it happens to be a substring of some catalog entry's full name —
 * exactly the fuzzy-guessing false-positive this rule must not produce.
 */
function matchesVendorText(normalized: string, vendor: SupportedVendor): boolean {
  const full = vendor.name.toLowerCase();
  const base = full.split(" - ")[0]?.trim() ?? full;
  return normalized === full || normalized === base || normalized.includes(full);
}

function groundedVendorMatches(text: string | null): SupportedVendor[] {
  if (!text) return [];
  const normalized = normalizeVenueText(text);
  if (!normalized) return [];
  return SUPPORTED_VENDORS.filter((vendor) => matchesVendorText(normalized, vendor));
}

/**
 * Resolves a canonical `shared/vendors.json` entry, grounded in
 * `evidenceText` — the independent on-device Vision OCR text — never in the
 * provider's own `visibleVenueText` alone. A provider claiming a venue the
 * independent evidence does not itself establish cannot select a vendor by
 * itself; raw provider text is not visible-location evidence on its own.
 *
 * Two catalog entries that share a base label before " - " (the two current
 * Upstein entries) are deliberately ambiguous when only the shared base
 * label is visible in the independent evidence — a match against every
 * entry sharing that label, not the first one, so a generic/historical
 * "Upstein" screenshot omits rather than guesses.
 *
 * If the provider's `visibleVenueText` is present and names a different
 * vendor than the one independent evidence grounded, the two disagree and
 * the proposal omits location rather than trusting either side alone. An
 * absent or consistent provider candidate does not block the grounded
 * result.
 */
function resolveVendor(
  evidenceText: string,
  visibleVenueText: string | null
): SupportedVendor | null {
  const groundedMatches = groundedVendorMatches(evidenceText);
  const groundedNames = new Set(groundedMatches.map((vendor) => vendor.name));
  if (groundedNames.size !== 1) return null;
  const grounded = groundedMatches[0]!;

  if (visibleVenueText) {
    const providerNames = new Set(
      groundedVendorMatches(visibleVenueText).map((vendor) => vendor.name)
    );
    if (providerNames.size > 0 && !providerNames.has(grounded.name)) {
      return null;
    }
  }

  return grounded;
}

function buildProposal(
  evidenceText: string,
  visibleVenueText: string | null,
  foodItems: ScreenshotFoodItem[],
  mealSwipes: number | null
): ScreenshotProposal {
  const proposal: ScreenshotProposal = {};

  const vendor = resolveVendor(evidenceText, visibleVenueText);
  if (vendor) {
    proposal.selectedDiningSpot = { name: vendor.name, address: vendor.address };
  }

  const foodRequest = formatFoodRequest(sanitizeModifiers(foodItems));
  if (foodRequest) {
    proposal.foodRequest = foodRequest;
  }

  if (mealSwipes !== null && mealSwipes >= 1 && mealSwipes <= 5) {
    // Independent corroboration (accepted "1M" signal): the candidate
    // survives only when the literal marker count in `evidenceText` — the
    // on-device Apple Vision OCR text this provider never saw or produced —
    // matches it exactly. A mismatch drops the value rather than coercing
    // it. This is never evaluated against anything the provider returned.
    if (countMealSwipeMarkers(evidenceText) === mealSwipes) {
      proposal.mealSwipes = mealSwipes;
    }
  }

  return proposal;
}

/**
 * The one deterministic validation boundary raw provider output passes
 * through before any of it can reach a proposal. Forbidden-field presence is
 * checked ahead of schema parsing, independent of whether the rest of the
 * shape is otherwise valid, so an attempted authority-field smuggling attempt
 * is refused on its own rather than folded into an ordinary shape error.
 *
 * Callers must only reach this function for a screenshot the independent
 * `localEvidenceText` rule (`screenshotEligibility.ts`) has already found
 * eligible — `screenshotProposalRoute.ts` evaluates that rule and refuses to
 * call the provider at all otherwise, so an ineligible screenshot never
 * reaches this function or the provider. `evidenceText` is that same
 * independent evidence, passed through here only for meal-swipe
 * corroboration; it is never re-derived from, or trusted against, anything
 * the provider itself returned.
 */
export function validateProviderOutput(
  raw: unknown,
  evidenceText: string
): ProviderValidationResult {
  if (raw && typeof raw === "object") {
    for (const key of Object.keys(raw as Record<string, unknown>)) {
      if ((FORBIDDEN_PROVIDER_FIELDS as readonly string[]).includes(key)) {
        return { ok: false, reason: "forbidden_fields" };
      }
    }
  }

  const result = ScreenshotProviderOutputSchema.safeParse(raw);
  if (!result.success) {
    return { ok: false, reason: "schema_invalid" };
  }

  const { visibleVenueText, foodItems, mealSwipes } = result.data;
  return {
    ok: true,
    proposal: buildProposal(evidenceText, visibleVenueText, foodItems, mealSwipes),
  };
}
