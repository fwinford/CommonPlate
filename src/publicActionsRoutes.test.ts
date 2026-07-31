import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

/**
 * `app.ts` connects to MongoDB and listens at module scope, so it cannot be
 * imported into a test. These assertions check the wiring instead: that the
 * pause guard is mounted ahead of the limiter and handler on exactly the two
 * public mutations, that browsing routes are left alone, and that the digest
 * cron consults the pause before it can write a delivery record.
 *
 * `publicActionsPause.test.ts` covers what the guard itself does.
 */
const appSource = readFileSync(new URL("../app.ts", import.meta.url), "utf8");

function registrationLine(pattern: RegExp): string {
  const match = appSource.match(pattern);
  expect(match, `no registration matched ${pattern}`).not.toBeNull();
  return match![0];
}

describe("public action routes are mounted behind the pause", () => {
  it("guards POST /api/request before the limiter and handler", () => {
    const line = registrationLine(/app\.post\("\/api\/request",[^\n]*/);

    expect(line).toContain(
      "pausePublicAction(CREATE_UNAVAILABLE_MESSAGE, \"PUBLIC_ACTIONS_PAUSED\")"
    );
    expect(line.indexOf("pausePublicAction")).toBeLessThan(
      line.indexOf("limiter")
    );
  });

  it("guards POST /api/subscribe before the limiter and handler", () => {
    const line = registrationLine(/app\.post\('\/api\/subscribe',[^\n]*/);

    expect(line).toContain("pausePublicAction(SUBSCRIBE_UNAVAILABLE_MESSAGE)");
    expect(line.indexOf("pausePublicAction")).toBeLessThan(
      line.indexOf("limiter")
    );
  });

  it("leaves public browsing routes ungated", () => {
    const listRoute = registrationLine(/app\.get\("\/api\/requests",[^\n]*/);
    const detailRoute = registrationLine(
      /app\.get\("\/api\/request\/:id",[^\n]*/
    );

    expect(listRoute).not.toContain("pausePublicAction");
    expect(detailRoute).not.toContain("pausePublicAction");
  });

  it("exposes the pause state read-only for the web pages", () => {
    const statusRoute = registrationLine(
      /app\.get\("\/api\/public-actions",[^\n]*/
    );

    expect(statusRoute).not.toContain("pausePublicAction");
    expect(appSource).toContain("res.json({ paused: isPublicActionsPaused() })");
  });

  it("registers only the claim-authorized fulfillment handler", () => {
    expect(appSource).toMatch(
      /app\.post\(\s*FULFILLMENT_ROUTE_PATH,\s*fulfillmentRateLimiter,\s*fulfillRequest\s*\)/
    );
    expect(appSource).not.toContain("registerFulfillmentPause");
    expect(appSource).not.toContain(
      'app.post("/api/request/:id/fulfill"'
    );
  });

  it("guards claim and extension before independent rate-limit buckets", () => {
    const claimRoute = appSource.match(
      /app\.post\(\s*CLAIM_ROUTE_PATH,\s*pauseDay4Mutation,\s*claimRateLimiter,\s*claimRequest\s*\)/
    );
    const extensionRoute = appSource.match(
      /app\.post\(\s*CLAIM_EXTENSION_ROUTE_PATH,\s*pauseDay4Mutation,\s*claimExtensionRateLimiter,\s*extendClaim\s*\)/
    );

    expect(claimRoute).not.toBeNull();
    expect(extensionRoute).not.toBeNull();
    expect(claimRoute![0]).not.toContain("claimExtensionRateLimiter");
    expect(extensionRoute![0]).not.toContain("claimRateLimiter,");
  });

  it("removes the temporary unauthenticated DELETE route", () => {
    expect(appSource).not.toMatch(/app\.delete\(\s*["']\/api\/request\/:id/);
    expect(appSource).not.toContain("findByIdAndDelete");
  });

  it("uses effective availability for list and digest queries", () => {
    const listStart = appSource.indexOf(
      'app.get("/api/requests"'
    );
    const listEnd = appSource.indexOf(
      'app.get("/api/request/:id"',
      listStart
    );
    const digestStart = appSource.indexOf(
      'cron.schedule("5 * * * *"'
    );
    // The digest cron ends where the next cron begins. This sentinel must match
    // the real five-field expression in app.ts — a sentinel that is never found
    // yields -1 and silently widens the slice to almost the whole file.
    const digestEnd = appSource.indexOf(
      'cron.schedule("0 3 * * *"',
      digestStart
    );

    expect(listStart).toBeGreaterThan(-1);
    expect(listEnd).toBeGreaterThan(listStart);
    expect(digestStart).toBeGreaterThan(-1);
    expect(digestEnd).toBeGreaterThan(digestStart);

    const listSource = appSource.slice(listStart, listEnd);
    const digestSource = appSource.slice(digestStart, digestEnd);

    expect(listSource).toContain("buildEffectiveAvailabilityFilter(now)");
    expect(digestSource).toContain(
      "buildEffectiveAvailabilityFilter(digestNow)"
    );
    // Neither path may hand-roll an expiration bound: the five-minute minimum
    // that gates claiming lives in the shared helper, and a local `expiresAt`
    // clause here is exactly how the two would drift back apart.
    expect(listSource).not.toMatch(/expiresAt:\s*\{/);
    expect(digestSource).not.toMatch(/expiresAt:\s*\{/);
  });

  it("uses deleteAt for backup physical cleanup", () => {
    expect(appSource).toContain(
      "MealRequest.deleteMany({ deleteAt: { $lte: now } })"
    );
    expect(appSource).not.toContain(
      "MealRequest.deleteMany({ expiresAt: { $lte: now } })"
    );
  });

  it("checks the pause in the digest cron before any query or send", () => {
    const cronStart = appSource.indexOf('cron.schedule("5 * * * *"');
    const pauseCheck = appSource.indexOf("isPublicActionsPaused()", cronStart);
    const firstQuery = appSource.indexOf("MealRequest.find(", cronStart);
    const firstSend = appSource.indexOf("sendDigestEmail(", cronStart);
    const firstSendLogWrite = appSource.indexOf("SendLog.create(", cronStart);

    expect(cronStart).toBeGreaterThan(-1);
    expect(pauseCheck).toBeGreaterThan(cronStart);
    expect(pauseCheck).toBeLessThan(firstQuery);
    expect(pauseCheck).toBeLessThan(firstSend);
    expect(pauseCheck).toBeLessThan(firstSendLogWrite);
  });
});
