import { describe, it, expect } from "vitest";
import { formatMealRequestWindow } from "./date.js";

describe("formatMealRequestWindow", () => {
  it("formats a same-day start/end window in America/New_York time", () => {
    const start = "2026-07-13T17:00:00.000Z"; // 1:00 PM ET
    const end = "2026-07-13T18:00:00.000Z"; // 2:00 PM ET
    const result = formatMealRequestWindow(start, end);
    expect(result).toBe("Jul 13, 1:00 PM – 2:00 PM");
  });

  it("falls back to the provided text when no start/end is given", () => {
    expect(formatMealRequestWindow(undefined, undefined, "ASAP")).toBe("ASAP");
  });
});
