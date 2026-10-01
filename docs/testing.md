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

The current accepted baseline is **990 passed, 172 Mongo-gated skipped**. Skipped Mongo suites are not failures. This command does not execute the real-Mongo transactional suite; run `npm run test:mongo` separately.

Representative coverage includes validation, route logic, error envelopes, browser behavior, copy guards, and source-wiring assertions. Some tests read source text instead of importing `app.ts`, because `app.ts` connects to MongoDB and starts listening at module scope. These assertions are not end-to-end route tests.

Consequences:

- Broad `app.ts` formatting or route-registration changes can break source-text assertions.
- README and web-copy changes can be pinned by tests.
- A repository-wide production-source guard rejects the superseded ASAP phrasings `within the next hour` and `within the next 5 hours`, and rejects any production sentence that names an expiration in hours other than three. It scans `src`, `public`, and `ios/CommonPlateios/CommonPlateios`, skipping test files and sourcemaps, so a stale generated bundle fails it until `npm run build:client` is rerun.
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

### NYU food-request allowlist coverage

Week 3 Day 5 Slice 5B applies the same allowlist to `POST /api/request` and the iOS Request Food form, adding, relative to the alert-signup baseline:

- 23 cases in `src/createRequestRoute.test.ts`. They prove acceptance and normalization of both exact domains including uppercase, surrounding whitespace, and plus-addressing — asserted on the persisted document, the daily-limit count, and the requester email, so all three use the normalized address; refusal of malformed, non-NYU, lookalike, and unlisted-subdomain addresses with the `INVALID_EMAIL` envelope; the same rule on the canonical scheduled and legacy web shapes; and that a refused address reaches no side effect, asserted as `Request.countDocuments`, `Request.create`, the Resend send, and `notifySubscribersForRequest` each never being called. Two further cases pin precedence: a missing or blank `email` keeps the generic `INVALID_REQUEST` payload message, and so does a bad address accompanied by a blank field, a bad `timing`, an unexpected key, or an ended window;
- 21 cases in `ios/CommonPlateios/CommonPlateiosTests/RequestEmailAllowlistTests.swift`. They prove both exact domains, uppercase and whitespace normalization, plus-addressing, and the malformed, non-NYU, lookalike, and unlisted-subdomain refusals; that the empty field keeps its own distinct message; that a refused address blocks submission, focuses the email field, and — driven through the real store, service, `APIClient`, and `URLSession` — issues no HTTP request and never arms the process-lifetime create block, while an allowed address still posts once and creates; that every other entered value and the timing selection survive an email rejection with only the email field marked presented; that a backend `INVALID_EMAIL` maps to the same sentence without showing the backend's own wording, and that every other create code and the ambiguous and in-progress outcomes map exactly as before; and that submit enabling, the duplicate-submit refusal, and the ambiguity guard are unchanged. Six of those cases cover the pre-entry eligibility notice: its exact sentence, that every `@`-prefixed token in it is an allowed domain and every allowed domain appears in it — so the copy and `NYUEmailPolicy.allowedDomains` cannot drift apart — that it is distinct from the validation message, the empty-field message, and the purpose notice, that the validator never emits it for any input and a rejected address still produces its own error, and that it promises no email delivery.

Those six cases are copy and validator tests: they cover the sentence and its relationship to the validation errors, not where or how it is drawn. There is no UI-test target, so four properties of the pre-entry notice were **verified by code inspection of `RequestFoodView.swift` only, not by automated UI verification**:

- that it is rendered before submission — the `Text` is unconditional, with no dependence on `validationPresentation`, `errors`, or `submissionError`;
- that it remains visible during editing — the same absence of any focus or edit-state condition;
- that it uses scalable `.footnote` typography with vertical expansion — `.font(.footnote)` plus `.fixedSize(horizontal: false, vertical: true)`;
- that it appears in the intended accessibility reading order — placed between the email `TextField` and `fieldErrorText`, carrying `request-email-eligibility`, and adding nothing to the field's `accessibilityHint`, which the error still owns.

A future UI-test target would be what actually pins those four. Until then, changes to that section's layout, styling, or ordering will not be caught by `CommonPlateiosTests`.

**Superseded by W3-I3.** The pre-entry eligibility notice and its six cases, and the code-inspection properties above, describe Request Food's former Contact section, which W3-I3 removed entirely (see the W3-I3 coverage subsection below). They are preserved here as the historical record of Slice 5B; they are no longer present in `RequestEmailAllowlistTests.swift` or `RequestFoodView.swift`.

`src/allowedEmailDomains.test.ts` already proves the helper matrix, so it gained no cases. The route suite's requester fixtures moved from `@example.edu` to `@nyu.edu` for the same reason the signup fixtures did in Slice 5A: they drive the real handler, which now refuses the former. One existing iOS assertion changed — `testEmptyAndMalformedEmailHaveDistinctCopy` now expects the NYU sentence for a malformed address, and additionally asserts that the empty and malformed messages still differ.

No Mongo suite drives `POST /api/request`, so no Mongo fixture changed and `npm run test:mongo` is unchanged at 127. No browser-client source changed; `src/client/new-request.ts` already decodes `error` as a string or `{code, message}` and renders the message, which `src/client/new-request.test.ts` already proves, so the new envelope cannot render as `[object Object]`.

### Cross-launch check-email presentation coverage

Week 3 Day 5 Slice 5C makes the iOS `Check your email` screen survive relaunch. It changes no backend file, so no backend or Mongo suite was rerun and both remain at their Slice 5B totals. It adds **21 cases in `ios/CommonPlateios/CommonPlateiosTests/AlertSignupPresentationTests.swift`**, and `AlertSignupTests.swift` is unchanged at 26 cases with every assertion preserved — only its store factory now passes an in-memory presentation storage.

The new cases prove that a generic 202 persists the normalized submitted address and the response time; that a store rebuilt over the same stored value — which is what launch does — restores the `checkEmail` phase, the remembered address, an empty draft, and no error state; that the restored screen is the existing accepted copy and that no observable property, record field, or storage key is named `subscriptionStatus`, `isSubscribed`, `isConfirmed`, `activeSubscriber`, or `pendingSubscriber`; that `Use a different email` removes the stored value, empties the draft, forgets the remembered address, and sends nothing; that a store rebuilt after clearing returns to editing; that a later accepted address replaces the earlier record with exactly one record remaining; and that `Done` — which dismisses the screen and calls nothing on the store — leaves the record for the next launch.

Seven cases cover the failure boundary. A locally rejected address, a backend `INVALID_EMAIL`, the paused bare 503, HTTP 429, `CONFIRMATION_EMAIL_UNAVAILABLE`, a transport-loss ambiguity, and a definitive unknown failure each perform **zero writes and zero deletes**, asserted as counts on an in-memory storage double rather than by inspecting the record — a preserved record and a destroyed-then-rewritten one are otherwise indistinguishable. One further case proves a failing attempt cannot destroy an existing accepted record at all: submission is refused outside `editing`, so a store holding a restored record sends nothing and writes nothing, and only the explicit `Use a different email` removes it.

Four cases cover unusable stored data, driven through a real `UserDefaults` suite: unparseable JSON, an incomplete record, an array in place of the record, and a value of the wrong type entirely; a stored address that no longer satisfies the NYU rule; and a missing, empty, unparseable, `null`, or numeric timestamp. Each is removed rather than left to be re-rejected, each leaves the editable form, and none crashes initialization. Restoring and rejecting are both proved to issue no HTTP request, since no endpoint reports subscription status.

Every store in the new file is given isolated persistence — either the in-memory double or a `UserDefaults` suite named per test and removed in `tearDown` — and one case asserts directly that the run leaves nothing in `UserDefaults.standard`. `AlertSubscriptionStore`'s storage argument has no default value, so a test cannot reach real preferences by omitting it.

"Relaunch" here means reconstructing `AlertSubscriptionStore` over the same persisted value, exactly as `ContentView` builds one at launch — no manual kill-and-relaunch walkthrough on a simulator or device was performed for this slice. The repository has no UI-test target, so these cases do not exercise the real `NavigationStack` → `AlertSignupView` rendering path; they prove store state only, not on-screen layout, navigation, or accessibility presentation.

### Supported-vendor integrity coverage

Week 3 Day 7 Slice 7A adds, relative to the cross-launch check-email presentation baseline:

- 3 cases in `src/supportedVendors.test.ts` for the catalog helper: exact-match acceptance of every entry in `shared/vendors.json`, and rejection of a near-match (different case or punctuation);
- 23 cases in `src/createRequestRoute.test.ts`, in a dedicated `POST /api/request supported-vendor allowlist` describe block: acceptance of each of the 11 catalog vendors by name, refusal of unsupported, case-variant, and near-match vendors with the `INVALID_VENDOR` envelope and no side effect (`Request.create`, the Resend send, and `notifySubscribersForRequest` each never called), a blank vendor keeping the generic `INVALID_REQUEST` structural message rather than `INVALID_VENDOR`, the same catalog applied to both the canonical scheduled and legacy web create shapes, vendor precedence over the email allowlist so an unsupported vendor is reported even when the email is also invalid, an earlier structural error still reported ahead of `INVALID_VENDOR`, and a source-inspection case proving `RequestFoodView.swift` reads `SupportedVendorCatalog.diningSpots` rather than a second hand-maintained vendor list;
- 2 cases in `ios/CommonPlateios/CommonPlateiosTests/SupportedVendorCatalogTests.swift` proving the iOS Picker's data source decodes the exact accepted 11 entries, in order, from the bundled shared catalog, and that every entry carries a non-empty address.

No Mongo suite reads or writes vendor state, so `npm run test:mongo` was not rerun for this slice and stands at its Slice 5B baseline below.

### Real-time helper-alert selection and response-isolation coverage

Week 3 Day 7 Slices 7B and 7C add, relative to the supported-vendor integrity baseline:

- In `src/notifySubscribers.test.ts`: the real-time eligibility query is asserted exact — `{ status: "confirmed" }` and `{ bounced: false }` only, no cooldown or daily-cap clause; every eligible subscriber in a multi-subscriber set is notified, not a bounded subset; a subscriber with a fresh `lastSentAt` and a subscriber already at the old daily cap are each still attempted; one subscriber's provider failure does not block the remaining eligible subscribers; `SendLog`'s claim-before-send dedup still skips a subscriber another process already claimed; a successful send still updates `dailyCount` and `lastSentAt`; and the real-time path never reads or writes the now-removed `notify_cursor` `System` document.
- In `src/createRequestRoute.test.ts`: the side-effect-ordering case now proves requester email is still awaited before the `201`, while helper-alert fan-out starts only after it. A dedicated `POST /api/request helper email isolation (Slice 7C)` describe block mirrors the existing helper-push isolation suite: `201` returns while a deliberately never-settling helper-alert dispatch is still outstanding; a rejecting dispatch does not alter the `201` result and produces no unhandled rejection (asserted against the process's rejection handling); and a synchronously throwing dispatch start does not reach the outer `catch` to attempt a second response.

No Mongo suite reads or writes `Subscriber`, `SendLog`, or `System` selection logic differently under these slices — the change is a query-shape and dispatch-timing change, not new persistence, transaction, or index behavior — so `npm run test:mongo` was not rerun and stands at its Slice 5B baseline below.

### Request correctness (W3-R1) coverage

W3-R1 is ACCEPTED: NYU/`America/New_York` campus-time request timing, the ASAP/Later `visibleFrom`/`expiresAt` availability window, elapsed-Later refusal, pre-`visibleFrom` withholding on public detail and claim (`REQUEST_NOT_YET_AVAILABLE`), and the daily-quota calendar-day boundary are covered in `src/createRequestRoute.test.ts`, `src/requestTiming.test.ts`, `src/requestAvailability.test.ts`, and the corresponding iOS suites (`RequestCreationViewTests.swift`, `RequestFetchingTests.swift`, `ClaimFlowTests.swift`). These behaviors are unchanged from the checkpoint commit and are now promoted as accepted runtime truth in `docs/system-contract.md` section 2.1.

Faith's revised presentation contract — removing the standing daily-quota notice from ordinary Request Food presentation, explaining the three-hour availability rule once at the timing choice instead of repeatedly downstream, and shortening the shared backend `ASAP` timing label — added and updated cases in `src/createRequestRoute.test.ts` (the shared `ASAP_WINDOW_TEXT` label and its propagation to `pickupWindowText`), `ios/CommonPlateios/CommonPlateiosTests/RequestPostingLimitCopyTests.swift` (the standing notice is gone from the ordinary form; the actual limit-reached recovery sentence is unchanged), and `ios/CommonPlateios/CommonPlateiosTests/RequestCreationViewTests.swift` (the timing-choice form states the three-hour rule exactly once per timing; the post-submit success screen states only the confirmation, with a scoped test reading the `successView` declaration's own source to guard against any reintroduction of timing/expiration policy there, under any name).

