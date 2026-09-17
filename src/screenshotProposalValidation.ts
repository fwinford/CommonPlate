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

function formatFoodItem(item: ScreenshotFoodItem): string | null {
  const name = item.name.trim();
  if (!name) return null;
  const quantityPrefix =
    item.quantity !== null && item.quantity > 0 ? `${item.quantity} ` : "";
  const modifierSuffix = item.modifiers.length
    ? ` (${item.modifiers.join(", ")})`
    : "";
  return `${quantityPrefix}${name}${modifierSuffix}`;
}

function itemIdentity(item: ScreenshotFoodItem): string {
  const normalize = (text: string) => text.trim().toLowerCase().replace(/\s+/g, " ");
  return JSON.stringify([
    normalize(item.name),
    item.quantity,
    item.modifiers.map(normalize).sort(),
  ]);
}

/**
 * W4-R4 overlap handling for multi-image evidence.
 *
 * Up to five screenshots describe ONE logical order, and real screenshots of
 * one order overlap. The provider is asked to report an item seen in several
 * screenshots once, but its output is one merged list with no record of
 * which screenshot each line came from. So when two lines share an exact
 * identity after normalization (same name, quantity, and modifier set), the
 * output cannot say whether that is one item seen twice or two identical
 * items ordered — collapsing to one, keeping both, or adding quantities
 * would each be a guess.
 *
 * The only provenance available is how many screenshots were analyzed:
 *
 * - One screenshot cannot overlap with itself, so repeated identical lines
 *   are separate order lines and every line is kept, as before W4-R4.
 * - With several screenshots, a repeated identity is ambiguous and is
 *   `null`: the caller proposes no meal items (and no swipe count, which
 *   depends on the same question) rather than a list that silently gained
 *   or lost an item. Lines that differ in quantity or any modifier are
 *   different items, never ambiguous with each other.
 */
function proposedMealItems(
  foodItems: ScreenshotFoodItem[],
  evidenceImageCount: number
): string[] | null {
  const seen = new Set<string>();
  const lines: string[] = [];

  for (const item of foodItems) {
    const line = formatFoodItem(item);
    if (line === null) continue;
    const identity = itemIdentity(item);
    if (seen.has(identity) && evidenceImageCount > 1) return null;
    seen.add(identity);
    lines.push(line);
  }

  return lines;
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
  evidenceImageCount: number,
  visibleVenueText: string | null,
  foodItems: ScreenshotFoodItem[],
  mealSwipes: number | null
): ScreenshotProposal {
  const proposal: ScreenshotProposal = {};

  const vendor = resolveVendor(evidenceText, visibleVenueText);
  if (vendor) {
    proposal.selectedDiningSpot = { name: vendor.name, address: vendor.address };
  }

  // W4-R4: one entry per observed order line. `null` means repeated
  // identical lines across several screenshots could be overlap or a real
  // repeat, so neither meal items nor a swipe count is proposed.
  const mealItems = proposedMealItems(sanitizeModifiers(foodItems), evidenceImageCount);
  if (mealItems?.length) {
    proposal.mealItems = mealItems;
  }

  if (mealItems !== null && mealSwipes !== null && mealSwipes >= 1 && mealSwipes <= 5) {
    // Independent corroboration (accepted "1M" signal): the candidate
    // survives only when the literal marker count in `evidenceText` — the
    // on-device Apple Vision OCR text this provider never saw or produced —
    // matches it exactly. A mismatch drops the value rather than coercing
    // it. This is never evaluated against anything the provider returned.
    //
    // W4-R4 multi-image consequence, and an intended one: `evidenceText` is
    // the combined evidence of every eligible screenshot, so an item visible
    // in two overlapping screenshots contributes its `1M` marker twice and
    // the count no longer matches. The candidate is dropped and the
    // requester chooses the quantity themselves. Ambiguous cross-screenshot
    // evidence stays ambiguous: deduplicating markers here would be a guess
    // about which markers describe the same swipe, and a wrong guess sets a
    // quantity the requester never chose.
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
 * the provider itself returned. `evidenceImageCount` is how many eligible
 * screenshots the provider analyzed together (see `proposedMealItems`).
 */
export function validateProviderOutput(
  raw: unknown,
  evidenceText: string,
  evidenceImageCount: number
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
    proposal: buildProposal(
      evidenceText,
      evidenceImageCount,
      visibleVenueText,
      foodItems,
      mealSwipes
    ),
  };
}
