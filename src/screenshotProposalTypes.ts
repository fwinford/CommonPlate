import { z } from "zod";

/**
 * W4-S1 provider output shape. Distinct from every request-create schema in
 * `createRequestRoute.ts`: this is analysis-boundary shape, never a Request
 * payload, and it is `.strict()` so a provider attempting to smuggle a field
 * outside this allowlist (e.g. `pickupName`, `action`, `reasoning`) fails
 * schema validation rather than being silently stripped.
 *
 * Deliberately carries no provider-produced transcription field. An earlier
 * revision asked the provider itself for a `visibleText` field and used it
 * as the eligibility/corroboration evidence source — that validated
 * OpenAI's own claims against evidence OpenAI itself produced, which is not
 * independent corroboration and was reverted. Eligibility and meal-swipe
 * corroboration now use `localEvidenceText` (`screenshotProposalRoute.ts`),
 * produced on-device by Apple Vision OCR — a different engine, run before
 * this schema's provider is ever called.
 */
export const ScreenshotFoodItemSchema = z
  .object({
    name: z.string(),
    quantity: z.number().int().nullable(),
    modifiers: z.array(z.string()),
  })
  .strict();

/**
 * W4-R4: unchanged in shape for multi-image analysis. Up to five screenshots
 * are evidence for ONE logical order, so the provider still returns exactly
 * one output object describing that one order — never one object per image,
 * which would invite the caller to concatenate overlapping screenshots into
 * duplicate items.
 */
export const ScreenshotProviderOutputSchema = z
  .object({
    visibleVenueText: z.string().nullable(),
    foodItems: z.array(ScreenshotFoodItemSchema),
    mealSwipes: z.number().int().nullable(),
  })
  .strict();

export type ScreenshotFoodItem = z.infer<typeof ScreenshotFoodItemSchema>;
export type ScreenshotProviderOutput = z.infer<
  typeof ScreenshotProviderOutputSchema
>;

/**
 * Fields that must never appear in provider output. Presence of any of these
 * is refused before schema validation even runs, independent of whether the
 * rest of the payload is otherwise well-formed — this is an authority
 * boundary, not a shape convenience.
 */
export const FORBIDDEN_PROVIDER_FIELDS = [
  "pickupName",
  "timing",
  "preferredPickupTime",
  "action",
  "submit",
  "reasoning",
  "explanation",
  // W4-R4: which menu path a request uses, and how many Dining Dollars it
  // needs, are requester product decisions. Screenshot Assistance proposes
  // values; it does not decide them. Listing these here means a provider
  // attempting to select a path or invent a dollar amount is refused before
  // schema validation even runs, exactly like an attempted `submit`.
  "menuPath",
  "orderDetails",
  "diningDollars",
  "estimatedDiningDollars",
  "estimatedDiningDollarsCents",
] as const;

/**
 * The allowlisted proposal shape: location, literal food, meal swipes only.
 *
 * W4-R4 replaces the single `foodRequest` string with `mealItems` — one
 * entry per distinct observed item — so a proposal can populate the
 * structured per-swipe meal-detail fields instead of one flat blob. The
 * allowlist itself is unchanged in kind: still location, literal food, and
 * meal swipes, and still nothing that decides menu path, Dining Dollars,
 * timing, or submission.
 */
export interface ScreenshotProposal {
  selectedDiningSpot?: { name: string; address: string };
  mealItems?: string[];
  mealSwipes?: number;
}

export interface ScreenshotProposalResponseBody {
  eligible: boolean;
  proposal: ScreenshotProposal;
}
