# CommonPlate system contract

## 1. Scope and release boundary

CommonPlate currently supports one journey: **create → list → claim → fulfill → placed**. The iOS client and backend are for internal simulator/testing use; they are not ready for student distribution or TestFlight.

Current scope excludes authentication, chat, maps, push, payments, cancellation, pickup confirmation, and any no-show lifecycle. The legacy web fulfillment page remains disabled and cannot place an order.

## 2. Request lifecycle and availability

| Persisted state | Meaning | Effective availability |
| --- | --- | --- |
| `open` | Awaiting a helper | Available only before `expiresAt` and with at least five full minutes remaining to claim. |
| `claimed` | Reserved for one helper | Not publicly available while its active claim has not expired; it may become claimable again after claim expiry if the request itself remains eligible. |
| `placed` | Placement was recorded | Never available. |

Backend time is authoritative for availability, the five-minute claim threshold, and claim deadlines. Public list membership is effective availability, not simply the stored `status`; listed records are projected as `open`. `expiresAt` ends availability. `deleteAt` controls TTL retention: it initially matches `expiresAt`, while placement retains the request for seven days from `placedAt` by moving `deleteAt` without changing `expiresAt`.

## 3. Public and private data boundaries

The public request projection is allowlisted: `id`, vendor, food, pickup-window text and bounds, persisted/projection status, `createdAt`, and `expiresAt`. It is used for list and detail responses.

| Private data | Boundary |
| --- | --- |
| Requester email and pickup name | Never public. Pickup name is returned only in the successful claimant's claim response. |
| Claim token, token digest, claim deadline, claim timestamps | Never public. The raw token is claimant authorization; the backend persists only its digest. |
| `deleteAt`, requester-notification state, fulfillment/contact fields, and other internal fields | Never public. |
| Helper email | May be sent to the requester in the committed-placement email for coordination. |

## 4. Claim contract

Claiming is an atomic conditional mutation, so one eligible attempt wins. The winning response returns the raw token once; iOS keeps it only in private in-memory store state, while the backend keeps an HMAC digest. One live iOS app process holds at most one active claim. Navigating back does not release it; there is no release operation.

A claim lasts at most 15 minutes and is capped by `expiresAt`. Its holder may receive one five-minute extension only when the full extension fits before request expiry. A readable `INTERNAL_FAILURE` from claim is ambiguous: iOS does not automatically retry it and never permits ordering without a confirmed active claim and its raw token.

## 5. Fulfillment contract

Fulfillment requires a valid, unexpired active claim token. In one MongoDB transaction, the backend conditionally transitions the request from `claimed` to `placed` and creates its Fulfillment ledger record. A unique Fulfillment `requestId` index independently protects one fulfillment per request.

`orderNumber` is a digits-only string, not a number; leading zeroes are preserved. The requester email is submitted only after placement commits. Email failure does not undo placement, and failure to clean up the database session cannot replace the committed placement result.

Fulfillment `INTERNAL_FAILURE` is ambiguous. iOS performs one read-only request-status check, then permits at most one exact-payload CommonPlate-only resend using the retained in-memory token and submission. It never instructs the helper to place another external order.

## 6. Request-creation contract

Creation uses strict backend validation for canonical and legacy request shapes, email, required text, scheduling bounds, and a still-usable scheduled end time. Where iOS can know an error locally, it validates before submission (including required fields, email, and scheduling/form constraints).

Creation has no operation identity. If iOS cannot confirm a create outcome, it blocks further creation for the lifetime of that `RequestStore`/app process to avoid duplicates. Durable reconciliation and backend idempotency do not exist. `REQUEST_CREATION_FAILED` therefore remains a Week 3 reconciliation concern rather than proof that no request was created.

## 7. Daily request abuse control

CommonPlate attempts to limit each email to three requests per day. The backend counts before creating, serially in the handler; this is best-effort abuse control, not an atomic quota transaction. A failed count read fails closed. Concurrent create requests can exceed the limit. Atomic enforcement is deferred to Week 5 if usage requires it.

## 8. Email and notification truth

Provider acceptance means only that CommonPlate submitted an email to the provider. It does not prove delivery, reading, or pickup; no email result is described as verified delivery.

| Record/state | Owner and meaning |
| --- | --- |
| `Request.notificationStatus` (`pending`, `sent`, `failed`) | Requester placement-email submission state only, recorded after committed placement. |
| `SendLog` (`sent`, `fail`) | Helper-alert and digest send ledger / duplicate-send guard. It is not requester placement-email state. |

## 9. Subscriber lifecycle

The current signup code is incorrect for a confirmed-subscription system: it sends a confirmation link but auto-confirms the subscriber in the signup handler. Confirmation and unsubscribe routes do not exist. Signup must remain paused while this remains true.

The accepted target lifecycle is `signup → pending → confirmed → unsubscribed`: pending and unsubscribed subscribers receive no alerts; a confirmation link changes pending to confirmed; an unsubscribe action changes confirmed to unsubscribed; signing up again starts a new pending confirmation instead of silently reactivating alerts. This target lifecycle is not implemented today.

## 10. Public-actions pause and scheduled jobs

`PUBLIC_ACTIONS_PAUSED` fails closed unless explicitly set to `false` or `0`. It blocks public request creation, subscription signup, claim and claim-extension mutations, real-time helper alerts, and hourly subscriber digests. It does not block fulfillment: a valid active claim token is already the authorization to record an order, and blocking that path could strand a helper who has already placed one.

`CRON_ENABLED=true` controls only the hourly expired-request cleanup backup to TTL deletion. The hourly digest, daily confirmed-subscriber `dailyCount` reset, and ten-minute SendLog failure monitor are registered independently of `CRON_ENABLED`; the digest additionally exits when public actions are paused.

## 11. Durable deferrals that constrain current behavior

- Confirmation and unsubscribe routes/lifecycle for alerts.
- Provider timeouts and durable email-outcome persistence.
- Create idempotency and reconciliation.
- Paid-but-unrecorded recovery beyond the in-memory, one-resend fulfillment safeguard.
- Physical-device and release backend configuration.
- Full privacy and accessibility review.
