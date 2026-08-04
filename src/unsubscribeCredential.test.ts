import { createHmac } from "node:crypto";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION,
  MAXIMUM_UNSUBSCRIBE_CREDENTIAL_VERSION,
  MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES,
  UNSUBSCRIBE_CREDENTIAL_PARAMETER,
  UNSUBSCRIBE_ROUTE_PATH,
  UNSUBSCRIBE_SIGNING_SECRET_ENV,
  UnsubscribeCredentialConfigurationError,
  UnsubscribeCredentialError,
  buildUnsubscribeUrl,
  readUnsubscribeSigningSecret,
  signUnsubscribeCredential,
  unsubscribeCredentialFor,
  verifyUnsubscribeCredential,
} from "./unsubscribeCredential.js";

// Every secret here is supplied directly. The process environment is touched
// only by the cases that exist to describe configuration reading.
const SECRET = Buffer.alloc(MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES, 1);
const OTHER_SECRET = Buffer.alloc(MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES, 2);

const SUBSCRIBER_ID = "64b000000000000000000001";
const OTHER_SUBSCRIBER_ID = "64b000000000000000000002";

function credential(
  subscriberId = SUBSCRIBER_ID,
  version: number = INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION,
  secret = SECRET
): string {
  return signUnsubscribeCredential(subscriberId, version, secret);
}

function parts(value: string): [string, string, string] {
  const split = value.split(".");
  expect(split).toHaveLength(3);
  return split as [string, string, string];
}

afterEach(() => {
  vi.unstubAllEnvs();
});

describe("unsubscribe signing secret configuration", () => {
  it("reads its own dedicated variable", () => {
    const configured = "u".repeat(MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES);
    vi.stubEnv(UNSUBSCRIBE_SIGNING_SECRET_ENV, configured);

    expect(readUnsubscribeSigningSecret()).toEqual(
      Buffer.from(configured, "utf8")
    );
  });

  it.each([
    ["missing", undefined],
    ["empty", ""],
    ["too short", "u".repeat(MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES - 1)],
  ])("refuses a %s secret", (_label, configured) => {
    vi.stubEnv(UNSUBSCRIBE_SIGNING_SECRET_ENV, configured);

    expect(() => readUnsubscribeSigningSecret()).toThrow(
      UnsubscribeCredentialConfigurationError
    );
  });

  it("never reuses another credential's secret or digest", () => {
    // Reading the claim-token secret or a stored confirmation digest here
    // would let one credential's compromise forge the other.
    vi.stubEnv("CLAIM_TOKEN_HMAC_SECRET", "c".repeat(64));
    vi.stubEnv(UNSUBSCRIBE_SIGNING_SECRET_ENV, "u".repeat(64));

    expect(readUnsubscribeSigningSecret()).toEqual(
      Buffer.from("u".repeat(64), "utf8")
    );
  });
});

