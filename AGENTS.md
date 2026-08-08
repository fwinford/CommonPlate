# Repository Guidelines

## Project Structure

`app.ts` starts the Node/Express service. Backend routes and helpers live in
`src/`, with Mongoose models in `models/`.

Browser client source is `src/client/*.ts`; tracked generated bundles are
`public/js/*.js`. Static pages, CSS, and images are in `public/`. Maintenance
scripts are in `scripts/`.

The SwiftUI app and XCTest target are under `ios/CommonPlateios/`.

## Sources of Truth

* `docs/system-contract.md` is the durable current technical contract. Update
  it only after accepted runtime behavior changes.
* `docs/testing.md` defines verification commands, prerequisites, organization,
  limitations, and accepted baselines.
* The current local weekly implementation spec owns active technical contracts,
  sequencing, dependencies, constraints, and engineering deferrals.
* Local weekly specs may be ignored by Git. Use them when present, but a fresh
  clone must not depend on them.
* `docs/decisions/` contains durable cross-week technical decisions.
* Completed weekly specs and reviews may be stored locally under
  `docs/archived/`.
* Notion is Faith’s separate learning, execution, question, and reflection
  workspace.

When sources conflict, identify the conflict. Do not silently choose one.

## Change Discipline

Inspect current code, tests, Git state, and the applicable contract before
editing.

Deliver one accepted endpoint or user-flow slice at a time. Preserve accepted
architecture unless repository evidence requires revisiting it.

Do not silently resolve product questions. If the accepted behavior is
incomplete or conflicts with repository evidence, stop and return the decision
to Faith.

Keep correctness fixes, product changes, broad cleanup, and documentation
separable enough to review.

Do not introduce unrelated features or redesigns unless they are explicitly in
scope.

Do not commit unless Faith explicitly asks.

## Backend Rules and Traps

`src/day4Errors.ts` is the shared structured API-error contract despite its
milestone-era name. Reuse it; do not create new Week-specific error modules.

New endpoint behavior should normally live in a focused `src/*Route.ts` or
`src/*Routes.ts` module with minimal `app.ts` registration.

`app.ts` connects to MongoDB, schedules jobs, and listens at module scope. Some
tests inspect its source text instead of executing a test app. Do not broadly
reformat, reorder, or refactor `app.ts` within an unrelated feature slice.

Do not reorder `models/db.ts` merely for style.

Preserve the transaction, uniqueness, privacy-by-omission, credential,
operation-identity, and ambiguous-mutation boundaries recorded in
`docs/system-contract.md`.

Use atomic conditional database mutations for lifecycle transitions. Do not
replace an accepted atomic mutation with read-check-save behavior.

## Browser Client Rules

Edit `src/client/*.ts`; never edit generated `public/js/*.js` directly.

After browser-client changes:

* run focused client tests;
* run `npm run typecheck`;
* run `npm run build:client`;
* inspect regenerated bundle diffs;
* preserve the generated-file banner.

CI does not independently determine whether generated bundle differences are
intentional.

## iOS Rules

Preserve the:

```text
APIClient → RequestService → RequestStore → SwiftUI
```

boundary.

Raw claim tokens and exact ambiguity-recovery payloads remain private to the
owning store. Do not expose or persist them without an accepted product and
security contract.

Never fabricate claim, placement, notification, subscription, or credential
state after an ambiguous response.

Preserve operation identities, collection revisions, stale-response guards,
cancellation boundaries, and one-use recovery limits.

Do not broadly split `RequestStore` during unrelated work.

Add new iOS tests in focused files where practical rather than continually
extending large existing test files. Do not reorganize existing test files
during an unrelated slice.

## Subscription and Public-Action Boundary

The accepted subscriber lifecycle is:

```text
pending → confirmed → unsubscribed
```

Pending and unsubscribed subscribers are ineligible for alerts.

`docs/system-contract.md` and the current weekly technical spec define current
activation, eligibility, confirmation, unsubscribe, credential, delivery, and
pause behavior.

Do not change any of the following without an accepted product and technical
contract:

