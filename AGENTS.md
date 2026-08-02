# Repository Guidelines

## Project Structure

`app.ts` starts the Node/Express service; backend routes and helpers live in
`src/`, with Mongoose models in `models/`. Browser client source is
`src/client/*.ts`; its tracked generated bundles are `public/js/*.js`. Static
pages, CSS, and images are in `public/`; maintenance scripts are in `scripts/`.
The SwiftUI app and XCTest target are under `ios/CommonPlateios/`.

## Sources of Truth

- `docs/system-contract.md` is the durable current technical contract. Update
  it when accepted runtime contracts change.
- `docs/testing.md` defines verification commands, prerequisites, and
  limitations.
- Faith may maintain local, ignored weekly implementation specs under `docs/`,
  such as `docs/week-3-notifications-spec.md`. Use them when present, but a
  fresh clone must not depend on them.
- Completed weekly specs and reviews may be kept locally under `docs/archived/`.
- Notion is Faith's separate learning and execution workspace.

## Change Discipline

Inspect current code and tests before editing. Deliver one endpoint and one
user-flow slice at a time, and preserve accepted architecture unless repository
evidence requires reconsideration. Do not silently resolve product questions:
return unresolved behavior decisions to Faith before implementation.

Do not combine correctness fixes, product changes, broad cleanup, and
documentation into an unreviewable diff. Do not add authentication, chat,
maps, payments, push notifications, SMS, or major redesigns unless directly in
scope. Do not commit unless Faith explicitly asks.

## Backend Rules and Traps

`src/day4Errors.ts` is the shared structured API-error contract despite its
milestone-era name. Reuse it; do not introduce Week-specific error modules.
New endpoint behavior should normally live in a focused `src/*Route.ts` or
`src/*Routes.ts` module with minimal `app.ts` registration.

`app.ts` connects to MongoDB, schedules jobs, and listens at module scope. Some
tests therefore inspect its source text instead of executing a test app. Do not
broadly reformat, reorder, or refactor `app.ts` inside a feature slice, and do
not reorder `models/db.ts` merely for style. Preserve the transaction,
uniqueness, privacy-by-omission, token, and ambiguous-mutation boundaries in
`docs/system-contract.md`.

## Browser Client Rules

Edit `src/client/*.ts`; never edit generated `public/js/*.js` directly. After
client changes, run `npm run build:client`, inspect regenerated bundle diffs,
and preserve the generated-file banner. CI does not automatically enforce
generated-output cleanliness. Keep focused client tests near their source.

## iOS Rules

Preserve the `APIClient` → `RequestService` → `RequestStore` → SwiftUI
boundary. Raw claim tokens and exact ambiguity-recovery payloads remain private
to the in-memory store: do not expose or persist them without an accepted
product and security contract. Never fabricate claim, placement, or credential
state after an ambiguous response. Preserve operation identities, collection
revisions, stale-response guards, and one-use recovery limits.

Do not broadly split `RequestStore` during unrelated work. Add Week 3 tests in
focused files where practical rather than continually extending
`ClaimFlowTests.swift`; do not split existing large test files during unrelated
work.

## Subscription Boundary

Signup currently auto-confirms incorrectly. The accepted lifecycle is
`pending → confirmed → unsubscribed`; pending and unsubscribed subscribers
receive no alerts. Subscriptions must remain paused until confirmation and
unsubscribe are both implemented, accepted, and tested. Do not unpause signup
or choose token/reconfirmation behavior without Faith's decision and the Week
3 spec.

## Verification

`docs/testing.md` is authoritative. Use this compact minimum:

- TypeScript/backend: `npm run typecheck` plus focused tests.
- Complete non-Mongo backend: `npm test`.
- Mongo persistence, transactions, uniqueness, or index work: `npm run test:mongo` in addition to `npm test`. `npm test` skips the real Mongo suite (currently 27 Mongo-gated tests).
- Browser client: focused tests, `npm run typecheck`, and `npm run build:client`.
- iOS or cross-stack: focused iOS tests and the complete `CommonPlateiosTests` target.
- Every change: `git diff --check`.
- Before committing: inspect `git status` and run `git diff --cached --check`.

Use a replica set for Mongo integration testing. Keep `.env` untracked; never
commit secrets or use production-like databases with local seed tools.

## Documentation Boundaries

Do not copy implementation-chat transcripts into tracked docs or combine Notion
learning plans with technical specifications. `system-contract.md` records
durable present runtime truth; local weekly specs record active implementation
sequencing and unresolved decisions; they are not durable repository
documentation. `AGENTS.md` contains lasting repository-operating rules only:
do not add weekly status, temporary Day notes, or implementation chronology
here.

## Safety Invariants

- Public request data is allowlisted.
- Pickup names and raw claim tokens are winner-only.
- Provider acceptance is not verified delivery, reading, or pickup.
- Ambiguous mutations are never automatically retried.
- Fulfillment email failure does not undo placement.
- No recovery flow may suggest placing a second external order.
- Subscriptions remain paused until confirmation and unsubscribe work.