describe("unsubscribe credential generation", () => {
  it("uses the accepted format and canonical signed input", () => {
    const value = credential(SUBSCRIBER_ID, 3);
    const [id, version, signature] = parts(value);

    expect(id).toBe(SUBSCRIBER_ID);
    expect(version).toBe("3");
    expect(signature).toBe(
      createHmac("sha256", SECRET)
        .update(`commonplate:unsubscribe:v1:${SUBSCRIBER_ID}:3`, "utf8")
        .digest("base64url")
    );
    expect(signature).toMatch(/^[A-Za-z0-9_-]{43}$/);
  });

  it("is stable for the same subscriber, version, and secret", () => {
    // Nothing random and nothing time-based: this is what lets an emailed
    // link keep working indefinitely.
    expect(credential()).toBe(credential());
    expect(credential(SUBSCRIBER_ID, 7)).toBe(credential(SUBSCRIBER_ID, 7));
  });

  it("differs for a different subscriber", () => {
    expect(credential(SUBSCRIBER_ID)).not.toBe(credential(OTHER_SUBSCRIBER_ID));
  });

  it("differs for a different credential version", () => {
    expect(credential(SUBSCRIBER_ID, 1)).not.toBe(
      credential(SUBSCRIBER_ID, 2)
    );
  });

  it("differs under a different secret", () => {
    expect(credential(SUBSCRIBER_ID, 1, SECRET)).not.toBe(
      credential(SUBSCRIBER_ID, 1, OTHER_SECRET)
    );
  });

  it("treats a subscriber with no stored version as the initial version", () => {
    // Documents written before the field existed have never been revoked.
    expect(
      unsubscribeCredentialFor({ _id: SUBSCRIBER_ID }, SECRET)
    ).toBe(credential(SUBSCRIBER_ID, INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION));
  });

  it("reads only the identity fields off a subscriber", () => {
    expect(
      unsubscribeCredentialFor(
        {
          _id: SUBSCRIBER_ID,
          unsubscribeCredentialVersion: 5,
          // Anything else on the document is irrelevant to the signature.
          ...({ email: "helper@example.edu", status: "confirmed" } as object),
        },
        SECRET
      )
    ).toBe(credential(SUBSCRIBER_ID, 5));
  });

  it.each([
    ["a missing id", undefined],
    ["an empty id", ""],
    ["a short id", "64b0000000000000000000"],
    ["an uppercase id", SUBSCRIBER_ID.toUpperCase()],
    ["a non-hexadecimal id", "z".repeat(24)],
  ])("refuses to sign %s", (_label, subscriberId) => {
    expect(() =>
      signUnsubscribeCredential(subscriberId, 1, SECRET)
    ).toThrow(UnsubscribeCredentialError);
  });

  it.each([
    ["zero", 0],
    ["a negative version", -1],
    ["a fractional version", 1.5],
    ["a non-numeric version", "1"],
    ["a version past the ceiling", MAXIMUM_UNSUBSCRIBE_CREDENTIAL_VERSION + 1],
  ])("refuses to sign %s", (_label, version) => {
    expect(() =>
      signUnsubscribeCredential(SUBSCRIBER_ID, version, SECRET)
    ).toThrow(UnsubscribeCredentialError);
  });

  it("refuses a signing secret below the required length", () => {
    expect(() =>
      signUnsubscribeCredential(SUBSCRIBER_ID, 1, Buffer.alloc(31, 1))
    ).toThrow(UnsubscribeCredentialConfigurationError);
  });

  it("performs no database work", async () => {
    // Imported for its side effect only: if the module reached Mongoose, this
    // spy on the Subscriber model would record it.
    const { Subscriber } = await import("../models/db.js");
    const find = vi.spyOn(Subscriber, "findOne");
    const exists = vi.spyOn(Subscriber, "exists");

    credential();
    verifyUnsubscribeCredential(credential(), SECRET);

    expect(find).not.toHaveBeenCalled();
    expect(exists).not.toHaveBeenCalled();
    vi.restoreAllMocks();
  });
});