No persistence, schema, query, or notification-routing behavior changed, so `npm run test:mongo` was not rerun for the presentation correction itself and stands at its own baseline below. The non-Eastern `DatePicker` physical-device timezone proof (Phoenix time) predates and is unaffected by the presentation correction, which does not touch timezone rendering or submission code; see the environmental-proof note in section 9.

### Verified participant identity (W3-I1) coverage

W3-I1 is accepted. Backend unit and HTTP tests cover participant challenge issuance and redemption, exact normalized NYU principals, rate/error envelopes, authority signing and revocation, route-local parsing, and startup configuration. The Mongo suites cover challenge expiry, resend supersession, bounded incorrect attempts, concurrent redemption, one participant per verified address, no raw verification-code persistence, and durable requester/helper bindings. Request, claim, fulfillment, notification, and browser tests cover the participant gate, requester identity derived from authority, atomic helper binding, fulfillment reuse of that bound helper, the intentionally narrow pre-I1 active-claim compatibility path, and the legacy website's non-actionable form.

The focused iOS participant identity, gate, and continuation suites contain 52 passing tests (including 15 continuation cases after the final test-proof correction). They cover code-verification flow, authority storage and rejection, Change Email staging, draft preservation through verification, requester/helper gates, and same-install continuation logic. The complete `CommonPlateiosTests` target passed with 550 tests and 0 failures.

These automated, source, and simulator results do **not** prove real NYU verification-email receipt or real-code redemption; uninstall/reinstall or new-device reverification; the remaining physical Keychain lifecycle behavior; backup/device-migration exclusion; or a real-address Change Email flow. Same-install authority retention through terminate/relaunch continuation was subsequently observed in the accepted W3-H1 physical flow below. The remaining items are accepted, explicitly unperformed environmental checks, not passed evidence.

### Requester verification entry (W3-I2) coverage

W3-I2 is accepted. It changes only requester-entry sequencing (verification before the Request Food form, rather than a gate at first Submit) and consumes W3-I1's identity, credential, storage, and lifetime semantics unchanged; the W3-I1 coverage above still governs those.

