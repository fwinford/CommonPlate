# CommonPlate verification guide

## 1. Verification overview

| Type | Command | Purpose | Important limitation |
| --- | --- | --- | --- |
| TypeScript checking | `npm run typecheck` | Checks the TypeScript source and tests without emitting files. | It does not exercise runtime behavior. |
| Backend unit/source-wiring tests | `npm test` | Runs Vitest unit, browser-behavior, and source-wiring tests. | Mongo suites are skipped without their integration environment. |
| Mongo integration tests | `npm run test:mongo` | Runs the real-Mongo replica-set suites. | Requires local `mongod` and `mongosh`. |
| Browser bundle generation | `npm run build:client` | Rebuilds tracked browser bundles from client TypeScript. | A successful build does not decide whether bundle diffs are intended. |
| iOS tests | See [section 9](#9-complete-terminal-ios-test-command). | Builds and runs `CommonPlateiosTests` on a simulator. | Compilation alone is not a passing test run. |
| Diff validation | `git diff --check` | Detects whitespace errors in unstaged changes. | It does not establish behavioral correctness. |

## 2. Node and dependency setup

Install dependencies with:

```bash
npm install
```

The repository supplies npm scripts and dependency versions in `package.json`; it does not declare a Node version. Configure local runtime values by copying `.env.example` to an untracked `.env` and replacing placeholders with local development values. Never copy secrets, real URIs, or personal values into tracked files.

For app startup, the configured MongoDB deployment must support transactions; a local single-member replica set is sufficient. The test runner itself does not require app startup.

## 3. TypeScript checking

Run:

```bash
npm run typecheck
```

This runs `tsc -p tsconfig.typecheck.json`. That configuration checks the application, `src`, browser-client source, scripts, and TypeScript test files with no emitted output. The production `tsconfig.json` intentionally excludes `**/*.test.ts`, so `npm run build` does not emit tests or require Vitest types in a production install.

Typechecking validates static TypeScript compatibility; it does not validate routes, MongoDB transactions, email-provider behavior, browser execution, or iOS behavior.

## 4. Backend unit and source-wiring tests

Run:

```bash
npm test
```

The current accepted baseline is **611 passed, 127 Mongo-gated skipped**, across **30 files passed, 10 files skipped, 40 files total**. Skipped Mongo suites are not failures. This command does not execute the real-Mongo transactional suite; run `npm run test:mongo` separately.

Representative coverage includes validation, route logic, error envelopes, browser behavior, copy guards, and source-wiring assertions. Some tests read source text instead of importing `app.ts`, because `app.ts` connects to MongoDB and starts listening at module scope. These assertions are not end-to-end route tests.

Consequences:

- Broad `app.ts` formatting or route-registration changes can break source-text assertions.
- README and web-copy changes can be pinned by tests.
- A repository-wide production-source guard rejects the phrase `within the next hour`.
- Vitest sets `process.env.BASE_URL` to `/`. A test that asserts an absolute emailed link must stub `BASE_URL` itself rather than relying on the production default.

### Confirmation coverage

The confirmation flow adds, relative to the previous baseline:

- 53 focused unit/HTTP cases in `src/confirmSubscriptionRoute.test.ts`;
- 2 real-Mongo HTTP cases in `src/confirmSubscriptionRoute.mongo.test.ts`;
- 6 additional public-route wiring/order assertions.

Slice 3A (`src/confirmSubscription*.test.ts`) proves the atomic pending-to-confirmed transition, concurrency and idempotent loser behavior, field cleanup, the bounded used-token receipt, send-lease interactions, and outcome classification. Since Day 4 Slice 4A it also proves confirmation issues no unsubscribe credential and never touches `unsubscribeCredentialVersion`.

Slice 3B (`src/confirmSubscriptionRoute*.test.ts`) proves the safe non-mutating GET, the explicit form POST, actual URL-encoded body handling, that the pause runs before parsing and limiter work, that malformed JSON cannot bypass the route, sanitized parser-error behavior, the POST-only 5-per-60-second limiter, the required HTML security headers, the absence of internal-detail leakage, the browser outcome mapping, real HTTP-to-Mongo confirmation, and that a repeated HTTP POST mutates the document no further.

### Unsubscribe credential coverage

Day 4 Slice 4A adds, relative to the confirmation baseline:

- 73 focused cases in `src/unsubscribeCredential.test.ts` — 53 at this slice, the rest added by the Slice 4B review fixes below: signing-secret configuration, credential format and canonical signed input, stability, per-subscriber and per-version distinctness, strict parsing, constant-time verification, wrong-secret and tampering rejection, malformed input that fails without throwing, absence of any database work, and the emitted URL shape;
- unsubscribe-link cases in `src/emailHelpers.test.ts` and `src/sendDigestEmail.test.ts` proving both send paths emit a correctly formed link whose extracted credential verifies, need no stored raw token, and do not rotate between sends;
- re-signup preservation cases in `src/subscribeRoute.test.ts` and `src/subscribeRoute.mongo.test.ts` proving signup names none of `unsubscribeCredentialVersion`, the delivery counters, or the unsubscribe history;
- `models/db.test.ts` cases for the bounded version field, its default, the removal of the stored-digest invariant, and the legacy raw `unsubToken` being excluded from ordinary projections, with `models/db.mongo.test.ts` proving that exclusion against real MongoDB while leaving the stored value in place;
- `src/publicActionsRoutes.test.ts` guards that no `/unsubscribe` route is registered and that signup and delivery stay paused.

Both send paths take an optional injected signing secret so these tests configure signing directly instead of mutating the process environment.

### Unsubscribe redemption coverage

Day 4 Slice 4B adds, relative to the credential baseline:

- 33 focused cases in `src/unsubscribeSubscriber.test.ts`: which links the primitive accepts, that an unusable one never reaches Mongo, the legacy/rotated stored-version comparison through `resolveUnsubscribeCredentialVersion`, the exact conditional filter (`$exists: false` versus the exact stored value), the single-update pipeline it writes, the exact cleared set — the active confirmation and send-attempt fields plus the bounded confirmation receipt, asserted against the shared definitions rather than a restated list — the fields it refuses to touch, and a conditional-update miss reported as the generic invalid result;
- 39 focused HTTP cases in `src/unsubscribeRoute.test.ts`: the non-mutating GET, the explicit form POST, the one page rendered for every subscriber status, one generic invalid page for every unusable link, the pause running ahead of verification, lookup, mutation, and the limiter, the POST-only 5-per-60-second limiter, the required security headers, sanitized parser-error behaviour, the fixed log lines, and the copy and page-structure guards;
- 36 real-Mongo cases in `src/unsubscribeRoute.mongo.test.ts`: the GET writing nothing for pending, confirmed, and unsubscribed rows, the atomic transition from each of those statuses, the pending row's confirmation link becoming unusable afterwards, idempotent repeats compared over the whole document, preserved identity/version/counters/send history, legacy and rotated versions, a version rotation landing between validation and update, and an unsubscribed row leaving the confirmed delivery pool;
- within those, a confirmation-lifecycle group added by the confirmation-receipt correction: a confirmed row holding a live receipt unsubscribing and losing it, the reopened confirmation link no longer able to claim the address is confirmed, the old credential posting back the existing invalid result without writing, a re-signup issuing a fresh pending credential on the same row and version, and the original emailed unsubscribe credential still working after re-signup and reconfirmation;
- `src/publicActionsRoutes.test.ts` guards for the two new registrations, their middleware order, registration ahead of the global parsers, and signup and delivery still being paused.

The independent-review fixes add, within those files:

- stored-version resolution cases in `src/unsubscribeCredential.test.ts` proving `undefined` resolves to version 1 while `null` is rejected alongside every other malformed value, and that valid versions — including the schema default of 1 — pass through unchanged;
- primitive cases in `src/unsubscribeSubscriber.test.ts` proving a persisted `null` produces the generic invalid result on both the check and the mutation without reaching `updateOne`, and that no stored state ever produces a `{unsubscribeCredentialVersion: null}` filter;
- real-Mongo cases proving a physically null row is refused generically on GET and POST at every credential version, keeps its status, and retains its physical `null`; and that a legacy row's atomic filter is captured as `{$exists: false}` while the real update still runs;
- a `tamperCredentialSignature` fixture helper, defined per test file like the other small fixture helpers and regression-tested once in `src/unsubscribeCredential.test.ts`, that swaps between two canonical trailing base64url characters so a tampered credential always differs from the authentic one. Every tampering fixture asserts both that difference and a failed `verifyUnsubscribeCredential` before submitting, and the Mongo suite covers both an authentic signature ending in `A` and one that does not, using deterministically searched subscriber ids rather than sampled ones.

### Activation validation coverage

Day 4 Slice 4C adds startup validation of `UNSUBSCRIBE_SIGNING_SECRET` and its coverage:

- 15 focused cases in `src/unsubscribeCredential.test.ts` for the activation rule itself — the paused rows, the unpaused rows for an absent, empty, short, exactly-32-byte, and longer secret, that a paused check never reads the variable, that the byte count is UTF-8 bytes rather than JavaScript characters in both directions, that no other configured secret is substituted, and that the reported failure names the variable but never its value. These cases describe environments as plain objects rather than stubbed process variables, so none of them can leak configuration into another;
- 13 cases in `src/startupValidation.test.ts`. Six read `app.ts` as text and pin where the check sits: inside the existing environment-validation block, exactly once, before the Express app, every route registration, `mongoose.connect`, `Fulfillment.createIndexes`, `app.listen`, and the first module-level `await`; that the catch logs only the reported message; and that `src/unsubscribeCredential.ts` is the only production module able to read the variable. The remaining seven run the real `app.ts` in a child process and observe the whole table end to end.

Those child processes are given an explicitly constructed environment rather than an inherited one, and `DOTENV_CONFIG_PATH` names a file that does not exist, so a developer's local `.env` can neither supply a secret a case means to withhold nor withhold one it means to supply. `MONGO_URI` points at a closed local port with a short server-selection timeout: a refused startup never reaches it, and a permitted startup fails there quickly, which is the signal that it passed validation. No real database is contacted.

### Lifecycle acceptance coverage

`src/subscriptionLifecycle.mongo.test.ts` (Slice 4C) is 20 real-Mongo acceptance cases for the complete backend email lifecycle, driven through the production route registrations, handlers, helpers, and emails: signup writing one pending Subscriber and rotating rather than duplicating on a repeat; the confirmation email carrying the token whose digest that row holds; the confirmation GET mutating nothing however often it is opened; the explicit POST transitioning pending to confirmed without moving the credential version; eligibility appearing only after that POST, proved through the real alert path rather than a query; a real-time alert and a digest each carrying a credential that verifies for exactly that subscriber and opens the real unsubscribe route; the unsubscribe GET mutating nothing; the explicit POST transitioning the row and clearing the active confirmation fields and the bounded receipt; idempotent repeats compared over the whole document; the address leaving later alert and digest selection; re-signup preserving `_id`, credential version, counters, send history, and unsubscribe history while issuing a fresh credential that retires the previous one; reconfirmation restoring eligibility with the original emailed link still working; no raw credential or signature persisted in any collection; and paused signup, confirmation, unsubscribe, alert, and digest paths all refusing before their protected work.

Only the email provider is replaced, at the existing `resend` boundary, so `emailHelpers.ts` composes the real messages and links. The one selection the suite reproduces rather than calls is the hourly digest query, which lives in the `app.ts` cron and cannot be imported; `src/publicActionsRoutes.test.ts` pins that query's `status: "confirmed"` against the real source.

### NYU alert-signup allowlist coverage

Week 3 Day 5 Slice 5A adds, relative to the lifecycle-acceptance baseline:

- 29 cases in `src/allowedEmailDomains.test.ts` for the exact-domain helper — the allowlist's exact contents, trimming and lowercasing, reading the domain after the final `@`, values with no usable domain, plus-addressing on an allowed domain, and the lookalike, unlisted-subdomain, and suffix/substring addresses a `hasSuffix("nyu.edu")` or `includes` check would wrongly accept;
- 9 cases in `src/subscribeRoute.test.ts` for the route. Six prove a non-allowlisted address is refused with the shared `INVALID_EMAIL` envelope **before any database work**, asserting that `Subscriber.findOne`, `Subscriber.create`, `Subscriber.findOneAndUpdate`, the token generator, and the confirmation sender are each never called. Three prove an allowed address is still normalized before its lookup;
- 26 cases in `ios/CommonPlateios/CommonPlateiosTests/AlertSignupTests.swift`. The original 21 cover the iOS allowlist, the single normalized POST through the existing `APIClient`, duplicate-submit refusal while a signup is in flight and after acceptance, the generic accepted state, and the distinct mapping of local invalid email, backend `INVALID_EMAIL`, paused signup, HTTP 429, `CONFIRMATION_EMAIL_UNAVAILABLE`, transport and undecodable-body ambiguity, and bounded unknown failure — plus copy guards proving no accepted or failure message claims a subscription, confirmation, active alerts, or a sent email. Five review-response cases were added: three pin the cancellation split described below, and two pin that `Use a different email` empties the field, sends nothing, and is ignored outside the accepted state.

No existing lifecycle assertion changed for this slice. Eight fixture addresses in `src/subscribeRoute.test.ts`, `src/subscribeRoute.mongo.test.ts`, `src/subscriptionLifecycle.mongo.test.ts`, and `src/unsubscribeRoute.mongo.test.ts` moved from `@example.edu` to `@nyu.edu` because those cases drive the real subscribe handler, which now refuses the former. The Mongo suites gained and lost no cases, so `npm run test:mongo` is unchanged at 127.

Cancellation is two outcomes, and `AlertSignupTests.swift` pins both. Cancellation observed before transmission is definitive — nothing was encoded or handed to the transport — and `AlertSubscriptionService` translates it into its own definitive failure rather than letting a raw `CancellationError` escape to be classified by whoever catches it; the service-level case fails if that translation is removed. Cancellation from transmission onward stays conservatively ambiguous, and its case cancels only after the stub has recorded the request, so the body is provably on the wire first. Known limit: `APIClient` reports cancellation from three points — before `URLSession` is called, from a cancelled transport, and after a response was already received. The first is pinned directly and the other two are pinned as a pair; separating them would require suspending the stub mid-response and reaching into `APIClient` internals, and both are ambiguous by design, so that distinction is documented rather than tested.

The Slice 4B mongo suite drives the production handlers, so it stubs both `PUBLIC_ACTIONS_PAUSED` and `UNSUBSCRIBE_SIGNING_SECRET` per case rather than injecting a secret. Fixtures that describe malformed persisted state — a physically absent version field, or a physical `null` — are written through the driver, because the schema default, its bounds, and its integer validator would otherwise replace or reject them before they reached the collection. Its lifecycle cases also mount the confirmation routes and call the signup handler directly, so that file replaces `emailHelpers.js` — whose module scope constructs a Resend client that refuses to build without an API key — and injects its own send function. Pause middleware is unaffected: signup, confirmation, and unsubscribe all remain paused in production registration.

## 5. Mongo integration tests

Run:

```bash
npm run test:mongo
```

The current accepted baseline is **127 passed across 10 files**. `mongod` and `mongosh` must both be on `PATH`. The script creates a temporary data directory, starts a temporary single-member replica set on a free local port, initializes it, injects an isolated `MONGO_INTEGRATION_URI`, runs `*.mongo.test.ts`, and removes the temporary database directory afterward.

A replica set is required because placement verification exercises MongoDB transactions; standalone MongoDB cannot provide that behavior. Mongo verification remains incomplete until this command passes. `npm test` reporting the Mongo suites as skipped does not replace this run.

`MONGO_INTEGRATION_URI` is an integration-test environment input. Do not set it to a real shared or production URI.

Mongo test files execute concurrently against one temporary replica set, and suites that clear a whole collection between cases can therefore delete another file's fixtures. Suites sharing a collection must not share a database. Six suites currently touch `Subscriber`, each in its own database:

| Suite | Database |
| --- | --- |
| `src/subscribeRoute.mongo.test.ts` (Day 2 signup) | The runner URI's default database |
| `src/confirmSubscription.mongo.test.ts` (Slice 3A) | `commonplate_confirmation_test` |
| `src/confirmSubscriptionRoute.mongo.test.ts` (Slice 3B) | `commonplate_confirmation_route_test` |
| `src/unsubscribeRoute.mongo.test.ts` (Slice 4B) | `commonplate_unsubscribe_test` |
| `src/subscriptionLifecycle.mongo.test.ts` (Slice 4C) | `commonplate_lifecycle_test` |
| `models/db.mongo.test.ts` (schema projection) | `commonplate_subscriber_schema_test` |

Each of these suites clears state with `Subscriber.deleteMany({})`. The distinct databases are what prevent one suite's cleanup from deleting a concurrently executing suite's fixtures. Apply the same isolation to any new suite that clears a shared collection.

`src/subscriptionLifecycle.mongo.test.ts` additionally clears `Request`, `SendLog`, and `System`, because it drives the real alert path. Those collections are also used by the claim, fulfillment, and availability suites in the runner URI's default database; its own database is what keeps the two apart.

`scripts/run-mongo-integration.mjs` runs all `.mongo.test.ts` files and does not currently support forwarding a single test-file argument. A requested focused Mongo verification therefore necessarily executes the complete Mongo-gated suite.

## 6. Browser-client bundles

Edit `src/client/*.ts`; never edit `public/js/*.js` directly. Rebuild with:

```bash
npm run build:client
```

The generated bundles are tracked and begin with a generated-file banner. After rebuilding, inspect `git diff` and confirm that only expected bundle changes are present. Current tooling does not independently fail CI merely because regenerated bundles differ, so the reviewer must verify the diff. No generated-output enforcement check exists.

## 7. iOS prerequisites

Full Xcode is required; Command Line Tools alone are insufficient. Verify the selected developer directory with:

```bash
xcode-select -p
```

The expected form is `/Applications/Xcode.app/Contents/Developer`. Correct it when necessary with:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

The project is `ios/CommonPlateios/CommonPlateios.xcodeproj`; its shared scheme is `CommonPlateios` and its unit-test target is `CommonPlateiosTests`. The project targets iOS 26.5, so use Xcode with the required SDK and simulator runtime.

## 8. Discovering an available simulator

Run:

```bash
xcrun simctl list devices available
```

Choose an available iPhone simulator from that output and copy its UDID into the test command. Do not assume a particular model exists on every machine.

## 9. Complete terminal iOS test command

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/CommonPlateios/CommonPlateios.xcodeproj \
  -scheme CommonPlateios \
  -destination 'platform=iOS Simulator,id=<AVAILABLE_SIMULATOR_UDID>' \
  -derivedDataPath /tmp/CommonPlate-Tests-DerivedData \
  -only-testing:CommonPlateiosTests
```

The current accepted baseline is **284 passed, 0 failed, 0 skipped, TEST SUCCEEDED**. Compilation alone is not a passing test result: the result bundle must complete and the output must contain `TEST SUCCEEDED`. Xcode GUI and terminal runs use the same shared scheme and `CommonPlateiosTests` target.

## 10. Test-file organization

Add new Week 3 iOS tests in new focused files where practical. Do not keep extending `ClaimFlowTests.swift` merely because it already contains related tests. Preserve existing test files rather than splitting them during unrelated feature work, and keep one endpoint and one user-flow slice per test change. This does not prescribe a new test framework or UI-test target.

## 11. Verification by change type

| Change | Minimum verification |
| --- | --- |
| Backend TypeScript only | Typecheck, focused tests, and `npm test`. |
| Mongo mutation/transaction | The backend checks above plus `npm run test:mongo`. |
| Browser source | Focused browser tests, typecheck, and `npm run build:client`. |
| iOS production or test change | Focused tests plus the complete `CommonPlateiosTests` target. |
| Cross-stack contract | All affected backend and iOS suites. |
| Comment/document-only | `git diff --check` and content review; run tests only when executable behavior is also pending in the same working tree. |

`npm run ci-check` runs lint, typecheck, prune, and build. It does not run the test suites.

## 12. Final diff checks

Run:

```bash
git diff --check
git diff --cached --check
git status
```

Before committing, inspect generated files, new tracked documentation, and deleted files; each must be intentional. Confirm that local weekly specifications and archived working documents under `docs/` remain ignored and unstaged.

## 13. Current verification baseline

These results are a reference baseline, not a substitute for rerunning affected checks after future changes. Every row was last recorded at the Week 3 Day 5 Slice 5A NYU alert-signup allowlist slice, including the iOS row, which was re-run for that slice because it changed iOS code.

| Check | Result |
| --- | --- |
| `npm run typecheck` | Passed |
| `npm test` | 611 passed; 127 Mongo-gated skipped (30 files passed, 10 skipped, 40 total) |
| `npm run test:mongo` | 127 passed across 10 files |
| `npm run ci-check` | Passed (lint, typecheck, prune, build) |
| `CommonPlateiosTests` | 284 passed; 0 failed; 0 skipped; TEST SUCCEEDED |
| `npm run build:client` | Not re-run at this closeout; no browser-client source changed |
| `git diff --check` | Passed |
