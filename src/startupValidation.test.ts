import { spawn } from "node:child_process";
import { generateKeyPairSync } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  APNS_AUTH_KEY_P8_ENV,
  APNS_BUNDLE_ID_ENV,
  APNS_KEY_ID_ENV,
  APNS_TEAM_ID_ENV,
} from "./apnsConfig.js";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
import {
  MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES,
  UNSUBSCRIBE_SIGNING_SECRET_ENV,
} from "./unsubscribeCredential.js";

/**
 * The activation prerequisite: an unpaused process must not be able to start
 * without a signing secret for the unsubscribe links its emails will carry.
 *
 * Two kinds of assertion, because neither alone is enough. The wiring group
 * reads `app.ts` as text — it connects to MongoDB and listens at module scope,
 * so it cannot be imported — and pins where the check sits relative to the
 * Express app, the route registrations, the database connection, and `listen`.
 * The startup group then runs the real file in a child process and observes
 * what a deployment would actually do, which is the only way to prove that the
 * refusal happens before any of that work rather than merely above it in the
 * source.
 *
 * `unsubscribeCredential.test.ts` owns the validation rule itself.
 */
const repositoryRoot = fileURLToPath(new URL("..", import.meta.url));
const appPath = fileURLToPath(new URL("../app.ts", import.meta.url));
const appSource = readFileSync(appPath, "utf8");

const ACTIVATION_CALL = "assertUnsubscribeSigningSecretForActivation()";
const APNS_ACTIVATION_CALL = "assertApnsConfigurationForActivation()";

/**
 * Every production source a deployment secret's name could reach.
 * `src/client` is listed on its own: browser bundles are built from it, and a
 * server secret's name has no business reaching one.
 */
function productionSources(): (readonly [string, string])[] {
  return ["src", "src/client", "models", "scripts"].flatMap((directory) =>
    readdirSync(new URL(`../${directory}`, import.meta.url), {
      withFileTypes: true,
    })
      .filter(
        (entry) =>
          entry.isFile() &&
          /\.(ts|mjs)$/.test(entry.name) &&
          !entry.name.endsWith(".test.ts")
      )
      .map(
        (entry) =>
          [
            `${directory}/${entry.name}`,
            readFileSync(
              new URL(`../${directory}/${entry.name}`, import.meta.url),
              "utf8"
            ),
          ] as const
      )
  );
}

function indexIn(needle: string): number {
  const index = appSource.indexOf(needle);
  expect(index, `app.ts does not contain ${needle}`).toBeGreaterThan(-1);
  return index;
}