Focused `ios/CommonPlateios/CommonPlateiosTests/RequestFoodEntryTests.swift` coverage exists for: clean/no-identity entry routing to verification rather than the form; a usable verification-start/email-entry action; successful verification continuing directly into the form; failed/cancelled verification not doing so; already-verified and restored identity entering the form directly; no second editable participant-email field; submission carrying the authority entry verification established; sticky form-admission surviving a later mid-form authority loss without losing the draft; a repeat appearance after admission not opening a second entry-owned verification flow; and the real SwiftUI sheet-dismissal handshake (successful verification's own dismissal) not being mistaken for a user cancellation and popping the Request Food navigation destination.

That last case matters specifically because simulator/unit tests cannot, by themselves, establish the real physical-device sheet-presentation/dismissal transition — an initial round of this coverage passed in simulator while a real iPhone still required a second "I Need Food" entry after successful verification, because nothing in the automated suite drives an actual `.sheet` presentation/dismissal handshake. That physical defect was found, fixed, and its regression proof added at the same pure-predicate boundary the fix itself uses; simulator/unit results remain a proxy for, not a substitute for, physical confirmation of this exact transition.

Physical confirmation was subsequently performed and passed on a real iPhone: unverified Request Food opened participant verification before the form; real NYU verification succeeded; successful verification proceeded immediately into Request Food without a second Request Food entry; Request Food had no second editable participant-email field; a valid request submitted using the verified participant identity with no further email/verification step; leaving and reopening Request Food entered the form directly using restored verified identity; and Change Email required reverification. Faith accepted W3-I2 on this basis.

The complete `CommonPlateiosTests` target has passed alongside this coverage. The combined-tree result is recorded as current execution evidence below; it is not a historical clean-commit baseline for W3-I2 alone.

### Verification UX and app-level identity presentation (W3-I3) coverage

W3-I3 is accepted. It changes only presentation: the participant-verification and Change Email visual hierarchy, and removal of Request Food's Contact section / verified-email row. It changes no verification-code, resend, expiry, credential, participant-principal, persistence, or authorization behavior; the W3-I1 and W3-I2 coverage above still governs those. Home-level verified-identity presentation and the Change Email entry point already existed from prior accepted work and required no change for this slice.

New focused `ios/CommonPlateios/CommonPlateiosTests/ParticipantVerificationHierarchyTests.swift` coverage (2 cases) proves, by reading `ParticipantVerificationView.swift`'s own tracked source scoped to each section's declaration: the email section orders the email field, then Send code, ahead of the standing eligibility/purpose/replacement/revoked explanation; and the code section orders the code field, Verify, then resend. `ParticipantGateTests.swift` and `RequestCreationViewTests.swift` lost cases that pinned copy/behavior removed by this slice (the Request Food Contact section's standing verification notice and email-purpose-notice text). `RequestEmailAllowlistTests.swift` replaced its pre-entry email-eligibility-copy cases with a source-inspection case (`testRequestFoodHasNoContactSection`) proving `RequestFoodView.swift` contains no `Section("Contact")`, no `"Posting as"` row, and none of `emailEligibilityNotice`, `emailPurposeNotice`, or `verificationRequiredNotice` — so a reintroduction under a different property or section name still fails it.

These are structural source-text assertions, matching the existing source-inspection pattern used elsewhere in this target (e.g. the Slice 5B pre-entry-notice cases they replace). They do not by themselves prove real rendered hierarchy, visual density, or discoverability on screen — the repository has no UI-test target. Physical-device presentation is the evidence that established those rendered/discoverability properties: on a real iPhone, entering the NYU email was immediately understandable, Send code read clearly as the verification screen's primary action, Verify read clearly as the code-entry screen's primary action, Change Email presentation looked good, Home-level verified identity and Change Email were discoverable, and Request Food showed no Contact/participant-email presentation and felt limited to request-specific information. Faith accepted W3-I3 on this basis.

A final focused run after the physical-presentation fix (the `.buttonStyle(.borderedProminent)`/`.controlSize(.large)` correction to Send code and Verify) passed 60 tests, 0 failures. The complete `CommonPlateiosTests` target also passed with **649 tests, 0 failed, TEST SUCCEEDED** alongside this coverage. That later composite result is retained as the newest recorded complete-target execution evidence below.

### Later Eligibility Notification Dispatch (W3-N3) coverage

W3-N3 is accepted. Notification-focused suites passed 117/117 at the accepted checkpoint. Backend automated coverage includes: no email/push initiation before `visibleFrom`; eligibility-time processing at the next sweep; discovery of a `createdAt` well outside the former lookback; delayed/catch-up execution after a missed or interrupted sweep; temporary-availability recovery; deduplication under concurrent/repeated sweep processing; per-recipient email fan-out (`SendLog`); per-installation push deduplication (`PushDelivery`); retryable pre-initiation outcomes (pause, not-yet-effectively-available, non-duplicate claim-write failure) remaining recoverable rather than consuming the request's only initiation; terminal provider outcomes remaining terminal and non-repeating; compatibility of pre-N3 W3-R1 Later rows with the eligibility sweep; and an ASAP regression proving no N3-created duplicate notification.

At acceptance: `npm run typecheck` passed; `npm test` passed 1,055 tests with 209 Mongo-gated skips; `npm run test:mongo` passed 209 tests across 14 files; `npm run ci-check` passed; `git diff --check` was clean. An initial independent HIGH-risk review returned 3 MUST FIX findings, all corrected; a fresh narrow independent rereview of the corrections was CLEAN.

**Physical/environmental acceptance evidence.** One real future Later request was observed against live Mongo, email, and APNs. Before its `visibleFrom` (`2026-08-10T08:29:00.000Z`), the request existed with `helperNotification` awaiting eligibility, zero `SendLog` rows, and zero helper-new-request `PushDelivery` rows — no email or APNs initiation had occurred. At the first eligible sweep, `helperNotification` transitioned `awaiting-eligibility → initiated` at `2026-08-10T08:29:00.544Z`. Email: exactly one real-time `SendLog` row for the confirmed subscriber, `status: sent`, `sentAt: 2026-08-10T08:29:00.537Z`; Faith confirmed the email arrived in the intended inbox. Push: three helper-new-request `PushDelivery` rows, one per eligible installation, with no duplicate rows; two were accepted by APNs and one was rejected under existing provider/token classification (not an N3 timing defect — initiation occurred at the correct time and another intended installation was accepted); Faith physically observed the notification on the intended physical iPhone. Every recorded initiation timestamp was at or after `visibleFrom`.

This physical request's `createdAt` was approximately 10 minutes before its `visibleFrom`, so the physical test alone does not reproduce the former long-lookback omission; that stronger old-`createdAt` property is established by the real-Mongo integration coverage above using requests many hours old, not by this physical observation. Provider acceptance proves provider submission/acceptance only; inbox arrival and physical notification presentation were observed as supporting environmental evidence, and neither proves reading or pickup.

A separate finding from this same physical session — that helper new-request emails for ASAP requests currently show a concrete time range where Faith prefers an "ASAP" label, while Later alerts correctly retain concrete scheduled timing — is not an N3 eligibility-time defect and is not part of this acceptance. It is recorded as a forward-routed product/email-presentation finding in the current weekly spec's deferral register.

### Reservation Lifecycle (W3-H1) coverage

W3-H1 is accepted. Backend automated coverage includes one-active-reservation enforcement across principals and requests; atomic release and continuation authorization; exact release CAS handling for absent, `null`, and date representations; release/extension one-winner races on real MongoDB; fulfillment/release safety; and deterministic transaction-callback retry regression proof. The H1 closeout typecheck, focused claim/reservation/fulfillment suites, complete non-Mongo suite, and complete Mongo-gated suite passed.

iOS coverage exercises continuation truth (`active` only for a claimed embedded request, `none` only for authoritative absence, and `unknown` for transport/server/decode/contradictory responses); reservation-scoped authority and stale-credential rejection; release/extend/fulfill exclusion and recovery; bounded ambiguous-fulfillment resend; requestID-stable warning scheduling; active/inactive warning ownership transfer; scheduler callback fencing; and warning tap routing, including cold launch and stale-warning isolation. The H1 closeout complete `CommonPlateiosTests` run passed **633 tests, 0 failed** on an iPhone 17 Pro simulator running iOS 26.5; final focused rereview suites and both diff checks also passed.

Faith's physical iPhone acceptance established the device-only behaviors not proven by simulator/unit tests: terminate/relaunch continuation; foreground in-app T−5 warning without a duplicate system warning; backgrounded and terminated local warning delivery; terminated-app warning-tap cold launch to the matching reservation; release; and fulfillment after restored continuation. These observations establish H1 behavior on the observed device only. They do not establish APNs provider behavior, Release/Archive/TestFlight signing, or release-environment configuration, which remain separate gates.

### Meal-Plan / Payment Requirement (W3-C1) coverage

W3-C1 is accepted. Backend coverage in `src/createRequestRoute.test.ts` proves the required integer 1–5 `mealSwipes` quantity is enforced identically on the canonical/iOS and `legacyWebSchema` request shapes: values 1–5 are accepted and round-trip unchanged; missing, invalid, fractional, and out-of-range values are rejected on both shapes, including a `legacyWebSchema` submission omitting the quantity. `src/requestListResponse.test.ts` and `src/requestDetailRoute.test.ts` prove the helper projection exposes the quantity without newly exposing any private field. `src/emailHelpers.test.ts` and `src/helperPushPayload.test.ts` prove the helper new-request email (text and HTML) and push payload carry the same authoritative quantity through the existing `sendNewRequestAlert()` and `buildHelperNewRequestPayload()` composition paths, unchanged for both immediate-creation and W3-N3 eligibility-sweep dispatch. `src/participantBinding.mongo.test.ts` and `models/db.ts` cover Request-owned persistence of the field.

iOS coverage proves the bounded 1–5 picker, payload behavior, and pre-Reserve visibility in Active Requests and `RequestDetailView`, continuity through active-reservation presentation and `FulfillRequestView`, and that fulfillment navigation reads the quantity from the active claim's authoritative request rather than a stale pre-claim copy — across `RequestCreationViewTests.swift`, `RequestFetchingTests.swift`, `RequestFoodEntryTests.swift`, `ClaimFlowTests.swift`, `ReservationContinuationTests.swift`, `ReservationFulfillmentContinuationTests.swift`, `ReservationReleaseTests.swift`, `ReservationWarningTests.swift`, `ReservationWarningRoutingTests.swift`, `ParticipantContinuationTests.swift`, `ParticipantGateTests.swift`, `RequestCreationInstallationCredentialTests.swift`, `RequestEmailAllowlistTests.swift`, `RequestTimingContractTests.swift`, `HelperNotificationRoutingTests.swift`, and `HelperNotificationTerminatedLaunchRoutingTests.swift`.

At acceptance: `npm run typecheck` passed; `npm test` passed 1,317 tests with 275 Mongo-gated skips; `npm run test:mongo` passed 275 tests across 17 files; `npm run ci-check` passed; `npm run build:client` produced no tracked bundle diff. The final focused Active Requests visibility test, the ClaimFlow focused proof after continuity fixes, and the complete `CommonPlateiosTests` target (662 passed, 0 failed, TEST SUCCEEDED) all passed. An independent engineering review resolved backend validation/persistence/privacy/notification findings and one iOS stale-request fulfillment continuity MUST FIX, with no remaining engineering finding afterward.

**Physical acceptance evidence.** Faith verified the meal-swipe quantity is visibly acceptable in Active Requests on a physical device. An earlier walkthrough verified the same distinctive quantity (`4`) in Request Detail, active-reservation presentation, and fulfillment/order context, and the helper new-request notification and email presentation were also physically reviewed and accepted. These observations establish on-device presentation on the observed device only; they do not establish Release/Archive/TestFlight signing or environment behavior, which remains a separate gate (`docs/system-contract.md` section 11).

**Week 4 deferral.** `Meal swipes: N` is technically correct but its user-facing meaning and visual hierarchy are deferred to Week 4; that resolution must not reopen C1 data semantics, backend behavior, validation rules, or notification content, except that Faith has explicitly authorized W4-N1 (not W4-R2, and only once N1 reaches its own READY contract) to change the new-request push notification's title/body composition specifically; this narrow carve-out does not reopen any other notification content, channel, delivery, tap-routing, or dedup behavior recorded in this document or in `docs/system-contract.md`.

### Notification Management / Activation Truth (W3-N2) coverage

W3-N2 is accepted. Backend coverage adds focused participant-authorized email-unsubscribe route/primitive tests proving: exact participant-email authorization with no caller-supplied email or Subscriber ID accepted; rejection of forged, revoked, deleted, and stale participant authority; absent/pending/confirmed/already-unsubscribed Subscriber convergence to the identical `{ "email": { "unsubscribed": true } }` result with no lifecycle or identifier leakage; atomicity and idempotency under repeat and concurrent calls; the exact cleared confirmation-credential field set, matching the existing emailed-unsubscribe clear list; that `unsubscribeCredentialVersion` is untouched; pause and rate-limit behavior; and that existing emailed unsubscribe credentials and browser GET/POST behavior are unaffected. Backend coverage also adds focused signup-privacy tests proving the same generic accepted `202` response across Subscriber lifecycle states and confirmation-email provider outcomes that previously exposed `CONFIRMATION_EMAIL_UNAVAILABLE`, that internal cleanup/rollback and sanitized logging still run on provider failure, and that the response makes no provider-submission or delivery claim.

At acceptance: `npm run typecheck` passed; complete `npm test` passed after the signup-privacy correction; `npm run test:mongo` passed **283 tests across 18 files**; `npm run ci-check` passed; `git diff --check` passed.

**Verification-environment limitation.** Sandboxed backend test execution could not bind `127.0.0.1` and produced unrelated EPERM/timeout failures unconnected to this slice's behavior. The complete backend suite passed when run with the necessary local-loopback permission. This is recorded as a verification-environment limitation, not a product defect.

iOS coverage adds focused suites for: ambiguous push enable/disable persistence surviving relaunch and requiring an explicit retry, with no automatic ambiguous reconciliation across relaunch or authorization refresh; participant-authorized email unsubscribe through `ParticipantEmailUnsubscribeService`/`ParticipantEmailUnsubscribeStore`, including forged/stale-credential rejection and convergence to the same Off result regardless of prior Subscriber state; a stale Email Alerts Off presentation being reset by a later signup, both to the same address and to a different one, returning to `Check your email` rather than a stale Off; in-flight unsubscribe generation/reset races; and removal of retired `CONFIRMATION_EMAIL_UNAVAILABLE` client-side handling from `AlertSubscriptionService` and `AlertSubscriptionStore`.

Final complete iOS evidence: **CommonPlateiosTests — 689 passed / 0 failed / TEST SUCCEEDED**. This supersedes the W3-C1 iOS baseline (662 passed) as the current accepted baseline below.

**Physical acceptance.** Faith completed the W3-N2 physical acceptance walkthrough on a physical iPhone and reported the behavior worked as expected. The walkthrough covered: physical Apple notification-permission behavior; push enable reaching authoritative On; push disable reaching authoritative Off; relaunch preserving accepted push-management truth; ambiguous push recovery/retry behavior as exercised in the walkthrough; participant-authorized in-app email unsubscribe; later signup returning to Check Your Email rather than stale Off; and email/push channel independence. This walkthrough does not establish verified email delivery or reading, a production APNs delivery environment, TestFlight signing/configuration, or production backend reachability — those remain separate provider/release gates (`docs/system-contract.md` section 11).

### Durable Request-Creation Recovery (W3-D1) coverage

W3-D1 is accepted. Backend coverage proves exact-operation idempotency and reconciliation for `POST /api/request`: sequential and concurrent replay of one operation identity converge on the same authoritative Request and create no duplicate; a backend commit followed by a lost/unreadable response reconciles to the already-created Request; a definitively rejected operation (`400 INVALID_OPERATION_ID`, `403 OPERATION_UNAUTHORIZED`, and the ordinary pre-write validation/quota/rate-limit refusals) creates no Request and permits a later intentional submission with a fresh identity; replay of an already-created operation consumes no additional daily quota while a genuinely distinct create still does; cross-participant reconciliation is refused generically with no private detail disclosed; the operation tombstone (`RequestOperation`) survives Request removal; presenting an identity whose Request has passed its recovery horizon resolves as terminal `410 OPERATION_EXPIRED` and creates zero Requests; and a fresh intentional operation after expiry creates normally under existing validation and quota rules. `src/createRequestRoute.test.ts` and `src/createRequestRoute.mongo.test.ts` cover this; `models/db.ts` adds the `RequestOperation` ledger and its unique operation-identity index.

iOS coverage (`RequestCreateDurableOperationTests.swift`, `PendingRequestOperationStorage.swift`) proves: a fresh operation identity is minted and its durable recovery record — participant-bound, carrying the exact submitted request fields, and never a raw participant credential — is persisted before transmission begins; the process-lifetime create block is armed only by an ambiguous outcome or a write-uncertain decoded response (`REQUEST_CREATION_FAILED`), never by a definitive non-create; a definitive non-create (including `OPERATION_EXPIRED`, `INVALID_OPERATION_ID`, `OPERATION_UNAUTHORIZED`, and the ordinary pre-write rejection codes) retires the durable record so a later intentional submission mints its own identity; a proven pre-transmission cancellation retires the record it just wrote; and launch reconciliation restores and reuses the exact persisted operation identity and payload rather than reconstructing it heuristically.

At acceptance:

* TypeScript/backend typecheck: passed.
* Complete non-Mongo backend suite: passed at the current recorded D1 run.
* Real-Mongo D1 suite (`src/createRequestRoute.mongo.test.ts`): passed, covering exact-operation replay, concurrency, participant isolation, quota non-double-consumption, the operation tombstone surviving Request removal, terminal expiry/non-resurrection, and a fresh operation after expiry.
* `npm run ci-check` and `git diff --check`: passed.
* `RequestCreateDurableOperationTests`: **21 passed, 0 failed**.
* Complete `CommonPlateiosTests`: **710 passed, 0 failed, 0 skipped**, with a valid inspectable `.xcresult`.
* An independent HIGH-risk review completed with all MUST-FIX findings corrected; a final narrow independent rereview was CLEAN.

**Accepted verification limitation.** The integrated physical-iPhone D1 runtime scenarios were **not executed before acceptance**. Faith explicitly accepted W3-D1 with this remaining physical-runtime limitation. The automated, simulator, and backend evidence above must **not** be described as proving: actual physical-device process termination at the post-commit/pre-retirement boundary; real physical-device relaunch sequencing; real physical-device network interruption behavior; or visible physical-device convergence after that termination boundary. The remaining unperformed scenarios are:

1. backend commits operation X to Request A → physical app terminates before retiring X → relaunch → the same X reconciles to the same A without creating a duplicate;
2. the physical client handles a terminal expired operation X without resurrecting a Request;
3. a fresh intentional operation Y, submitted after X has become terminal, creates normally.

A separate attempt at a simulator-integrated (non-physical) proof was made and was **blocked by environment/tooling**, not by a D1 correctness defect: the preserved physical-test `APIConfiguration.swift` LAN value was unreachable from the development machine's then-current subnet, and the repository-connected verification agent lacked GUI-input/interactive-LLDB capability needed to drive Simulator UI and hold a deterministic post-commit/pre-retirement breakpoint. That blocked attempt is neither PASS nor FAIL and did not discover a D1 correctness defect. Faith has accepted this limitation for W3-D1 V1 closeout; see `docs/system-contract.md` section 11.

### Helper Participation Continuity (W3-H2) coverage

W3-H2 is accepted. Backend coverage in `src/claimRouteParticipation.test.ts` and `src/claimRouteParticipation.mongo.test.ts` proves: a participant who releases or passively expires out of a claim cannot successfully reacquire the same request while another eligible participant still can; a failed or raced acquisition attempt that never wins authority consumes no participation; the same verified participant presenting newly issued authority from another installation/device cannot bypass the invariant; concurrent reacquisition attempts preserve one-winner behavior and correctly refuse the prior holder; and H1's one-active-reservation-across-requests invariant remains intact and unaffected. `src/requestParticipation.test.ts` and `src/requestParticipation.mongo.test.ts` prove the marketplace-list exclusion is scoped to exactly the resolving caller's own participant id, leaving every other eligible participant's list unaffected, and that anonymous/unverified browsing is never refused. `src/requestDetailRoute.test.ts` and `src/requestDetailRoute.mongo.test.ts` prove participant-aware detail exposes only the resolving caller's own already-participated boolean alongside the existing public projection and privacy boundary. `src/reservationRoute.test.ts` and `src/reservationRoute.mongo.test.ts` prove the participant-scoped placed-request re-entry read: restoring already-placed/Got It truth only within the request's retained `deleteAt`/`PLACED_RETENTION_MS` horizon, an active `claimed` reservation taking priority over any placement field, and no reservation authority or raw claim token being recreated by re-entry. `models/db.ts`/`app.ts` add the `RequestParticipation` collection and its unique `(requestId, participantId)` index, explicitly established via `RequestParticipation.createIndexes()` before the process accepts claim traffic, with real-Mongo coverage proving the index enforces one successful acquisition per participant per request under concurrency.

iOS coverage adds three focused files: `ActiveRequestsParticipantAuthorityTests.swift` proves the active-requests fetch forwards the caller's verified participant authority header when present and sends none when absent, at both the service and store layers. `RequestDetailStaleParticipationTests.swift` proves the already-participated read decodes correctly (including treating an absent field as `false`), resolves eligible/already-participated from backend truth, resolves unresolved (never fabricated-eligible) on a failed read, discards a result resolved for a participant identity that changed while the read was in flight, and gates both the rendered claim-section state and the `startClaim` action boundary on current-key-aware eligibility truth — a stale or cross-identity result can never enable Reserve. `PlacementReentryContinuationTests.swift` proves the reconstructed Got It/already-placed presentation across settled-sent, settled-failed, and unknown notification outcomes, that no reservation and no placement restores nothing, that a restored confirmation blocks starting a new claim until acknowledged, that a second continuation call never overwrites an already-restored confirmation, and that an active reservation takes priority over any placement field. The complete `CommonPlateiosTests` target passed **744 tests, 0 failed, TEST SUCCEEDED**.

At acceptance: `npm run typecheck` passed; `npm test` passed 1,378 tests with 321 Mongo-gated skips; `npm run test:mongo` passed 321 tests across 22 files; complete `CommonPlateiosTests` passed 744 tests, 0 failed, TEST SUCCEEDED; `git diff --check` passed. An independent HIGH-risk review identified a contract conflict (Change Email / principal-scoped participation, resolved by Faith as principal-scoped per `docs/system-contract.md` section 5.1) and four correctness-critical findings (stale marketplace/detail Reserve affordance, unverified startup index establishment, unbounded placed re-entry recovery, and insufficient production-boundary proof beyond source inspection); all four were addressed during implementation and a focused rereview found no remaining engineering finding.

**Accepted verification limitation.** The repository has no iOS UI-test target, so the literal SwiftUI stale-detail render/tap scheduling sequence — a visible Reserve affordance disabling itself on screen, and an actual tap being gated in real `RequestDetailView` rendering — was not driven end-to-end through UI automation or physical-device interaction. The accepted evidence instead covers: current-key-aware production eligibility/action logic directly (`RequestDetailStaleParticipationTests.swift`); production `startClaim` action-boundary wiring; backend authoritative reacquisition refusal; real-Mongo persistence/concurrency proof for the participation ledger and its unique index; participant-scoped list/detail behavior and privacy isolation; the complete `CommonPlateiosTests` target; and independent HIGH-risk review plus focused rereviews ending CLEAN. This is an accepted verification limitation, not a failed or pending correctness check, and must not be described as UI-test or physical-device proof.

### Remove Verified Identity (W3-I4) coverage

W3-I4 is accepted. Focused `RemoveEmailTests` reached 19/19 and the complete `CommonPlateiosTests` target reached 763/763 with 0 failures before the final literal-only copy correction; that correction was verified by source/diff inspection and `git diff --check` passed. An independent rereview established that the H1/D1 cold-launch race identified against the removal-safety gating was closed, that unknown/inconclusive removal-safety states fail closed rather than allowing removal, and that the ambiguous-fulfillment-recovery blocking case is a meaningful blocker rather than a redundant one.

**Accepted verification limitation.** The final focused `RemoveEmailTests` rerun against the literal-only copy correction was attempted twice but could not execute because CoreSimulator became unavailable (`CoreSimulatorService connection became invalid`; `Unable to find a device matching the provided destination specifier`). This final focused test state is not claimed as passed; it is an accepted environmental verification limitation, consistent with the pattern already used for W3-I1/W3-H1/W3-D1/W3-H2. Physical-device Keychain-deletion proof was likewise not established and is accepted as unperformed on the same basis.

### Email Request Alert State Authority (W4-N0) coverage

W4-N0 is accepted. Backend coverage (`src/emailAlertState.test.ts`, `src/emailAlertState.mongo.test.ts`, `src/emailAlertStateRoute.test.ts`) proves: the read derives its principal only from `resolveParticipantAuthority`, refusing missing/invalid authority before any Subscriber lookup; no caller-supplied query, body, or header field can select a different address; another participant's Subscriber state cannot affect or be exposed to the caller; absent, pending, and unsubscribed Subscriber rows all read `active: false` and only `status: "confirmed"` reads `active: true`; the read performs no mutation on any path; a database failure answers `503` rather than a false `active: false`; the response carries only `{ "email": { "active": boolean } }` with no Subscriber id, credential, or lifecycle field; and `Cache-Control: private, no-store` / `Vary: x-commonplate-participant` are present on success, authority-refusal, and lookup-failure responses alike. `src/emailAlertState.mongo.test.ts` proves the absent/pending/confirmed/unsubscribed lifecycle mapping and read-only behavior against real MongoDB, in its own `commonplate_email_alert_state_test` database, following the same per-suite-database `Subscriber` isolation convention documented in section 5 below.

iOS coverage (`EmailAlertStateStoreTests.swift`) proves: no credential issues no network call and leaves state `.unknown`; authoritative backend On/Off map exactly to `.active`/`.inactive`; authorization, transport, and decoding failures all leave state `.unknown` rather than a fabricated Off; a response or an authority-invalid rejection resolved under a participant authority that a later Change Email has since replaced is discarded rather than applied to, or retiring, the replacement identity — including when the newer participant's own refresh has already completed, and when the newer participant's refresh is still in flight concurrently with the superseded one; repeated refreshes for the same still-current participant remain coherent; and only `PARTICIPANT_AUTHORITY_INVALID` for the still-current credential invokes the existing participant-authority rejection path, matching `RequestStore.applyParticipantVerdict`.

At acceptance: `npm run typecheck` passed; focused backend N0 suites passed **18/18**; complete `npm test` passed **1,406 passed, 328 Mongo-gated skipped**; `npm run test:mongo` passed **328 tests across 23 files** (against the N0 query/persistence implementation, which a later comment-only correction left unchanged); focused `EmailAlertStateStoreTests` passed **18/18**; complete `CommonPlateiosTests` passed **857 passed, 0 failed, 0 skipped, TEST SUCCEEDED**; `git diff --check` passed. An initial independent HIGH-risk review returned three MUST FIX findings (participant-specific cache isolation, iOS state remaining bound to the current participant across a Change Email race, and current-only authority-rejection retirement) and one SHOULD FIX (a misleading backend comment conflating N0's confirmed-only state with send/delivery eligibility); all four were corrected, and a fresh focused rereview was CLEAN.

A `ReservationWarningTests.testReleaseSucceedsBeforeTheWarningEverFires` timing flake surfaced twice during the fix-round complete-target runs. It was investigated: the test passed standalone in both the pre-fix and post-fix trees, passed as part of its full suite against the unmodified pre-fix tree, and passed again in its full suite and in the complete target against the post-fix tree with no further code change. It does not touch `EmailAlertStateStore`, `EmailAlertStateService`, or any other N0 file. This is recorded as pre-existing `Task.sleep`/`waitUntil` polling flakiness in that unrelated suite, not an N0 defect, and is not a new accepted verification limitation for N0.

No N0-specific physical-device or environmental proof is required or outstanding.

### AI Screenshot Proposal Foundation (W4-S1) coverage

W4-S1 is accepted for the bounded contract-aware fix recorded in the current weekly spec: extending the existing cart-rule checkout-context exclusion to `place your delivery order` and `place your pickup order`. Focused backend coverage lives in `src/screenshotEligibility.test.ts` (the deterministic `evaluateEligibility`/`countMealSwipeMarkers` rule, including the checkout-context exclusion and strict H5), `src/screenshotProposalValidation.test.ts` (forbidden-field refusal, `.strict()` schema validation, bare yes/no sanitization, vendor resolution/ambiguity, and meal-swipe corroboration), `src/screenshotProposalProvider.test.ts` (the stateless single-attempt OpenAI adapter and its error-kind classification), and `src/screenshotProposalRoute.test.ts` (participant-authority-first ordering, the route's own bounded image transport and structural PNG/JPEG validation, fail-closed missing-provider-configuration behavior, and that no path reaches `createRequest`/`RequestOperation`/quota/notifications). Focused iOS coverage lives in `ScreenshotProposalStoreTests.swift`. These files are ordinary `*.test.ts`/`XCTest` suites and are collected automatically by `npm test` and the complete `CommonPlateiosTests` target; this documentation sync did not rerun those runtime suites, so exact pass counts are not restated here — they are the implementing/reviewing session's record, not invented for this sync.

**Apple Vision eligibility-corpus verification (local-only research artifact; not committed).** A 71-image eligibility corpus, a companion Apple Vision OCR harness, and an OpenAI provider-qualification harness were used during W4-S1 to verify the deterministic eligibility rule end to end. None of that evaluation workspace — corpus images, harness code, run scripts, or result artifacts — is committed to this repository or reproducible from a fresh clone. It is kept local-only because the evaluation workspace mixes real personal order screenshots, real extracted OCR/provider-response text, and third-party campus-dining/Grubhub material with no cleared redistribution status, and no boundary short of excluding the whole workspace reliably kept that content out of Git history. This is a distribution/retention decision, not a statement that the verification didn't happen or isn't trustworthy.

The verification itself re-ran the actual production `evaluateEligibility`/`countMealSwipeMarkers` implementations (`src/screenshotEligibility.ts`) against production-equivalent Apple Vision OCR output for all 71 corpus images, so it exercised real production logic rather than a reimplementation of the rule. The accepted post-fix result is 71/71 processed, 0 load failures, 0 OCR failures, and an all-71 confusion matrix of 12 TP / 55 TN / 2 FP / 2 FN. This establishes: the bounded checkout-context fix rejects the intended false positive; a compound screenshot with a visible receipt/payment sheet is judged on whether its exposed supported evidence independently qualifies, not disqualified merely because a receipt is visible; and strict H5 is unchanged. One historical-detail fixture may remain an accepted false negative when Apple Vision fails to recognize the required quantity-prefix digit — a documented V1 limitation (manual entry remains available), not a defect. Two deliberate synthetic vocabulary/chrome-mimicking fixtures are accepted false positives outside the V1 authenticity guarantee (`docs/system-contract.md` section 12). This result contributed to W4-S1 acceptance; it is not evidence about a signed Release build, production provider credentials/reachability, or a physical device — those remain Week 5 gates (`docs/system-contract.md` section 11).

Because the corpus and harnesses are not distributed, a fresh clone cannot reproduce this historical 71-image run from committed artifacts alone. Rerunning it in the future requires rebuilding an equivalent local corpus/harness against the production eligibility functions; the result above stands as the accepted historical evidence until such a rerun happens.

### Home & Navigation Architecture (W4-H2) coverage

W4-H2 is accepted. Backend coverage proves the expanded ownership/self-claim contract: participant-scoped request-list ownership projection (verified owner receives an affirmative ownership signal for their own eligible open request only; another verified participant and anonymous/unresolved callers receive no participant-specific ownership truth for it; own requests are not filtered out of the list; `requesterParticipantId`, requester email, and other private identity never enter the response; existing public-list privacy projection and participant-aware filtering remain intact) and the authoritative backend self-claim guard inside the existing atomic conditional claim mutation (direct self-claim is refused using the existing conflict-style error envelope, creates no reservation/helper-binding/participation side effect, and leaves another eligible participant's claim, existing one-active-reservation behavior, and claim visibility/expiry/atomicity unaffected). iOS coverage proves `FoodRequest` ownership truth (own/notOwn/unresolved) driven only by authoritative backend signal rather than an installation-local heuristic, the approved YOUR REQUEST presentation, owner-side withholding of the Help/Reserve action, and unresolved ownership failing closed for actionability; Home root/navigation, live-board entry and ASAP-then-scheduled ordering, `Continue Helping` continuation, Low Activity/Empty/Unavailable presentation, Settings navigation and identity presentation, verified/unverified Request Alerts entry and verification-return continuation, and the native-`.refreshable`-only functional refresh contract (initial-load and manual-refresh 5-second deadlines, recovery-only checkmark, stale-response/generation safety, and baseline Reduce Motion correctness) recorded in `docs/system-contract.md` section 1.3.

At the final ownership rereview: `npm run typecheck` passed; focused backend ownership/detail/privacy/self-claim suites passed **90 passed, 23 Mongo-gated skipped in that focused run**; complete `npm test` passed **1,424 passed, 328 Mongo-gated skipped**; `npm run test:mongo` passed **328 passed across 23 files**. Focused iOS ownership suites passed **40 passed**: `RequestOwnershipLifecycleTests` — 15, `RequestOwnershipAuthorityContextTests` — 16, `RequestOwnershipReconciliationTests` — 5, `RequestOwnershipTests` — 4. The latest complete iOS run after the ownership implementation, `CommonPlateiosTests`, passed **914 passed, 0 failed, TEST SUCCEEDED**.

**Final rereview scope.** The final independent rereviewer did not independently rerun the complete 914-test `CommonPlateiosTests` target; it inspected the prior current-tree complete result above and reran the focused ownership evidence (the 90 backend and 40 iOS totals above) fresh. Do not describe the complete 914-test run as having been independently rerun at the final rereview; it is the most recent complete-target result on the accepted tree, not evidence reproduced by that final review pass.

**Known, accepted limitations.** The repository has no iOS UI-test target: the unresolved-ownership UI branch (help/reserve withheld while ownership resolves) is proven through production ownership-resolution predicate/action-boundary logic and the complete iOS target rather than through UI automation or physical-device interaction. Backend detail ownership is proven through production handler/builder behavior with mocked persistence for the unit layer, plus real-Mongo coverage for the list/claim mutation, rather than a fully mounted HTTP+Mongo detail request end to end. The current authored refresh visual/motion polish (pull-cue choreography, easing, arrow-to-symbol transform quality, spinner/symbol treatment) is not acceptance proof of anything beyond H2's functional refresh contract; it is a known, accepted visual/experience limitation deferred to W4-H3 (`docs/system-contract.md` section 1.3), not a defect. A Simulator-only defect (native `.refreshable` not activating under Simulator's indirect-pointer/trackpad input path; see the current weekly spec's W4-H2 section) was investigated but could not be resolved further without a physical device; the repository/session contains no record of a physical-iPhone reproduction-or-rule-out walkthrough for this specific defect, and this is not claimed as performed.

### Request Creation Eligibility Authority (W4-Q1) coverage

W4-Q1 is accepted. Backend coverage (`src/requestDailyQuota.test.ts`, `src/requestEligibility.test.ts`, `src/requestEligibilityRoute.test.ts`, `src/requestEligibility.mongo.test.ts`) proves: the read derives its principal only from `resolveParticipantAuthority`, refusing missing/invalid authority before any count; no caller-supplied query, body, or header field can select a different principal; distinct exact normalized principals retain distinct current allowances; `eligible` below three and `exhausted` at three and above, with no count/remaining/reset/identity/credential/request data in the response; the NY campus-day rollover at `America/New_York` midnight; the read and `POST /api/request` call the same extracted `src/requestDailyQuota.ts` count/threshold authority (create's own daily-limit suites in `src/createRequestRoute.test.ts` pass unchanged against the shared extraction); a count/database failure fails closed as unavailable rather than eligible or exhausted; `Cache-Control: private, no-store` and `Vary: x-commonplate-participant` cover success and every refusal/failure path, including a mounted rate-limited `429` proven through a real Express/HTTP server rather than a direct handler call; and the read performs no Request/RequestOperation/participant/notification/subscription/installation mutation. `src/requestEligibility.mongo.test.ts` additionally proves the current-as-of-read boundary against real MongoDB: an eligible Q1 read followed by racing writes that reach the threshold, then a real `createRequest` invocation for the same participant carrying a fresh valid `x-commonplate-operation-id`, independently refuses with `429 REQUEST_LIMIT_REACHED`, creates no additional `Request`, writes no `RequestOperation` ledger row for the presented identity, and starts no requester-confirmation email, helper-alert, or helper-push side effect.

iOS coverage (`RequestEligibilityTests.swift`) proves: `RequestService.fetchRequestCreationEligibility` decodes `eligible`/`exhausted` and sends the participant header, and fails decoding on an unrecognized wire value rather than guessing; `RequestStore.resolveRequestCreationEligibility()` resolves `.eligible`/`.exhausted` only from a successfully decoded backend result for the still-current authority; no participant identity issues no network call and leaves `.unknown`; transport failure, decoding failure, and an unrelated server refusal all leave `.unknown`; a result resolved for an authority a later Change Email has since replaced is discarded as `.unknown` rather than applied to the replacement identity, while the unchanged-identity path still resolves normally; genuine mid-flight cancellation (a `Task` cancelled while a gated in-flight stub is provably still waiting, not merely a call that never reaches the network) resolves `.unknown` without retiring identity; and a current `PARTICIPANT_AUTHORITY_INVALID` refusal invokes the same `applyParticipantVerdict`/authority-retirement path every other participant-gated `RequestStore` method already uses, while a stale rejection for a since-replaced authority cannot retire the replacement.

At acceptance: `npm run typecheck` passed; `npm test` passed **1,537 passed, 335 Mongo-gated skipped**; `npm run test:mongo` passed **335 tests across 24 files**; complete `CommonPlateiosTests` passed **1,001 passed, 0 failed, TEST SUCCEEDED**; `git diff --check` passed. Independent HIGH-risk review of this evidence ended CLEAN.

No Q1-specific physical-device or environmental proof is required or outstanding.

### W4-R2 Requester Journey Integration acceptance

W4-R2 is accepted. It is an iOS-only slice: per section 11, its minimum verification is focused suites plus the complete `CommonPlateiosTests` target. No backend, Mongo, or browser-bundle check was required or rerun for R2, and none is claimed here.

Automated coverage proves: the pushed (not sheeted) Request Food navigation and its preserved entry-verification/draft/re-entry behavior; the Q1-consuming early eligibility boundary, including the distinct retryable unknown/error presentation versus the unchanged non-retryable exhausted presentation, and that `Try Again` performs a fresh eligibility read rather than reusing a cached result; the in-memory draft-session lifetime across ordinary departure and background/foreground transitions, including manual-outranks-AI and no-mutation-by-stale-analysis; Timing's ASAP/Later presentation, quick-time choices, and native `Choose time` replacing its own label; the Screenshot Assistance completion acknowledgement's three distinct outcome states; the first-use consent/disclosure gate, its Off-state discoverable re-entry path (`Turn on Screenshot Assistance`), and the independence of consent/enabled state from Screenshot Help completion state; Screenshot Help's centered-overlay presentation and `Got it` dismissal back to the same draft; Posting/Success timing (the tinted native `ProgressView`, the single success haptic, and the ~1.6-second Success dwell) and D1 unresolved-ambiguity's continued haptic-free distinctness from definitive failure; that R2 performs no Home insertion/reorder/highlight and instead relies on H4's authoritative fetch (section 1.4); and the `YOUR REQUEST` eyebrow suppression scoped to the dedicated owned-request zone only. Focused coverage lives in `RequestFoodEntryTests.swift`, `RequestFoodDraftSessionTests.swift`, `RequestCreationViewTests.swift`, `RequestTimingContractTests.swift`, `ScreenshotProposalStoreTests.swift`, `ScreenshotProposalDisclosurePresentationTests.swift`, `ScreenshotHelpPresentationTests.swift`, `RemoveEmailTests.swift`, `RemoveEmailStatusKindTests.swift`, `RequestOwnershipLifecycleTests.swift`, and `RequestCreateDurableOperationTests.swift`, alongside updates to `MealSwipeQuantityTests.swift`, `OnboardingPresentationTests.swift`, `RequestEligibilityTests.swift`, `RequestFetchingTests.swift`, and `SettingsRequestAlertsToggleTests.swift`.

At acceptance: a final independent rereview passed; the Q1 production-transition proof (the early-boundary consuming the real Q1 read rather than a stub) passed; the Remove Email overlapping-read presentation-state proof (an in-flight check versus a settled-unresolved check resolving to distinct presentations without racing) passed; a focused final rereview passed **63 passed, 0 failed**; the complete `CommonPlateiosTests` target passed **1,104 passed, 0 failed**; `git diff --check` and `git diff --cached --check` were both clean, with nothing staged at the final rereview. Faith completed the required physical-device walkthroughs — covering Request Food navigation, Q1 eligibility presentation, draft continuity, Timing, Screenshot Assistance consent/Off-state/Help, Posting/Success motion and haptics, and Remove Email presentation — and explicitly accepted W4-R2 on 2026-09-07.

**Known, accepted limitations.** The repository still has no iOS UI-test target: rendered layout, gesture, and accessibility-traversal properties for the items above are the same class of accepted limitation recorded for W4-H2/H4 and are established by physical-device walkthrough rather than automated UI verification. W4-R2 acceptance does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (`docs/system-contract.md` section 11). The new-request push notification's title/body composition remains W4-N1's future work, not R2's (see the W3-C1 coverage subsection's carve-out above); R2's own acceptance evidence does not touch that payload.

## 5. Mongo integration tests

Run:

```bash
npm run test:mongo
```

A prior reference baseline was **172 passed across 13 files**. The complete Mongo-gated suite also passed in the accepted H1 closeout; section 13 deliberately records that pass without inventing an unrecorded new total. `mongod` and `mongosh` must both be on `PATH`. The script creates a temporary data directory, starts a temporary single-member replica set on a free local port, initializes it, injects an isolated `MONGO_INTEGRATION_URI`, runs `*.mongo.test.ts`, and removes the temporary database directory afterward.

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

The project is `ios/CommonPlateios/CommonPlateios.xcodeproj`; its shared scheme is `CommonPlateios` and its unit-test target is `CommonPlateiosTests`. The project's `IPHONEOS_DEPLOYMENT_TARGET` is 17.6; accepted test runs have executed against an iOS 26.5 simulator runtime, so use Xcode with a matching installed simulator runtime available. iOS 26.5 is the simulator runtime used for verification, not the deployment target.

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

The current accepted W4-F1 complete-iOS proof is **785 passed, 0 failed, 0 skipped, TEST SUCCEEDED**. Compilation alone is not a passing test result: the result bundle must complete and the output must contain `TEST SUCCEEDED`. Xcode GUI and terminal runs use the same shared scheme and `CommonPlateiosTests` target.

Automated routing tests (this target included) prove tap-routing logic against stubbed backend resolution; they do not by themselves prove real APNs terminated-launch handoff on a device. Physical-device proof was required for helper terminated-launch tap routing and for requester-fulfillment push, and both have now passed on a physical iPhone. Release/Archive/TestFlight signing and environment behavior is unrelated evidence and remains a separate, still-open environmental gate (see `docs/system-contract.md` section 11).

Automated and source-text assertions can prove that `RequestFoodView` installs the NYU/New York timezone and calendar into the SwiftUI environment; they cannot prove what a real `DatePicker` renders on a device actually configured to a different timezone. W3-R1 required physical-device verification on a non-Eastern device for exactly that reason: an iPhone configured to Phoenix time (no DST offset from New York for part of the year) displayed the intended NYU/New York wall-clock selection of 10:30 PM rather than device-local Phoenix time, and submitted `windowStart = 2026-08-09T02:30:00.000Z`, `visibleFrom = 2026-08-09T02:30:00.000Z`, and `expiresAt = 2026-08-09T05:30:00.000Z`; the requester email rendered `Aug 8, 10:30 PM – Aug 9, 1:30 AM`. This is device evidence, not part of the automated `CommonPlateiosTests` count above, and it predates and is unaffected by the later presentation-contract correction, which does not touch timezone rendering or submission code.

### W4-F1 Product Truth & Visual Foundation acceptance

For W4-F1 iOS changes, run focused affected suites using the section 9 command
with the applicable repeated `-only-testing:CommonPlateiosTests/<TestClass>`
filters, then run the complete `CommonPlateiosTests` command unchanged. The
final production tree passed focused W4-F1/affected suites at **166 passed, 0
failed, 0 skipped** and the complete target at **785 passed, 0 failed, 0
skipped, TEST SUCCEEDED**. Both final `xcodebuild test` commands succeeded;
their build/test processing also validated the required app resources,
embedded Fraunces registration, and semantic-color assets. `git diff --check`
and the staged diff check passed where run.

Rendered simulator evidence covered Home at normal Dynamic Type (fully visible
action labels, coherent hierarchy and shape), largest accessibility Dynamic
Type (labels grew/wrapped without clipping and Home remained vertically
scrollable), and dark appearance (legible, differentiated hierarchy/colors).
The final simulator could not programmatically navigate to the verification
email/code stages: the host GUI had no usable input/accessibility route and
the app has no existing UI-test or deep-link route that presents that sheet
without changing behavior. This documentation does not claim final rendered
simulator verification-stage screenshots; source/tests establish structural
verification behavior instead.

Faith performed the final physical-device walkthrough, said it looked good,
and explicitly accepted W4-F1. That physical acceptance supplies the final
rendered/user-visible verification evidence that automation and source tests
cannot substitute for; it does not establish Release/Archive/TestFlight or
production-environment behavior.

### W4-R1 Home and requester experience coverage

The focused onboarding/brand/foundation suites passed **20 tests, 0 failed**.
The complete `CommonPlateiosTests` target passed **795 tests, 0 failed, 0
skipped, TEST SUCCEEDED**. `git diff --check` passed. The fresh independent
review found no MUST FIX, SHOULD FIX, or contract conflict and concluded that
the implementation was ready for visual verification. Faith then completed
the requested visual walkthrough and accepted the observed first-launch,
walkthrough, recurring Home, requester-entry, responsive-control, and
accessibility-size presentation and interaction behavior.

The automated and source-focused tests establish onboarding persistence and
replay state, exact copy and ordering, route wiring, control-size seams,
typography scope, requester presentation labels, and preservation of the
existing identity/requester behavior. They do not establish VoiceOver reading
order, provider delivery or notification reading, Release/Archive/TestFlight
signing or environment behavior, or any configuration-specific result that
was not rendered or exercised. Faith's visual acceptance is the evidence for
the observed rendered and interaction behavior; it does not extend those
environmental or provider claims. The separately authorized verification
Cancel → X correction remains outside the R1 evidence and acceptance record.

### W4-C1 R1 carryover reconciliation

Request Food reconciliation required no additional implementation because the
accepted R1 behavior already satisfied it. The only C1 correction replaced the
verification-modal `Cancel` presentation with the accepted top-leading
`xmark`; the cancellation action, destination, and lifecycle behavior are
unchanged. Focused proof passed **21 tests, 0 failed, 0 skipped**. The complete
`CommonPlateiosTests` target passed **795 tests, 0 failed, 0 skipped, TEST
SUCCEEDED**. Independent review was CLEAN. These source-level presentation
tests are not rendered UI proof; the correction is limited to presentation and
does not alter the verification lifecycle.

### W4-H4 Home continuous scroll composition acceptance

W4-H4 is accepted. It is an iOS-only slice: per section 11, its minimum
verification is focused suites plus the complete `CommonPlateiosTests` target.
No backend, Mongo, or browser-bundle check was required or rerun for H4, and
none is claimed here.

Automated coverage proves the count-sensitive ownership preview (0/1/2/3+ and
`See all N`), the ownership partition — including that an owned request hidden
from the two-card Home preview is still excluded from `Needs help right now` —
the `See all N` destination wiring, one unified Home `ScrollView` with exactly
one `.refreshable`, the persistent-CTA `.safeAreaInset` bottom accommodation,
the shared 24-point content-column authority, and the manual-refresh deadline
contract.

`HomeRefreshCallerCancellationTests` covers the physical-device refresh defect
behaviorally rather than by source text: it drives the production
`HomeExchangeView.awaitWithDeadline`, the production
`RequestStore.fetchRequests()`, and a real `URLSession` behind the existing
`RequestFetchingURLProtocol` stub, and proves that a refresh whose calling task
is cancelled mid-flight still applies the new authoritative requests, that
repeated cancelled refreshes leave the latest authoritative result through the
existing generation/collection-revision fence rather than anything added by the
fix, that an operation losing the manual-refresh deadline is still cancelled and
still reports failure without a spurious `refreshError`, and that an uncancelled
refresh is unchanged. These tests do not, and cannot, prove the physical pull
gesture itself; they prove the refresh path applies authoritative data when the
caller is cancelled the way SwiftUI cancels it.

At acceptance: focused Home/H4/refresh suites passed **115 passed, 0 failed, 0
skipped**; the complete `CommonPlateiosTests` target passed **1,009 passed, 0
failed, TEST SUCCEEDED** for the H4 commit set in isolation and **1,032 passed,
0 failed, 0 skipped, TEST SUCCEEDED** on the full working tree (see the
attribution table below); `git diff --check` passed. Independent
engineering review was CLEAN. The ownership-partition review fix and the
refresh cancellation/lifetime fix were each independently rereviewed CLEAN /
RESOLVED.

**Complete-target total attribution (measured, not inferred).** The 1,032
figure was measured on the full working tree, which also carries unrelated
in-progress W4-R2/W4-S1 and dev-seed work, so it is not an H4 total. Three
complete-target runs were taken during H4 closeout to separate the slices, each
in an isolated `git worktree`:

| Tree | Result |
| --- | --- |
| Clean `W4-Q1` commit (`fb3adcd`), no local changes | 976 passed, 0 failed |
| That commit plus exactly the staged W4-H4 commit set | 1,009 passed, 0 failed |
| Full H4 working tree, including unrelated R2/S1/seed work | 1,032 passed, 0 failed |

**1,009 is the H4-attributable total** and is what the target will report once
the H4 commit lands. H4 contributes exactly 33 cases over the committed Q1 tree:
9 in `HomeContinuousScrollCompositionTests`, 6 in
`HomeOwnershipPartitionRegressionTests`, 6 in
`OwnRequestsSeeAllDestinationTests`, 4 in
`HomeRefreshCallerCancellationTests`, and 8 added to
`HomeExchangeBoardStateTests`. The remaining 23 cases between 1,009 and 1,032
belong to unrelated in-progress work and must not be credited to H4.

**Discrepancy flagged, not silently rewritten.** The W4-Q1 row below records
1,001 for `CommonPlateiosTests` at Q1 acceptance, but a clean checkout of the Q1
commit measures 976. That earlier figure therefore appears to have been taken on
a working tree that also carried then-in-progress work, the same way 1,032 does
here. Q1's own acceptance record is left as written — correcting it belongs to
Q1, not to this slice — but no H4 statement relies on 1,001, and the H4 baseline
below uses the measured 976/1,009 pair instead.

Physical-device verification completed by Faith on a physical iPhone: final
Home proportions and the shared content column, the persistent CTA and its
soft-floating treatment, pull-to-refresh correctness, automatic fresh data on
Home return, larger Dynamic Type, and VoiceOver traversal and focus all passed,
and the native safe-area relationship is accepted. The remaining apparent
CTA-bottom-position difference against Figma is recorded as **NO ACTION /
CONTRACT-LIMITED DEVICE SAFE-AREA DIFFERENCE**: authored CTA bottom padding is
zero and the residual clearance is the device-provided home-indicator safe area,
so moving the CTA lower would require a negative adjustment or safe-area overlap
the accepted contract prohibits.

**Known, accepted limitations.** The repository still has no iOS UI-test
target, so no automated check drives the real pull gesture, the rendered Home
composition, Dynamic Type layout, or VoiceOver traversal; the physical-device
evidence above is the authority for every device-specific safe-area, gesture,
and accessibility observation, and the source and unit tests do not by
themselves establish any of them. Simulator reproduction of the refresh defect
and of the fix was performed with synthetic pointer drags against the local
backend; that is stronger than source inspection but is not physical-device
proof and does not replace it. The authored refresh presentation and polish
remain W4-H3's, and nothing in H4's evidence accepts them. H4 acceptance does
not establish Release/Archive/TestFlight signing or environment behavior, which
remains open (`docs/system-contract.md` section 11).

**Freshness-scope correction (verified).** `docs/system-contract.md` section 1.4
deliberately states Home freshness as "when Home appears" plus manual
pull-to-refresh. Returning CommonPlate to the foreground from the background is
**not** an automatic refetch: with ten open requests present on the backend, an
app foregrounded from the background continued to render Empty Exchange until a
pull-to-refresh was performed, and no `scenePhase` transition invokes
`fetchRequests()`. This was verified on the simulator during documentation sync.
The accepted "fresh data on Home return" physical result is recorded above as
Faith observed it; it is not documented as a background-to-foreground refresh
guarantee. See the open question raised at H4 closeout.

### W4-R4 Structured Meal Requests & Multi-Screenshot Evidence acceptance

**W4-R4 is accepted (not yet COMMITTED).** Faith explicitly accepted W4-R4 on
2026-09-29 on the basis of the complete implementation, automated
verification, independent review, and the physical R4 verification recorded
below. This subsection records the accepted verification state; see the
current weekly spec's W4-R4 card for the full lifecycle and contract history.

**Structured request / Screenshot Assistance automated proof.** Current
focused coverage spans: structured Meal Exchange / Dining Dollars
representation and validation (`src/structuredRequest.ts`,
`src/structuredRequest.test.ts`, `src/createRequestRoute.test.ts`,
`src/createRequestRoute.mongo.test.ts`); multi-screenshot analysis and
deterministic proposal validation (`src/screenshotEligibility.ts`/`.test.ts`,
`src/screenshotProposalValidation.ts`/`.test.ts`,
`src/screenshotProposalRoute.test.ts`, `src/screenshotProposalTypes.ts`);
manual authority and field-level provenance, incomplete-vs-invalid
presentation, and menu-path reset (`RequestFoodFormValidation.swift`,
`RequestFoodView.swift`, `RequestIncompleteVsInvalidValidationTests.swift`,
`RequesterIncompleteVsInvalidHostedTests.swift`); requester rendered
geometry, the DD ordering control, and populated/expanded Meal geometry
(`RequesterFormLayout.swift`, `RequesterFormLayoutBehaviorTests.swift`,
`RequesterFormHostedFidelityTests.swift`, `RequesterFormHostedHarness.swift`,
`RequesterMealPresentationHostedTests.swift`); mounted Meal
presentation/focus/accessibility behavior, preserved-entry rerun
qualification/lifecycle, and the unified Meal provenance OR presentation
(`ScreenshotProposalStore.swift`, `ScreenshotProposalStoreTests.swift`,
`ScreenshotPreservedEntryFeedbackLifecycleTests.swift`); and the durable
request-create operation surfaces R4's structured payload flows through
(`RequestCreateDurableOperationTests.swift`,
`RequestCreatePendingOperationScopeTests.swift`,
`RequestCreateTerminalReconciliationTests.swift`,
`RequestCreationViewTests.swift`, `RequestFoodDraftSessionTests.swift`,
`MealSwipeQuantityTests.swift`, `ParticipantContinuationTests.swift`,
`RemoveEmailTests.swift`).

**Accepted complete iOS target.** The complete `CommonPlateiosTests`
target at R4 acceptance: **1,483 passed, 0 failed, TEST SUCCEEDED**. A final
focused provenance/badge-unification implementation pass measured **225
tests, 0 failures**. This was the accepted baseline at R4 acceptance (section 13 below); it
has since been superseded by the W4-S3 consent-authority revision figure
(1,744 total, 1,742 passed, 0 failed, 2 configuration skips, TEST SUCCEEDED), which is the current accepted baseline.
`git diff --check` was clean after the final implementation;
nothing has been committed for this correction — COMMITTED requires Faith's
separate approval of the final staging set and an actual commit.

**Physical-device proof.** Distinct from the automated/simulator proof above,
Faith completed a physical-iPhone requester and Screenshot Assistance
walkthrough. Requester presentation/interaction confirmed: incomplete
required fields stay neutral and keep `Post request` disabled; DD
ordering-field geometry/copy; adaptive `Post request` placement; collapsed/
expanded Meal presentation; full `Details` wrapping without ellipsis; equal
Meal item/Details hierarchy; materially improved Meal expand/collapse
latency; and the unified Meal provenance presentation. Screenshot Assistance
confirmed: real `PhotosPicker` multi-image selection/analysis; a correct
eligible multi-screenshot structured proposal (three Meal Exchange meals, a
strongly-supported `$2.00` Dining Dollars proposal); no auto-submit; manual
Meal-item and Details authority preserved independently across an eligible
rerun; an untouched screenshot-derived value remaining eligible to update;
provenance clearing/restoration through a later valid reproposal; the exact
qualifying preserved-entry message `Screenshot checked. Your existing entries
were kept.`; its correct absence on a non-qualifying eligible rerun; feedback
cleanup on view disappearance and on Screenshot Assistance disablement; and
the nonqualifying-prior-outcome behavior Faith exercised. Faith did not
record a detailed device transcript for every individual
unsupported/failed/cancelled/nil subcase; no physical proof is claimed for a
subcase not individually observed, and the automated F1+F2 focused proof
(`RequestCreateTerminalReconciliationTests`/`ScreenshotProposalStoreTests`
state-machine coverage) is the record for those exact cases instead. This
physical proof does not establish Release/Archive/TestFlight signing or any
provider environment beyond the observed Screenshot Assistance run.

**Hosted-test methodology notes.** As with W4-D2's
`RequestCreationContinuityHostedGeometryTests` technique above, R4's hosted
requester fidelity tests (`RequesterFormHostedFidelityTests.swift`,
`RequesterFormHostedHarness.swift`,
`RequesterIncompleteVsInvalidHostedTests.swift`,
`RequesterMealPresentationHostedTests.swift`) mount the real production
SwiftUI view in a `UIWindow` and inspect rendered geometry/accessibility
rather than source strings; source-string checks do not substitute for
rendered-geometry proof. Some hosted runs can stall when the Mac idles;
`caffeinate -i` was required for reliable execution during this slice. This is
an incidental test-run/environment note, not a product limitation.

**Accessibility limitation.** Hardware-keyboard Tab traversal into the
mounted hidden Meal editor was not physically established. No failure is
known; this is deferred, unperformed physical evidence owned by W4-A1, not a
demonstrated defect (see the current weekly spec's W4-A1 card).

### W4-S3 Shared Screenshot Assistance Runtime & Local-First Routing acceptance

The W4-S3 runtime baseline is COMMITTED (`3d4287f`); Faith explicitly accepted it on 2026-09-30 and re-accepted it after the retired W4-OBS1/Datadog dependency was removed. Faith then re-accepted W4-S3 (2026-10-01) for the revised Screenshot Assistance consent-authority behavior; that revision is accepted and not yet COMMITTED. The accepted state below is the post-removal state with the consent-authority revision applied. `docs/system-contract.md` section 15 records the accepted runtime truth; the current weekly spec's W4-S3 card owns lifecycle and deferrals.

**Focused iOS coverage.** New focused files under `ios/CommonPlateios/CommonPlateiosTests/` (shared helpers: `ScreenshotAssistanceTestSupport.swift`, `ScreenshotConformanceSchemaSupport.swift`, `ScreenshotS3FixTestSupport.swift`):
- schema-neutral runtime, ordered multi-screenshot input, and the test-only second-schema conformance workflow: `ScreenshotAssistanceRuntimeTests`, `ScreenshotSharedRuntimeConformanceTests`, `ScreenshotConformanceVectorTests`;
- local-first routing, qualification identity/enforcement, empty production registry, and fail-closed routing matrix: `ScreenshotLocalFirstRoutingTests`, `AppleOnDeviceScreenshotProviderTests`, `ScreenshotQualificationFingerprintTests`, `ScreenshotFingerprintBuildScriptTests` (runs the actual build-phase script text under `/bin/bash`);
- external fallback under standing consent, authority timing/loss, single-use runtime transfer-permission binding, evaluation fencing, and the external-transfer request seam (store → runtime → shipped external provider → `ScreenshotProposalService` → `APIClient` → a recording `URLProtocol`, proved by transport request count and store state: zero requests for a retired, cancelled, stale, replayed, consent-less, or authority-less attempt, exactly one for a valid attempt under standing consent): `ScreenshotFallbackAuthorityTimingTests`, `ScreenshotAuthorityAtFallbackTests`, `ScreenshotExternalPermissionBindingTests`, `ScreenshotEvaluationFencingTests`, `ScreenshotExternalRequestSeamTests`;
- revised consent authority (Off → On disclosure, `Not Now`/`Turn On`, persisted contract-bound consent, revocation on Off, legacy-state and corrupt/mismatched-record fail-closed behavior, no per-attempt popup, Off-blocked local and external processing, stale-result fencing after revocation) and disclosure presentation/source wiring (exact copy, both Settings and Request Food entry points): `ScreenshotAssistanceConsentAuthorityTests`, `ScreenshotAssistanceDisclosurePresentationTests`;
- deadline-bounded local orchestration (non-cooperative provider; late completion stale): `ScreenshotDeadlineEnforcementTests`;
- structural boundary tripwires, including that no Datadog/observability package, initialization, or telemetry reference exists in the app target or project: `ScreenshotAssistanceBoundaryTests`;
- updated Requester regressions: `ScreenshotProposalStoreTests`, `ScreenshotPreservedEntryFeedbackLifecycleTests`, `RequestFoodEntryTests`, `RequestCreationViewTests`. `ScreenshotProposalDisclosurePresentationTests` was removed with the pre-S3 disclosure (superseded; `docs/system-contract.md` sections 12–13).

A focused run uses section 9's command with `-only-testing:CommonPlateiosTests/<TestClass>` in place of `-only-testing:CommonPlateiosTests`.

**Backend drift guard.** `shared/screenshot-conformance-vectors.json` is asserted by `src/screenshotConformanceVectors.test.ts` (backend) and `ScreenshotConformanceVectorTests` (iOS). S3 changed no backend route or runtime code. The focused `npx vitest run src/screenshotConformanceVectors.test.ts` run (118 passed) was executed during the acceptance documentation sync; `npm test` and `npm run test:mongo` were **not** rerun for S3 and their baselines below are unchanged.

**Accepted automated baseline (post-OBS1-removal, pre-consent-revision).** Complete `CommonPlateiosTests`: **1,713 passed, 0 failed, 0 skipped**. Release builds succeeded for the generic iOS Simulator and for the unsigned generic iOS device. The qualification fingerprint derived by the always-run `Derive Screenshot Qualification Fingerprint` build phase was identical across Debug, Release-simulator, and Release-device builds. The Release builds are also the proof gate for a Swift 6.3 release-optimizer crash on the synthesized deinit of generic classes (`docs/decisions/screenshot-qualification-fingerprint-and-release-build-constraints.md`); Debug-only runs do not exercise it. `git diff --check` was clean. The 1,713 total is the measured post-removal suite; the OBS1 telemetry-only tests were deleted with the retired dependency. The acceptance also confirmed by source/project inspection that no Datadog package, product, initialization, `ScreenshotAssistanceTelemetry` file, or stale SwiftPM resolution remains. Compilation alone is not a passing result: the result bundle must complete and print `TEST SUCCEEDED`.

**Revised consent-authority verification (Faith re-accepted 2026-10-01).**
- *Focused S3 selection:* `ScreenshotAssistanceConsentAuthorityTests`, `ScreenshotAssistanceDisclosurePresentationTests`, `ScreenshotAssistanceBoundaryTests`, `ScreenshotAuthorityAtFallbackTests`, `ScreenshotDeadlineEnforcementTests`, `ScreenshotEvaluationFencingTests`, `ScreenshotExternalPermissionBindingTests`, `ScreenshotExternalRequestSeamTests`, `ScreenshotFallbackAuthorityTimingTests`, `ScreenshotLocalFirstRoutingTests`, `ScreenshotProposalStoreTests`: **205 passed, 0 failed, 0 skipped, TEST SUCCEEDED**.
- *Builds:* the Release generic iOS Simulator build and the unsigned generic iOS device Release build both **succeeded** (unsigned; not a signed/Archive/TestFlight result).
- *Qualification fingerprint:* the same Screenshot Assistance qualification fingerprint, `d0de0ead6c5c373eea8a1eda71393f6f51ee2205d85074b06be2a72c67421bd9`, was observed across the Debug simulator, test-build Debug, Release simulator, and Release generic-device builds.
- *Independent review:* a fresh independent review found no S3 correctness defect in consent persistence, local-processing authority, external-transfer authority, revocation/races, stale-result fencing, payload boundary, legacy/reset behavior, or disclosure source wiring; no S3 code fixes were required afterward.
- *Physical device:* Faith performed the revised consent flow on a physical iPhone and confirmed (1) an Off → enable attempt shows the disclosure before enabling; (2) `Not Now` leaves Screenshot Assistance Off; (3) `Turn On` enables it; (4) On → Off disables and revokes; (5) a later enable attempt shows the disclosure again. Manual Request Food remained available while Off.
- *Integrated target:* complete `CommonPlateiosTests` — **1,744 total, 1,742 passed, 0 failed, 2 expected configuration skips, TEST SUCCEEDED**. The two skips are the S2.1 development-evaluation tests, which are gated by configuration. This is the current accepted complete-iOS baseline. `git diff --check` passed.
- *Limitation:* source and unit tests prove consent state, authority, fencing, and source wiring; they do not themselves prove SwiftUI presentation, and no iOS UI-test target exists. Presentation was verified by the physical-device walkthrough above only. That walkthrough observed a brief perceptible delay between tapping the enable control and the disclosure appearing; consent sequencing was correct and nothing became enabled before the disclosure. It is a presentation-responsiveness item, not an S3 correctness defect, and is deferred to Candidate Stabilization (UI responsiveness/polish) per the current weekly spec. The walkthrough does not establish Release/Archive/TestFlight signing or endpoint behavior, or provider reachability. `npm test` and `npm run test:mongo` were not rerun for this revision (no backend change).

**Physical-device acceptance and its limits (earlier smoke, pre-revision consent model; the revised-consent walkthrough is recorded above).** A bounded physical-iPhone smoke was performed on an iPhone 16 Pro, iOS 26.3.1, with Apple Intelligence On, using a Debug build. It exercised the real `PhotosPicker` and device preprocessing (Vision OCR) path; the closed production registry (zero entries, so Foundation Models was not invoked despite Apple Intelligence being On) taking the fallback path; the manual flow with no external transfer before the then-current authorization step; and retirement/back-navigation preventing any late result application. These are Faith-observed device results. They do **not** establish Apple local-model extraction quality or qualification (none exists), held-out corpus quality, or S2 thresholds. The smoke used a temporary, since-reverted development LAN backend configuration (`APIConfiguration.localSimulator` pointed at the development Mac), so it does **not** establish Release/Archive/TestFlight signing or endpoint behavior, which remains open (`docs/system-contract.md` section 11). The Settings-Off retirement path was not separately recorded in the smoke. The smoke was not rerun after the OBS1/Datadog removal: that removal changed no requester-visible or device-only boundary, so the recorded smoke remains the device evidence, and the replaced transfer-timing observation is now covered by the transport request-count proof above.

**Accepted verification limitation.** No iOS UI-test target exists; disclosure presentation, retirement, and routing are proven by store/runtime/source-inspection tests plus the physical-device evidence above, not by UI automation. The deadline test proves control returns without waiting for a non-cooperative provider; it does not prove cancellation of a provider that blocks the main actor.

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

These results are reference evidence, not a substitute for rerunning affected checks after future changes. Where an exact later total is recorded, it is retained; otherwise the row records the accepted H1 pass without inventing a new count.

| Check | Result |
| --- | --- |
| `npm run typecheck` | Passed at W4-Q1 acceptance |
| `npm test` | Passed at W4-Q1 acceptance: 1,537 passed, 335 Mongo-gated skipped |
| `npm run test:mongo` | Passed at W4-Q1 acceptance: 335 passed across 24 files |
| `npm run ci-check` | Passed (lint, typecheck, prune, build), at the W4-H2 final ownership rereview — not independently rerun for Q1; see the Q1 coverage subsection above for the checks that were |
| `CommonPlateiosTests` | At W4-R2 acceptance: **1,104 passed, 0 failed**. At W4-H4 acceptance, measured in isolated worktrees: **1,009 passed, 0 failed, TEST SUCCEEDED** for the clean W4-Q1 commit plus exactly the W4-H4 commit set — the figure the target reported once H4 landed. The same clean Q1 commit alone measures 976, and the full H4 working tree including then-in-progress R2/S1 work measured 1,032. See the W4-H4 subsection in section 9 for the attribution table and for the flagged 1,001-versus-976 discrepancy in the Q1 record. At W4-R4 acceptance: **1,483 passed, 0 failed, TEST SUCCEEDED**; a final focused provenance/badge-unification pass separately measured 225 tests, 0 failures At W4-S3 acceptance, as re-accepted after OBS1/Datadog removal: **1,713 passed, 0 failed, 0 skipped**. At W4-S3 consent-authority revision re-acceptance (current accepted baseline): **1,744 total, 1,742 passed, 0 failed, 2 expected configuration skips** (S2.1 development-evaluation tests gated by configuration), TEST SUCCEEDED. |
| Release generic iOS Simulator build | Succeeded at W4-S3 acceptance and again at the consent-authority revision re-acceptance |
| Release unsigned generic iOS device build | Succeeded at W4-S3 acceptance and again at the consent-authority revision re-acceptance (unsigned; not a signed/Archive/TestFlight result) |
| `npm run build:client` | Passed; no tracked bundle diff (no browser-client source changed in N2, D1, H2, N0, or Q1) |
| `git diff --check` | Passed |

Physical-device proof (helper terminated-launch tap routing; requester-fulfillment push to Home with the one-time notice) has passed on a physical iPhone and is recorded as accepted runtime truth in `docs/system-contract.md` sections 8.2–8.3. It is device evidence, not part of the automated suite above, and it does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W3-C1 physical acceptance (meal-swipe quantity visible in Active Requests, Request Detail, active-reservation presentation, fulfillment/order context, and helper new-request notification/email) is recorded above and in `docs/system-contract.md` section 6.2. It does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W3-D1 automated/independent-review evidence (exact-operation idempotency and reconciliation, the bounded-recovery operation tombstone, and durable iOS unresolved-operation persistence and reconciliation) is recorded above and in `docs/system-contract.md` section 6.3. **W3-D1 was accepted without the integrated physical-iPhone runtime scenarios described above.** That remaining physical-runtime proof is an accepted verification limitation, not evidence that the behavior was physically proven; it does not establish Release/Archive/TestFlight signing or environment behavior either, which remains open (section 11 of the same document).

W3-H1 physical-device acceptance is recorded above. It closes H1's reservation-lifecycle device gate only; it does not close the Release/Archive/TestFlight APNs environment gate.

W3-N3 physical-device/environmental acceptance (real future Later request: no early email/APNs initiation, then eligibility-time email + APNs initiation, observed inbox arrival and physical notification presentation) is recorded above and in `docs/system-contract.md` section 8.5. It closes N3's environmental acceptance gate; the physical request's `createdAt` was not old enough to reproduce the former long-lookback omission on its own, which real-Mongo integration coverage establishes separately. It does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W3-N2 physical-device acceptance (push enable/disable reaching authoritative On/Off, relaunch-preserved push-management truth, ambiguous push recovery/retry, participant-authorized in-app email unsubscribe, later signup returning to Check Your Email rather than stale Off, and email/push channel independence) is recorded above and in `docs/system-contract.md` sections 8.6 and 9.8–9.9. It closes N2's device-acceptance gate; it does not establish verified email delivery/reading, a production APNs environment, TestFlight signing/configuration, or production backend reachability, which remain open (section 11 of the same document). Sandboxed local-loopback bind failures (EPERM/timeouts) observed during N2 backend verification are recorded as a verification-environment limitation, not a product defect (section 4 notes above).

The non-Eastern `DatePicker` timezone proof required for W3-R1 (see section 9) is likewise device evidence, not part of the automated suite above.

W3-I4 acceptance evidence and its accepted CoreSimulator verification limitation are recorded above (Remove Verified Identity (W3-I4) coverage) and in `docs/system-contract.md` section 3.1.

W4-H2 acceptance evidence (participant-scoped request-list ownership projection, the authoritative backend self-claim guard, iOS ownership presentation/action-gating, and the functional Home/navigation/refresh contract) is recorded above (Home & Navigation Architecture (W4-H2) coverage) and in `docs/system-contract.md` section 1.3. Faith accepted H2's functional pull-to-refresh behavior; the repository/session contains no explicit record of a physical-iPhone reproduction-or-rule-out walkthrough for the Simulator-only native-`.refreshable`-activation defect noted in the current weekly spec's W4-H2 section, and this documentation does not claim that verification occurred. It does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document). The current authored refresh visual/motion presentation is explicitly not part of H2's acceptance evidence; it is deferred to W4-H3 and is not accepted as final.

W4-N0 acceptance evidence (authorization/privacy/cache-isolation for the participant-authorized Email Request Alert state read, current-participant stale-authority fencing, and Subscriber-lifecycle-to-state mapping) is recorded above (Email Request Alert State Authority (W4-N0) coverage) and in `docs/system-contract.md` section 9.10. No physical-device or environmental proof was required; it does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W4-Q1 acceptance evidence (the participant-authorized request-creation eligibility read sharing its substantive quota authority with `POST /api/request`, authorization/privacy/cache-isolation including a mounted rate-limited response, the current-as-of-read-to-POST-refusal boundary, and iOS fail-closed/stale-response/authority-retirement behavior) is recorded above (Request Creation Eligibility Authority (W4-Q1) coverage) and in `docs/system-contract.md` section 7.1. No physical-device or environmental proof was required; it does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W4-H4 acceptance evidence (the count-sensitive Home ownership preview and `See all N`, the ownership partition, one unified Home scroll with a single native `.refreshable`, the persistent `Request a Meal` structural bottom accommodation and shared 24-point content column, and pull-to-refresh actually applying authoritative data) is recorded above (W4-H4 Home continuous scroll composition acceptance) and in `docs/system-contract.md` section 1.4. Faith's physical-device pass is the authority for the rendered composition, gesture, Dynamic Type, and VoiceOver observations; no automated check drives them. H4 accepts refresh correctness only — the authored refresh presentation remains deferred to W4-H3 and is not accepted as final. It does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W4-R2 acceptance evidence (the pushed Request Food navigation, the Q1-consuming early eligibility boundary and its distinct retryable/exhausted presentations, in-memory draft-session continuity, Timing's quick-time/native-picker presentation, the Screenshot Assistance completion acknowledgement, the first-use consent/disclosure gate and its Off-state re-entry path, Screenshot Help's centered-overlay presentation, Posting/Success timing and haptics, D1's continued haptic-free distinctness from definitive failure, no R2-authored Home insertion, and the zone-scoped `YOUR REQUEST` eyebrow suppression) is recorded above (W4-R2 Requester Journey Integration acceptance) and in `docs/system-contract.md` section 13, section 1.4, and section 3.1. Faith's physical-device walkthroughs are the authority for the rendered navigation, consent/Off-state, Screenshot Help, motion/haptic, and Remove Email presentation observations; no automated check drives them. It does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document). The new-request push notification's title/body composition remains W4-N1's future work, not R2's, per the carve-out recorded in the W3-C1 coverage subsection above.

W3-H2 durable one-successful-participation enforcement, marketplace/detail privacy isolation, and fulfillment re-entry evidence is recorded above and in `docs/system-contract.md` section 5.1. **W3-H2 was accepted without an iOS UI-test target**, so the literal SwiftUI stale-detail render/tap scheduling sequence was not driven end-to-end through UI automation or physical-device interaction; production predicate/action logic and wiring are covered by unit/source-level tests and the full iOS target instead. That remaining limitation is accepted, not a failed or pending check, and must not be described as UI-test or physical-device proof; it does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W4-R4 acceptance evidence (structured Meal Exchange/Dining Dollars representation, multi-screenshot Assistance proposal validation, per-field manual authority/provenance, incomplete-vs-invalid presentation, requester hosted-geometry fidelity, and the unified Meal-row provenance badge correction) is recorded above (W4-R4 Structured Meal Requests & Multi-Screenshot Evidence acceptance) and in the current weekly spec's W4-R4 card. **Faith explicitly accepted W4-R4 on 2026-09-29.** Its complete `CommonPlateiosTests` result (1,483 passed, 0 failed, TEST SUCCEEDED) was the accepted baseline at R4 acceptance and has since been superseded by the W4-S3 consent-authority revision figure (1,744 total, 1,742 passed, 0 failed, 2 configuration skips, TEST SUCCEEDED), the current accepted baseline recorded in the table above. Hardware-keyboard Tab traversal into the mounted hidden Meal editor remains deferred to W4-A1 and is not an R4 acceptance blocker. This evidence does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document). R4 is ACCEPTED, not yet COMMITTED.

W3-I1 physical/environmental verification remains unperformed for real NYU verification-email receipt and real-code redemption; uninstall/reinstall and new-device reverification; remaining Keychain lifecycle behavior; backup/device-migration exclusion where practical; and a real-address Change Email flow. The accepted W3-H1 flow has physically established same-install authority retention through terminate/relaunch continuation; neither that result nor source/simulator inspection proves the remaining outcomes.
