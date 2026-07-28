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

  it("keeps the legacy fulfillment refusal independent of the pause flag", () => {
    const registration = appSource.indexOf("registerFulfillmentPause(app)");
    const legacyRoute = appSource.indexOf(
      'app.post("/api/request/:id/fulfill"'
    );

    expect(registration).toBeGreaterThan(-1);
    expect(legacyRoute).toBeGreaterThan(registration);
    expect(appSource).not.toMatch(
      /if\s*\([^)]*isPublicActionsPaused[^)]*\)\s*\{?\s*registerFulfillmentPause/
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