describe("unsubscribe signing secret activation wiring", () => {
  it("validates from the existing startup-validation block", () => {
    // One validation architecture, not a second one: the claim-token secret is
    // already checked here, and both refusals log a message and exit.
    const claimTokenCheck = indexIn("readClaimTokenHmacSecret();");
    const activationCheck = indexIn(ACTIVATION_CALL);
    const resendClient = indexIn("const resend = new Resend(resendApiKey);");

    expect(activationCheck).toBeGreaterThan(claimTokenCheck);
    expect(activationCheck).toBeLessThan(resendClient);
    expect(appSource).toContain("process.exit(1)");
  });

  it("is checked exactly once", () => {
    // A second call site is how two validation paths with different rules
    // start to drift apart.
    expect(
      appSource.match(/assertUnsubscribeSigningSecretForActivation\(/g)
    ).toHaveLength(1);
  });

  it("runs before the app, its routes, the database, and listening", () => {
    const activationCheck = indexIn(ACTIVATION_CALL);

    for (const later of [
      "const app = express();",
      "app.get(",
      "app.post(",
      "app.use(",
      "await mongoose.connect(MONGO_URI);",
      "await Fulfillment.createIndexes();",
      "app.listen(",
    ]) {
      expect(
        activationCheck,
        `the activation check must run before ${later}`
      ).toBeLessThan(indexIn(later));
    }
  });

  it("runs before the first point at which the process can yield", () => {
    // The scheduled digest is registered at the top of the file, above this
    // check. Registration is not delivery: a cron callback needs the event
    // loop, and module evaluation up to this point is synchronous, so the
    // process exits before any scheduled job can run. This pins that property
    // rather than assuming it.
    const activationCheck = indexIn(ACTIVATION_CALL);
    // Module-level awaits only: the ones inside the scheduled callbacks are
    // indented, and they cannot run before the module finishes evaluating.
    const firstTopLevelAwait = appSource.search(/^await\s/m);

    expect(firstTopLevelAwait).toBeGreaterThan(-1);
    expect(activationCheck).toBeLessThan(firstTopLevelAwait);
  });

  it("logs the reported message and no configured value", () => {
    const activationCheck = indexIn(ACTIVATION_CALL);
    // The catch block this call owns, ending at the first unindented brace
    // after it, rather than a fixed-width window that would run into the
    // unrelated configuration reads below.
    const blockEnd = appSource.indexOf("\n}\n", activationCheck);
    expect(blockEnd).toBeGreaterThan(activationCheck);
    const block = appSource.slice(activationCheck, blockEnd);

    expect(block).toContain("error.message");
    // Nothing may reach the log except the fixed message the validator built.
    expect(block).not.toContain("process.env");
    expect(block).not.toContain(UNSUBSCRIBE_SIGNING_SECRET_ENV);
  });

  it("keeps one module able to read the secret", () => {
    // Every path capable of reading the variable, enumerated: a second reader
    // is how an inconsistent rule — or a silent substitution of another
    // secret — would appear.
    const sources = [["app.ts", appSource] as const, ...productionSources()];

    const readers = sources
      .filter(([, text]) => text.includes(UNSUBSCRIBE_SIGNING_SECRET_ENV))
      .map(([name]) => name);

    expect(readers).toEqual(["src/unsubscribeCredential.ts"]);
  });
});

/**
 * The same activation architecture, for the APNs provider configuration that
 * helper new-request push delivery needs (Week 3 Day 6 Slice 6D). An
 * installation can already turn push on, and the accepted meaning of "push
 * alerts are on" is that this deployment is configured to submit through APNs,
 * so an unpaused process without provider configuration must not start.
 *
 * `apnsConfig.test.ts` owns the validation rule itself.
 */
describe("APNs provider configuration activation wiring", () => {
  it("validates from the same startup-validation block, after the signing secret", () => {
    const activationCheck = indexIn(ACTIVATION_CALL);
    const apnsCheck = indexIn(APNS_ACTIVATION_CALL);
    const resendClient = indexIn("const resend = new Resend(resendApiKey);");

    expect(apnsCheck).toBeGreaterThan(activationCheck);
    expect(apnsCheck).toBeLessThan(resendClient);
  });

  it("is checked exactly once", () => {
    expect(
      appSource.match(/assertApnsConfigurationForActivation\(/g)
    ).toHaveLength(1);
  });

  it("runs before the app, its routes, the database, and listening", () => {
    const apnsCheck = indexIn(APNS_ACTIVATION_CALL);

    for (const later of [
      "const app = express();",
      "app.get(",
      "app.post(",
      "app.use(",
      "await mongoose.connect(MONGO_URI);",
      "await PushDelivery.createIndexes();",
      "app.listen(",
    ]) {
      expect(
        apnsCheck,
        `the APNs activation check must run before ${later}`
      ).toBeLessThan(indexIn(later));
    }
    expect(apnsCheck).toBeLessThan(appSource.search(/^await\s/m));
  });

  it("logs the reported message and no configured value", () => {
    const apnsCheck = indexIn(APNS_ACTIVATION_CALL);
    const blockEnd = appSource.indexOf("\n}\n", apnsCheck);
    expect(blockEnd).toBeGreaterThan(apnsCheck);
    const block = appSource.slice(apnsCheck, blockEnd);

    expect(block).toContain("error.message");
    expect(block).not.toContain("process.env");
    for (const name of [
      APNS_TEAM_ID_ENV,
      APNS_KEY_ID_ENV,
      APNS_BUNDLE_ID_ENV,
      APNS_AUTH_KEY_P8_ENV,
    ]) {
      expect(block).not.toContain(name);
    }
  });

  it("keeps one module able to read the provider configuration", () => {
    // A second reader is how an inconsistent rule — or a silent substitution
    // of other key material — would appear.
    const readers = ["app.ts", ...productionSources()]
      .filter(([, text]) => text.includes(APNS_AUTH_KEY_P8_ENV))
      .map(([name]) => name);

    expect(readers).toEqual(["src/apnsConfig.ts"]);
  });

  it("creates the push deduplication index before listening", () => {
    // Two concurrent dispatches would otherwise both submit for the same
    // installation, and V1 has no retry path that could repair a duplicate.
    expect(indexIn("await PushDelivery.createIndexes();")).toBeLessThan(
      indexIn("app.listen(")
    );
  });
});

interface StartupResult {
  code: number | null;
  stderr: string;
  stdout: string;
}

/**
 * Starts the real `app.ts` with an explicitly built environment.
 *
 * The environment is constructed rather than inherited, and `DOTENV_CONFIG_PATH`
 * names a file that does not exist, so a developer's local `.env` cannot supply
 * a secret a case means to withhold. The database URI points at a closed port
 * with a short server-selection timeout: a process that gets as far as
 * connecting fails there quickly, which is exactly the signal that it passed
 * validation.
 */
function startApp(
  environment: Record<string, string>
): Promise<StartupResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ["--import", "tsx", appPath], {
      cwd: repositoryRoot,
      env: {
        DOTENV_CONFIG_PATH: "/nonexistent/commonplate-startup-test/.env",
        MONGO_URI:
          "mongodb://127.0.0.1:1/commonplate_startup_test?serverSelectionTimeoutMS=750",
        RESEND_API_KEY: "startup-test-key",
        CLAIM_TOKEN_HMAC_SECRET: "c".repeat(64),
        ...environment,
      },
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += String(chunk);
    });
    child.stderr.on("data", (chunk) => {
      stderr += String(chunk);
    });
    child.once("error", reject);
    child.once("exit", (code) => resolve({ code, stderr, stdout }));
  });
}

