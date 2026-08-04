import { describe, expect, it } from "vitest";
import {
  ALLOWED_EMAIL_DOMAINS,
  emailDomain,
  hasAllowedEmailDomain,
  normalizeEmail,
} from "./allowedEmailDomains.js";

describe("the allowlist itself", () => {
  it("is exactly the two accepted NYU domains", () => {
    expect([...ALLOWED_EMAIL_DOMAINS]).toEqual(["nyu.edu", "stern.nyu.edu"]);
  });
});

describe("normalization", () => {
  it.each([
    ["  faith@nyu.edu  ", "faith@nyu.edu"],
    ["FAITH@NYU.EDU", "faith@nyu.edu"],
    ["\tFaith@Stern.NYU.edu\n", "faith@stern.nyu.edu"],
  ])("normalizes %s", (raw, expected) => {
    expect(normalizeEmail(raw)).toBe(expected);
  });

  it("reads the exact domain after the final @", () => {
    expect(emailDomain("faith@nyu.edu")).toBe("nyu.edu");
    expect(emailDomain("  FAITH+alerts@NYU.EDU ")).toBe("nyu.edu");
    expect(emailDomain("faith@nyu.edu.fake")).toBe("nyu.edu.fake");
  });

  it.each(["nyu.edu", "@nyu.edu", "faith@", "   ", ""])(
    "reports no usable domain for %s",
    (value) => {
      expect(emailDomain(value)).toBeNull();
    }
  );
});

describe("exact-domain acceptance", () => {
  it.each([
    "faith@nyu.edu",
    "student@stern.nyu.edu",
    "FAITH@NYU.EDU",
    "  faith@nyu.edu  ",
    "faith+alerts@nyu.edu",
    "Student+alerts@Stern.NYU.EDU",
  ])("accepts %s", (email) => {
    expect(hasAllowedEmailDomain(email)).toBe(true);
  });

  it.each([
    "faith@gmail.com",
    "faith@law.nyu.edu",
    "faith@nyu.edu.fake",
    "faith@fake-nyu.edu",
    "faith@nyu.edu.example.com",
    "faith@notnyu.edu",
    "faith@nyu.education",
    "faith@edu",
    "nyu.edu",
    "faith@",
    "@nyu.edu",
    "",
  ])("rejects %s", (email) => {
    expect(hasAllowedEmailDomain(email)).toBe(false);
  });

  it("does not match a domain by suffix or substring", () => {
    // The two failures a `hasSuffix`/`includes` implementation would allow.
    expect(hasAllowedEmailDomain("faith@evil-nyu.edu")).toBe(false);
    expect(hasAllowedEmailDomain("faith@nyu.edu.evil.test")).toBe(false);
  });
});