describe("unsubscribe credential verification", () => {
  it("accepts a credential it signed and reports its subject", () => {
    expect(verifyUnsubscribeCredential(credential(SUBSCRIBER_ID, 6), SECRET)).toEqual({
      subscriberId: SUBSCRIBER_ID,
      credentialVersion: 6,
    });
  });

  it("still accepts a credential signed at an older version", () => {
    // Cryptographic verification does not decide currency: a redemption route
    // compares the verified version against the stored one.
    expect(
      verifyUnsubscribeCredential(credential(SUBSCRIBER_ID, 1), SECRET)
    ).toEqual({ subscriberId: SUBSCRIBER_ID, credentialVersion: 1 });
  });

  it("rejects a modified subscriber id", () => {
    const [, version, signature] = parts(credential(SUBSCRIBER_ID, 2));

    expect(
      verifyUnsubscribeCredential(
        `${OTHER_SUBSCRIBER_ID}.${version}.${signature}`,
        SECRET
      )
    ).toBeNull();
  });

  it("rejects a modified credential version", () => {
    const [id, , signature] = parts(credential(SUBSCRIBER_ID, 2));

    expect(
      verifyUnsubscribeCredential(`${id}.3.${signature}`, SECRET)
    ).toBeNull();
  });

  it("rejects a modified signature", () => {
    const [id, version, signature] = parts(credential(SUBSCRIBER_ID, 2));
    const flipped = `${signature[0] === "A" ? "B" : "A"}${signature.slice(1)}`;

    expect(
      verifyUnsubscribeCredential(`${id}.${version}.${flipped}`, SECRET)
    ).toBeNull();
  });

  it("rejects a credential signed with another secret", () => {
    expect(
      verifyUnsubscribeCredential(
        credential(SUBSCRIBER_ID, 1, OTHER_SECRET),
        SECRET
      )
    ).toBeNull();
  });

  it.each([
    ["a non-string", 12345],
    ["null", null],
    ["undefined", undefined],
    ["an object", { credential: "x" }],
    ["an empty string", ""],
    ["no separators", "notacredential"],
    ["too few segments", `${SUBSCRIBER_ID}.1`],
    ["too many segments", `${SUBSCRIBER_ID}.1.aaa.bbb`],
    ["an empty signature", `${SUBSCRIBER_ID}.1.`],
    ["a short signature", `${SUBSCRIBER_ID}.1.${"a".repeat(42)}`],
    ["an over-long signature", `${SUBSCRIBER_ID}.1.${"a".repeat(44)}`],
    ["a non-base64url signature", `${SUBSCRIBER_ID}.1.${"a".repeat(42)}+`],
    ["a zero version", `${SUBSCRIBER_ID}.0.${"a".repeat(43)}`],
    ["a leading-zero version", `${SUBSCRIBER_ID}.01.${"a".repeat(43)}`],
    ["a signed version", `${SUBSCRIBER_ID}.+1.${"a".repeat(43)}`],
    ["a spaced version", `${SUBSCRIBER_ID}. 1.${"a".repeat(43)}`],
    ["a fractional version", `${SUBSCRIBER_ID}.1.5.${"a".repeat(43)}`],
    ["an enormous version", `${SUBSCRIBER_ID}.9999999999.${"a".repeat(43)}`],
    ["an uppercase id", `${SUBSCRIBER_ID.toUpperCase()}.1.${"a".repeat(43)}`],
    ["a short id", `64b0.1.${"a".repeat(43)}`],
  ])("fails safely on %s", (_label, candidate) => {
    expect(() =>
      expect(verifyUnsubscribeCredential(candidate, SECRET)).toBeNull()
    ).not.toThrow();
  });

  it("rejects a non-canonical spelling of a valid signature", () => {
    const [id, version, signature] = parts(credential(SUBSCRIBER_ID, 1));
    // Same 32 bytes, different text: one signature must have exactly one
    // accepted form, or two distinct credential strings would both verify.
    const padded = `${signature}=`;

    expect(
      verifyUnsubscribeCredential(`${id}.${version}.${padded}`, SECRET)
    ).toBeNull();
  });
});

describe("unsubscribe URL", () => {
  it("uses the configured public base URL and the accepted shape", () => {
    vi.stubEnv("BASE_URL", "https://commonplate.test/");

    const url = new URL(
      buildUnsubscribeUrl({ _id: SUBSCRIBER_ID, unsubscribeCredentialVersion: 2 }, SECRET)
    );

    expect(url.origin).toBe("https://commonplate.test");
    expect(url.pathname).toBe(UNSUBSCRIBE_ROUTE_PATH);
    expect([...url.searchParams.keys()]).toEqual([
      UNSUBSCRIBE_CREDENTIAL_PARAMETER,
    ]);
    expect(
      verifyUnsubscribeCredential(
        url.searchParams.get(UNSUBSCRIBE_CREDENTIAL_PARAMETER),
        SECRET
      )
    ).toEqual({ subscriberId: SUBSCRIBER_ID, credentialVersion: 2 });
  });

  it("falls back to the configured signing secret when none is supplied", () => {
    vi.stubEnv("BASE_URL", "https://commonplate.test");
    vi.stubEnv(UNSUBSCRIBE_SIGNING_SECRET_ENV, SECRET.toString("utf8"));

    expect(buildUnsubscribeUrl({ _id: SUBSCRIBER_ID })).toBe(
      buildUnsubscribeUrl({ _id: SUBSCRIBER_ID }, SECRET)
    );
  });
});