const VALID_SECRET = "u".repeat(MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES);
const SHORT_SECRET = "u".repeat(MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES - 1);

/** Generated per run: no key material is ever committed to the repository. */
const { privateKey: apnsAuthKey } = generateKeyPairSync("ec", {
  namedCurve: "prime256v1",
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
  publicKeyEncoding: { type: "spki", format: "pem" },
});

const VALID_APNS: Record<string, string> = {
  [APNS_TEAM_ID_ENV]: "ABCDE12345",
  [APNS_KEY_ID_ENV]: "KEY1234567",
  [APNS_BUNDLE_ID_ENV]: "org.commonplatenyu.CommonPlateios",
  [APNS_AUTH_KEY_P8_ENV]: apnsAuthKey,
};

/**
 * A process that reached `mongoose.connect` passed activation validation: the
 * connection is attempted after the check, after the Express app is built, and
 * after every route is registered.
 */
function reachedTheDatabase(result: StartupResult): boolean {
  return result.stderr.includes("MongooseServerSelectionError");
}

describe("real startup with and without the signing secret", () => {
  it(
    "refuses to start unpaused with no secret",
    async () => {
      const result = await startApp({ [PUBLIC_ACTIONS_PAUSED_ENV]: "false" });

      expect(result.code).toBe(1);
      expect(result.stderr).toContain(
        `Missing required environment variable: ${UNSUBSCRIBE_SIGNING_SECRET_ENV}`
      );
      // It never got as far as the database, so it never registered a usable
      // public-action surface or began listening either.
      expect(reachedTheDatabase(result)).toBe(false);
      expect(result.stdout).not.toContain("http://localhost");
    },
    30_000
  );

  it(
    "refuses to start unpaused with an empty secret",
    async () => {
      const result = await startApp({
        [PUBLIC_ACTIONS_PAUSED_ENV]: "false",
        [UNSUBSCRIBE_SIGNING_SECRET_ENV]: "",
      });

      expect(result.code).toBe(1);
      expect(result.stderr).toContain(UNSUBSCRIBE_SIGNING_SECRET_ENV);
      expect(reachedTheDatabase(result)).toBe(false);
    },
    30_000
  );

  it(
    "refuses to start unpaused with fewer than 32 UTF-8 bytes",
    async () => {
      const result = await startApp({
        [PUBLIC_ACTIONS_PAUSED_ENV]: "false",
        [UNSUBSCRIBE_SIGNING_SECRET_ENV]: SHORT_SECRET,
      });

      expect(result.code).toBe(1);
      expect(result.stderr).toContain(
        `${UNSUBSCRIBE_SIGNING_SECRET_ENV} must contain at least ${MINIMUM_UNSUBSCRIBE_SIGNING_SECRET_BYTES} UTF-8 bytes`
      );
      // The refused value itself must not reach the deployment log.
      expect(result.stderr).not.toContain(SHORT_SECRET);
      expect(result.stdout).not.toContain(SHORT_SECRET);
      expect(reachedTheDatabase(result)).toBe(false);
    },
    30_000
  );

  it(
    "starts unpaused with a valid secret",
    async () => {
      const result = await startApp({
        [PUBLIC_ACTIONS_PAUSED_ENV]: "false",
        [UNSUBSCRIBE_SIGNING_SECRET_ENV]: VALID_SECRET,
        // Unpaused startup also requires APNs provider configuration; that
        // rule has its own group below.
        ...VALID_APNS,
      });

      expect(result.stderr).not.toContain(UNSUBSCRIBE_SIGNING_SECRET_ENV);
      // Past validation and into the database connection this environment
      // deliberately cannot satisfy.
      expect(reachedTheDatabase(result)).toBe(true);
      expect(result.stderr).not.toContain(VALID_SECRET);
      expect(result.stdout).not.toContain(VALID_SECRET);
    },
    30_000
  );

  it.each([
    ["with no secret", {}],
    [
      "with a valid secret",
      { [UNSUBSCRIBE_SIGNING_SECRET_ENV]: VALID_SECRET },
    ],
  ])(
    "starts while paused %s",
    async (_label, secret) => {
      const result = await startApp({
        [PUBLIC_ACTIONS_PAUSED_ENV]: "true",
        ...secret,
      });

      expect(result.stderr).not.toContain(UNSUBSCRIBE_SIGNING_SECRET_ENV);
      expect(reachedTheDatabase(result)).toBe(true);
    },
    30_000
  );

  it(
    "starts while paused by default, with no pause variable set at all",
    async () => {
      // The repository's existing reading of the variable: absent is paused.
      // A local process serving unrelated functionality must not be asked for
      // a secret no paused path can use.
      const result = await startApp({});

      expect(result.stderr).not.toContain(UNSUBSCRIBE_SIGNING_SECRET_ENV);
      expect(reachedTheDatabase(result)).toBe(true);
    },
    30_000
  );
});

