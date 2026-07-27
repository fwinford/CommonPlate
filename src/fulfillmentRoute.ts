import type { Express, Request, Response } from "express";

export const FULFILLMENT_UNAVAILABLE_MESSAGE =
  "Fulfilling meal requests is temporarily unavailable.";
export const FULFILLMENT_ROUTE_PATH = "/api/request/:id/fulfill";

/**
 * Day 2 safety pause. This must remain the first handler registered for the
 * legacy fulfillment endpoint so no validation, database, email, or lifecycle
 * logic runs before Day 5 replaces the endpoint atomically.
 */
export function refuseLegacyFulfillment(
  _req: Request,
  res: Response
): Response {
  return res.status(503).json({
    error: FULFILLMENT_UNAVAILABLE_MESSAGE,
  });
}

export function registerFulfillmentPause(app: Express): void {
  app.post(FULFILLMENT_ROUTE_PATH, refuseLegacyFulfillment);
}