* `PUBLIC_ACTIONS_PAUSED`;
* subscriber eligibility;
* confirmation or unsubscribe credentials;
* reconfirmation behavior;
* activation sequencing;
* alert-delivery eligibility;
* notification-channel ownership.

Provider acceptance is not verified delivery, reading, or pickup.

## Verification

`docs/testing.md` is authoritative.

Use this compact minimum:

* TypeScript/backend: `npm run typecheck` plus focused tests.
* Complete non-Mongo backend: `npm test`.
* Mongo persistence, transactions, uniqueness, concurrency, or index work:
  `npm run test:mongo` in addition to `npm test`.
* Browser client: focused tests, `npm run typecheck`, and
  `npm run build:client`.
* iOS or cross-stack work: focused iOS tests and the complete
  `CommonPlateiosTests` target.
* Every change: `git diff --check`.
* Before committing: inspect `git status` and run
  `git diff --cached --check`.

`npm test` does not replace the real Mongo integration suite.

Use a replica set for Mongo integration testing.

Keep `.env` untracked. Never commit secrets or use production-like databases
with local seed or integration tools.

Verification output must distinguish:

* tests actually executed;
* tests skipped by configuration;
* behavior verified only by source inspection;
* behavior verified manually on a simulator or physical device;
* behavior not yet verified.

## Documentation Boundaries

Do not copy implementation-chat transcripts into repository documentation.

Do not combine Notion learning plans with technical specifications.

`docs/system-contract.md` records durable accepted runtime truth, not proposed
behavior.

`docs/testing.md` changes only when verification commands, prerequisites,
organization, limitations, or accepted baselines change.

The current weekly spec records active sequencing, unresolved decisions,
technical consequences, and engineering deferrals.

`AGENTS.md` contains lasting repository-operating rules only. Do not add weekly
status, temporary Day notes, implementation chronology, or changing test totals.

Keep `CLAUDE.md` as a thin bridge to `AGENTS.md`, with only genuinely
Claude-specific instructions added beneath the import.

## Safety Invariants

* Public request data is explicitly allowlisted.
* Pickup names and raw claim tokens are winner-only.
* Credentials, tokens, signatures, and secrets are never logged or exposed.
* Provider acceptance is not verified delivery, reading, or pickup.
* Ambiguous mutations are never automatically retried.
* Fulfillment email failure does not undo committed placement.
* No recovery path may suggest placing a second external order.
* No client may fabricate backend lifecycle or subscription truth.
* Public-action activation must fail closed when required configuration is
  missing.
* Privacy promises in the product must match runtime behavior.

## AI Agent Workflow

Work within one accepted endpoint or user-flow slice at a time.

Use only the relevant section of the current weekly technical spec and the
files required for the slice. Do not load or restate the full roadmap, product
history, audit ledger, or unrelated documents when narrower context is
sufficient.

Before editing, inspect:

* current code;
* relevant tests;
* Git status and existing changes;
* applicable technical contracts;
* known limitations and deferrals for the slice.

If the task introduces a new slice, a changed product or technical contract, or
an independent review while the current session contains unrelated
implementation history, stop before editing and tell Faith that a fresh agent
session is required.

Within the same accepted slice, continue only for:

* focused implementation;
* fixes;
* focused tests;
* review responses;
* documentation required by that slice.

Keep implementation, engineering review, and product review separate.

Independent reviews should evaluate:

* the accepted contract;
* relevant diff or files;
* verification results;
* known limitations and deferrals.

Do not rely on the implementing agent’s reasoning transcript as review
evidence.

Do not silently make product decisions. If the accepted contract is incomplete
or conflicts with repository evidence, stop and return the decision to Faith.

Before returning, report:

* behavior implemented or reviewed;
* files changed;
* verification performed and its limitations;
* unresolved findings and assigned deferrals;
* whether the stated stop condition was met.

Never add Claude, Anthropic, Codex, OpenAI, AI-generated, generated-by, or
co-authored attribution to commits or pull requests.

Do not commit unless Faith explicitly asks.
