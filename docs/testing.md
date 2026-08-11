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

**Week 4 deferral.** `Meal swipes: N` is technically correct but its user-facing meaning and visual hierarchy are deferred to Week 4; that resolution must not reopen C1 data semantics, backend behavior, validation rules, or notification content.

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

The current accepted baseline is **550 passed, 0 failed, TEST SUCCEEDED**. Compilation alone is not a passing test result: the result bundle must complete and the output must contain `TEST SUCCEEDED`. Xcode GUI and terminal runs use the same shared scheme and `CommonPlateiosTests` target. The increase includes the accepted W3-I1 participant-identity coverage described in section 4.

Automated routing tests (this target included) prove tap-routing logic against stubbed backend resolution; they do not by themselves prove real APNs terminated-launch handoff on a device. Physical-device proof was required for helper terminated-launch tap routing and for requester-fulfillment push, and both have now passed on a physical iPhone. Release/Archive/TestFlight signing and environment behavior is unrelated evidence and remains a separate, still-open environmental gate (see `docs/system-contract.md` section 11).

Automated and source-text assertions can prove that `RequestFoodView` installs the NYU/New York timezone and calendar into the SwiftUI environment; they cannot prove what a real `DatePicker` renders on a device actually configured to a different timezone. W3-R1 required physical-device verification on a non-Eastern device for exactly that reason: an iPhone configured to Phoenix time (no DST offset from New York for part of the year) displayed the intended NYU/New York wall-clock selection of 10:30 PM rather than device-local Phoenix time, and submitted `windowStart = 2026-08-09T02:30:00.000Z`, `visibleFrom = 2026-08-09T02:30:00.000Z`, and `expiresAt = 2026-08-09T05:30:00.000Z`; the requester email rendered `Aug 8, 10:30 PM – Aug 9, 1:30 AM`. This is device evidence, not part of the automated `CommonPlateiosTests` count above, and it predates and is unaffected by the later presentation-contract correction, which does not touch timezone rendering or submission code.

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
| `npm run typecheck` | Passed at the H2 closeout |
| `npm test` | Passed at the H2 closeout: 1,378 passed, 321 Mongo-gated skipped |
| `npm run test:mongo` | Passed at the H2 closeout: 321 passed across 22 files |
| `npm run ci-check` | Passed (lint, typecheck, prune, build) |
| `CommonPlateiosTests` | H2 closeout: 744 passed; 0 failed; TEST SUCCEEDED |
| `npm run build:client` | Passed; no tracked bundle diff (C1 closeout; no browser-client source changed in N2, D1, or H2) |
| `git diff --check` | Passed |

Physical-device proof (helper terminated-launch tap routing; requester-fulfillment push to Home with the one-time notice) has passed on a physical iPhone and is recorded as accepted runtime truth in `docs/system-contract.md` sections 8.2–8.3. It is device evidence, not part of the automated suite above, and it does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W3-C1 physical acceptance (meal-swipe quantity visible in Active Requests, Request Detail, active-reservation presentation, fulfillment/order context, and helper new-request notification/email) is recorded above and in `docs/system-contract.md` section 6.2. It does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W3-D1 automated/independent-review evidence (exact-operation idempotency and reconciliation, the bounded-recovery operation tombstone, and durable iOS unresolved-operation persistence and reconciliation) is recorded above and in `docs/system-contract.md` section 6.3. **W3-D1 was accepted without the integrated physical-iPhone runtime scenarios described above.** That remaining physical-runtime proof is an accepted verification limitation, not evidence that the behavior was physically proven; it does not establish Release/Archive/TestFlight signing or environment behavior either, which remains open (section 11 of the same document).

W3-H1 physical-device acceptance is recorded above. It closes H1's reservation-lifecycle device gate only; it does not close the Release/Archive/TestFlight APNs environment gate.

W3-N3 physical-device/environmental acceptance (real future Later request: no early email/APNs initiation, then eligibility-time email + APNs initiation, observed inbox arrival and physical notification presentation) is recorded above and in `docs/system-contract.md` section 8.5. It closes N3's environmental acceptance gate; the physical request's `createdAt` was not old enough to reproduce the former long-lookback omission on its own, which real-Mongo integration coverage establishes separately. It does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W3-N2 physical-device acceptance (push enable/disable reaching authoritative On/Off, relaunch-preserved push-management truth, ambiguous push recovery/retry, participant-authorized in-app email unsubscribe, later signup returning to Check Your Email rather than stale Off, and email/push channel independence) is recorded above and in `docs/system-contract.md` sections 8.6 and 9.8–9.9. It closes N2's device-acceptance gate; it does not establish verified email delivery/reading, a production APNs environment, TestFlight signing/configuration, or production backend reachability, which remain open (section 11 of the same document). Sandboxed local-loopback bind failures (EPERM/timeouts) observed during N2 backend verification are recorded as a verification-environment limitation, not a product defect (section 4 notes above).

The non-Eastern `DatePicker` timezone proof required for W3-R1 (see section 9) is likewise device evidence, not part of the automated suite above.

W3-H2 durable one-successful-participation enforcement, marketplace/detail privacy isolation, and fulfillment re-entry evidence is recorded above and in `docs/system-contract.md` section 5.1. **W3-H2 was accepted without an iOS UI-test target**, so the literal SwiftUI stale-detail render/tap scheduling sequence was not driven end-to-end through UI automation or physical-device interaction; production predicate/action logic and wiring are covered by unit/source-level tests and the full iOS target instead. That remaining limitation is accepted, not a failed or pending check, and must not be described as UI-test or physical-device proof; it does not establish Release/Archive/TestFlight signing or environment behavior, which remains open (section 11 of the same document).

W3-I1 physical/environmental verification remains unperformed for real NYU verification-email receipt and real-code redemption; uninstall/reinstall and new-device reverification; remaining Keychain lifecycle behavior; backup/device-migration exclusion where practical; and a real-address Change Email flow. The accepted W3-H1 flow has physically established same-install authority retention through terminate/relaunch continuation; neither that result nor source/simulator inspection proves the remaining outcomes.