describe("real startup with and without APNs provider configuration", () => {
  function unpaused(overrides: Record<string, string> = {}) {
    return {
      [PUBLIC_ACTIONS_PAUSED_ENV]: "false",
      [UNSUBSCRIBE_SIGNING_SECRET_ENV]: VALID_SECRET,
      ...VALID_APNS,
      ...overrides,
    };
  }

  it.each([
    APNS_TEAM_ID_ENV,
    APNS_KEY_ID_ENV,
    APNS_BUNDLE_ID_ENV,
    APNS_AUTH_KEY_P8_ENV,
  ])(
    "refuses to start unpaused without %s",
    async (name) => {
      const result = await startApp(unpaused({ [name]: "" }));

      expect(result.code).toBe(1);
      expect(result.stderr).toContain(name);
      // It never got as far as the database, so it never registered a usable
      // public-action surface or began listening either.
      expect(reachedTheDatabase(result)).toBe(false);
      expect(result.stdout).not.toContain("http://localhost");
    },
    30_000
  );

  it.each([
    [APNS_TEAM_ID_ENV, "TOO-SHORT"],
    [APNS_KEY_ID_ENV, "ELEVENCHARS"],
    [APNS_BUNDLE_ID_ENV, "not a bundle id"],
    [APNS_AUTH_KEY_P8_ENV, "-----BEGIN PRIVATE KEY-----\nnot-a-key\n"],
  ])(
    "refuses to start unpaused with a malformed %s",
    async (name, value) => {
      const result = await startApp(unpaused({ [name]: value }));

      expect(result.code).toBe(1);
      expect(result.stderr).toContain(name);
      // The refused value itself must not reach the deployment log.
      expect(result.stderr).not.toContain(value);
      expect(result.stdout).not.toContain(value);
      expect(reachedTheDatabase(result)).toBe(false);
    },
    30_000
  );

  it(
    "starts unpaused with complete provider configuration and never logs the key",
    async () => {
      const result = await startApp(unpaused());

      expect(reachedTheDatabase(result)).toBe(true);
      for (const output of [result.stderr, result.stdout]) {
        expect(output).not.toContain(apnsAuthKey);
        expect(output).not.toContain("BEGIN PRIVATE KEY");
        expect(output).not.toContain(VALID_APNS[APNS_TEAM_ID_ENV]);
      }
    },
    30_000
  );

  it(
    "starts while paused with no APNs configuration at all",
    async () => {
      // A paused process reads none of the four variables, exactly like the
      // unsubscribe signing secret above.
      const result = await startApp({
        [PUBLIC_ACTIONS_PAUSED_ENV]: "true",
      });

      expect(reachedTheDatabase(result)).toBe(true);
      for (const name of [
        APNS_TEAM_ID_ENV,
        APNS_KEY_ID_ENV,
        APNS_BUNDLE_ID_ENV,
        APNS_AUTH_KEY_P8_ENV,
      ]) {
        expect(result.stderr).not.toContain(name);
      }
    },
    30_000
  );
});
