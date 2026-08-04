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
| Confirmation token, its digest, expiry, and send-ownership fields | Never public. The raw confirmation token exists only in the emailed link; the backend persists only its SHA-256 digest. |
| Used-confirmation-token receipt (`lastConfirmedTokenDigest`, `lastConfirmedTokenExpiresAt`) | Never public. |
| Unsubscribe signing secret (`UNSUBSCRIBE_SIGNING_SECRET`) | Never public and never emailed. It is the only thing that makes an unsubscribe link authentic; nothing derived from it is stored. |
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

The lifecycle is `signup → pending → confirmed → unsubscribed`. Only `confirmed` subscribers are eligible for real-time helper alerts and the hourly digest; `pending` and `unsubscribed` subscribers are excluded by both the alert query and the recent-request path. Signing up again never silently reactivates alerts.

Signup is implemented. Confirmation is implemented as an internal backend primitive (section 9.4) reached by a public browser flow (section 9.5). Unsubscribe credentials and their emailed links are implemented (section 9.6), and so is unsubscribe redemption (section 9.7). Rows already marked `confirmed` by the removed auto-confirm handler stay `confirmed` and alert-eligible; no slice migrated or modified legacy confirmed rows. Signup, confirmation, and alert delivery all remain paused (section 10).

The accepted end-to-end runtime path, proven end to end against real MongoDB through the production handlers and the real emails, is:

```text
signup → pending Subscriber → confirmation email → safe confirmation GET
→ explicit confirmation POST → confirmed and alert-eligible
→ alert or digest email carrying a valid unsubscribe link
→ safe unsubscribe GET → explicit unsubscribe POST → unsubscribed and ineligible
```

Signing up again after unsubscribing rotates a fresh pending confirmation credential onto the same document — preserving `_id`, `unsubscribeCredentialVersion`, `dailyCount`, `lastSentAt`, `bounced`, `unsubscribedAt`, and SendLog history — and reconfirming restores eligibility. The unsubscribe link emailed before any of that still opens the page and still unsubscribes afterwards. Neither half of either emailed link mutates anything on a GET.

Every Subscriber holds a revocable unsubscribe credential by construction: it is signed on demand from `_id` and `unsubscribeCredentialVersion` (section 9.6) rather than stored, so no confirmed-row credential invariant is needed and no unsubscribe credential is persisted in any form. The legacy raw `unsubToken` field is retained on existing rows but excluded from ordinary projections (`select: false`); nothing issues, requires, or explicitly selects one, and confirmation still clears it when it transitions a row that carries one.

### 9.1 `POST /api/subscribe`

The handler validates a strict body: the sole field is `email`, unexpected fields are rejected, and the address is trimmed and lowercased before any database work. Invalid input returns the shared structured error envelope with HTTP 400 and `INVALID_EMAIL`.

Every valid attempt — brand-new, unexpired pending, expired pending, unsubscribed, and already-confirmed — returns the identical generic response, so the response cannot be used to enumerate subscription status:

```http
HTTP 202
{ "message": "If confirmation is needed, check your email for the next step." }
```

Confirmation-email submission failure returns the shared structured error envelope:

```http
HTTP 503
{ "error": { "code": "CONFIRMATION_EMAIL_UNAVAILABLE", "message": "Email confirmation is temporarily unavailable. Please try again.", "fields": null } }
```

An already-confirmed address performs no mutation and submits no email. Signup never auto-confirms, never creates unsubscribe credentials, never resets delivery history, and never dispatches recent-request alerts. Re-signup preserves `bounced`, `dailyCount`, `lastSentAt`, unsubscribe-token state, unsubscribe timestamp, and existing delivery history.

### 9.2 Confirmation tokens and pending state

The raw confirmation token is a cryptographically random 32-byte base64url value that exists only for the emailed link. Only its SHA-256 digest is persisted, in the private `confirmationTokenDigest`. `confirmationExpiresAt` is backend time plus exactly 24 hours. `confirmationTokenDigest`, `confirmationExpiresAt`, `confirmationSendAttemptId`, and `confirmationSendAttemptAt` are private (`select: false`) and never public.

The confirmation link is built from trusted configured `BASE_URL`, never from a request `Host`, `X-Forwarded-Host`, or request protocol, because the link carries a bearer token.

A brand-new address creates one Subscriber. Unexpired pending, expired pending, and unsubscribed addresses rotate the existing document, preserving its `_id`. Rotation issues a new token, digest, and expiry, so any previous confirmation link becomes invalid.

### 9.3 Concurrency, send ownership, and compensation

Creation relies on the unique normalized-email index; a duplicate-key loss re-reads state and returns the same 202. Existing-lifecycle rotation is one exact conditional mutation that matches every prior lifecycle field, including field presence. A losing concurrent attempt re-reads state and never submits a token whose digest is not the persisted one.

One attempt owns provider submission through `confirmationSendAttemptId` under a two-minute lease. Ownership with no timestamp, or a timestamp at or before the lease cutoff, is stale and takeover-eligible, so a process that dies mid-flight cannot make an address permanently unconfirmable. The confirmation provider request carries a real 30-second abort deadline — strictly shorter than the lease — so an unanswered provider releases its lifecycle within the lease.

Successful submission leaves the Subscriber `pending` and clears the owner conditionally on `_id`, digest, and attempt ID. Submission failure conditionally deletes only the record created by that attempt, or restores the exact previous field values and field-presence semantics of the record it rotated; both compensations match `_id`, digest, and attempt ID, so stale cleanup cannot damage a newer lifecycle.

If an owner-clear, deletion, or rollback operation itself rejects, its database outcome is unknown rather than known-failed, and is logged as unverified with only the subscriber ID, attempt ID, and a sanitized reason — never a raw token or confirmation URL. API behavior is unchanged by that ambiguity: 202 after provider success even when the owner clear is unacknowledged, and the exact 503 after provider failure even when compensation is unacknowledged. The bounded lease is what makes an unresolved owner recoverable by a later signup.

### 9.4 Confirmation redemption primitive

An internal primitive redeems a raw confirmation token against backend time:

```text
valid pending confirmation token
→ one conditional atomic mutation
→ confirmed Subscriber
```

Eligibility requires all three of `status: "pending"`, a matching SHA-256 `confirmationTokenDigest`, and `confirmationExpiresAt` strictly after backend now. The transition is one conditional atomic Mongo mutation, not read-check-save, so two concurrent redemptions cannot both observe `pending` and both write.

Confirmation issues no unsubscribe credential and never touches `unsubscribeCredentialVersion`: raising that version would invalidate every unsubscribe link the address has already been sent.

A successful transition sets `status` to `confirmed`; clears the active `confirmationTokenDigest` and `confirmationExpiresAt`; clears the confirmation send-attempt ownership and lease fields; clears the legacy raw `confirmToken` and `unsubToken`; sets `bounced` to `false`, `dailyCount` to `0`, and `lastSentAt` to `null`; clears any prior `unsubscribedAt`; and retains a bounded receipt of the used confirmation-token digest until that token's original expiry.

Reopening the same valid confirmation link before its original expiry mutates nothing and yields the internal `alreadyConfirmed` result. After the original expiry the used token no longer needs to be recognised, and an unsubscribe clears the receipt outright (section 9.7): the link is then simply `invalid`, because the address it would have vouched for is no longer confirmed.

The primitive distinguishes four internal outcomes — `confirmed`, `alreadyConfirmed`, `expired`, and `invalid`. Expired and invalid tokens mutate no state. These remain internal results rather than a response shape; section 9.5 defines the only surface that currently maps them, and how much of each outcome a browser is allowed to learn.

Malformed tokens are rejected on shape alone, before any hashing or database work.

Concurrency and interaction with signup send ownership:

- Simultaneous confirmation attempts produce exactly one lifecycle mutation; the losing valid attempt receives `alreadyConfirmed` rather than an invalid-token answer.
- Confirmation may succeed while a signup send lease is live or orphaned. Success clears that ownership, because the lifecycle the lease guarded no longer exists.
- A late signup deletion, rollback, timeout, compensation, or owner-clear filter cannot undo a confirmed Subscriber: every such filter still requires the confirmation digest and attempt ID that confirmation cleared.

Confirmation-token generation, shape validation, and SHA-256 digest calculation are shared with signup through `src/subscriptionTokens.ts`; signup behaviour is otherwise unchanged.

### 9.5 Browser confirmation routes

The emailed link is redeemed through two public routes in `src/confirmSubscriptionRoute.ts`:

```text
GET  /api/subscribe/confirm?token=...
POST /api/subscribe/confirm
```

Every response from both routes is HTML, including every refusal. A person reading email is the only intended caller, so the shared structured JSON error envelope is deliberately not used here.

#### GET: safe by construction

Opening the link never confirms anything. Inbox scanners, link previewers, and prefetchers fetch links without a person acting, so the mutation belongs to the explicit button press instead.

The public-action pause is checked before any token work. A paused GET returns an HTML `503` page carrying no form. A missing or malformed token returns HTML `400`. A well-formed token returns HTML `200` with a no-JavaScript confirmation form.

GET performs token-shape validation only. It does not hash the token, query Subscriber, call the confirmation primitive, or mutate anything. Because it answers from shape alone, the page cannot be used to probe whether a token belongs to a real Subscriber.

GET is not rate-limited.

#### POST: middleware and handler order

```text
confirmation security headers
→ HTML public-action pause guard
→ POST-only confirmation limiter
→ route-local URL-encoded parser
→ confirmation handler
→ sanitized route-local parser-error boundary
```

Both routes are registered in `app.ts` **before** the global JSON and URL-encoded parsers. A global parser runs ahead of route middleware, so a body it rejected would be answered by the global JSON error handler — outside this route's security headers, outside its HTML contract, and logging a parser error that can quote the raw token. Route-local parsing keeps every malformed-body outcome inside the confirmation route.

POST accepts the confirmation token through `application/x-www-form-urlencoded`, the only encoding the accepted form submits. JSON bodies are not parsed for this route; an unparsed body reaches the handler with no usable token and produces the invalid-link HTML response. Malformed or oversized URL-encoded input is handled by the route-local parser-error boundary and never reaches the global JSON error handler.

The public-action pause runs before rate-limit capacity consumption, route-local parsing, validation, hashing, lookup, and mutation, so a paused confirmation performs no lifecycle work and spends no throttle capacity. The confirmation limiter is IP-based, POST-only, and allows 5 requests per 60 seconds in its own bucket, so confirming cannot spend the signup allowance.

#### POST outcome mapping

| Condition | Browser response |
| --- | --- |
| `confirmed` | HTML `200` |
| `alreadyConfirmed` | HTML `200` |
| `expired` | HTML `410` |
| `invalid` | HTML `400` |
| Rate-limited | HTML `429` |
| Public actions paused | HTML `503` |
| Unexpected internal failure | Sanitized HTML `500` |

The primitive returns no credential for the route to discard. Its `subscriberId` is internal detail and is never rendered, logged, or exposed in any form.

#### Browser security and privacy

Every confirmation HTML response — including the pause, invalid, expired, rate-limit, and error pages — carries route-owned headers:

- `Cache-Control: no-store`
- `Referrer-Policy: no-referrer`
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- a route Content-Security-Policy enforcing at least `default-src 'none'`, `script-src 'none'`, `style-src 'self' 'unsafe-inline'`, `form-action 'self'`, `base-uri 'none'`, and `frame-ancestors 'none'`.

The pages load no JavaScript and no third-party resources. The form submits to the same origin, and the hidden token is HTML-escaped. Result pages never repeat the token, and no page displays the subscriber email or internal lifecycle detail.

Caught request, parser, and database details are never logged, because each can carry the body and therefore the raw token. The only permitted unexpected-failure log is a fixed sanitized event.

#### Accepted browser behavior

- The initial page states explicitly that opening the link alone does not confirm alerts; the user must select `Confirm alerts`.
- Success and already-confirmed pages state that no further action is needed.
- Expired and invalid pages offer the same privacy-preserving link back to `/` to sign up again, so neither page can be read as evidence about a Subscriber.
- Paused and unexpected-error pages read identically and tell the user to reopen the link later; the distinction survives only in the status code.
- The rate-limit page tells the user to wait about a minute and reopen the confirmation link.
- Page titles identify CommonPlate.

#### Activation boundary

Signup, confirmation activation, and alert delivery all remain publicly paused. The existence of these routes does not mean the alert flow is activated: `pauseConfirmationPage` refuses both halves while `PUBLIC_ACTIONS_PAUSED` holds.

No iOS, APNs, or push behavior was added with these routes.

The page shell these routes render — document skeleton, styles, title convention, `text/html` send helper, and the header middleware above — lives in `src/publicPage.ts` and is shared with the unsubscribe routes (section 9.7), so both emailed-link surfaces answer with the same structure and the same headers.

### 9.6 Unsubscribe credentials and emailed links

An unsubscribe credential is signed on demand and never stored:

```text
<subscriberId>.<credentialVersion>.<signature>
```

The signature is HMAC-SHA-256 over the canonical, domain-separated input `commonplate:unsubscribe:v1:<subscriberId>:<credentialVersion>`, encoded base64url. The key is the dedicated `UNSUBSCRIBE_SIGNING_SECRET`, at least 32 UTF-8 bytes; no confirmation digest, claim-token secret, or other credential's raw value is reused, so one credential's compromise cannot forge another.

Because the credential is derived from identity the document already carries, an authentic link does not expire and stays valid across unsubscribe, re-signup, and reconfirmation. `unsubscribeCredentialVersion` is the sole revocation lever: it is a bounded positive integer (1 to 1,000,000) defaulting to `1`, and raising it invalidates every credential signed at the previous version. Signup, re-signup, and confirmation all leave it untouched, and a document that *physically lacks* the field — one written before it existed — is treated as version `1`. That absence is the only legacy case: a persisted `null` is malformed state no schema path produces, and it is rejected rather than resolved to `1`. No migration rewrites existing documents.

Verification parses strictly — three segments, a 24-character lowercase hexadecimal subscriber id, a bounded version with no leading zeros or sign, and a canonical 43-character base64url signature — and compares signatures with a constant-time comparison. Malformed input yields no result rather than an exception. Neither signing nor verification performs any database work; comparing a verified version against the stored one belongs to the unsubscribe redemption route (section 9.7).

Real-time helper alerts and hourly digests build the link while composing the message, with no database read or write:

```text
<BASE_URL>/unsubscribe?credential=<URL-encoded credential>
```

`BASE_URL` is the single public base-URL setting, resolved in one place (`src/publicBaseUrl.ts`) and never taken from a request `Host`, `X-Forwarded-Host`, or forwarded protocol. Both send paths remain behind `PUBLIC_ACTIONS_PAUSED`, so no such link has been delivered.

#### Activation prerequisite

`UNSUBSCRIBE_SIGNING_SECRET` is validated at startup, from the same `app.ts` environment-validation block as `CLAIM_TOKEN_HMAC_SECRET` and through one reader (`src/unsubscribeCredential.ts`). The check runs before the Express app is constructed, before any route is registered, before the MongoDB connection, and before the process listens, so an unpaused process cannot expose a public-action surface, accept a signup or confirmation, send an alert, deliver a digest, or serve an unsubscribe link without being able to sign one.

The requirement is conditional on the pause, which is what makes those surfaces reachable at all:

| Public actions | `UNSUBSCRIBE_SIGNING_SECRET` | Startup |
| --- | --- | --- |
| Paused | Absent | Starts; paused routes and delivery stay unavailable |
| Paused | Valid | Starts; functionality stays paused |
| Unpaused | Absent | Refused |
| Unpaused | Empty | Refused |
| Unpaused | Fewer than 32 UTF-8 bytes | Refused |
| Unpaused | 32 UTF-8 bytes or more | Starts |

While paused the variable is not read at all, so a paused local or deployed process is never asked for a secret no paused path can use. A refusal logs a message naming only the variable — never its value — and exits non-zero. No other secret is substituted for a missing one, and the validated secret is discarded rather than returned or cached: every signing and verification path still reads it where it is needed.

### 9.7 Unsubscribe redemption routes

`GET /unsubscribe?credential=<credential>` and `POST /unsubscribe` are the browser surface for the emailed link. Both answer in HTML behind the shared emailed-link security headers (section 9.5) and an HTML pause guard.

#### Safe by construction

Opening the link never unsubscribes anyone. Mail scanners, previewers, and prefetchers fetch inbox links with nobody acting, so the GET only renders a form and performs no mutation on any path, including a repeated open. The mutation belongs to the explicit POST.

Unlike the confirmation GET, this one does read a Subscriber, because an unsubscribe credential is unforgeable: a `200` is returned only when the credential verifies against an existing Subscriber whose stored version matches. What the page never discloses is the state it found. Pending, confirmed, and already-unsubscribed subscribers receive the identical page, and the redemption primitive reports only whether the link is usable, so no page can carry a status it was never told.

Malformed, tampered, unknown-Subscriber, and version-mismatched links all receive one generic `400` page carrying no form. A `503` pause page and a `500` unexpected-error page — including the case where `UNSUBSCRIBE_SIGNING_SECRET` is missing — read identically to each other and carry no form either.

#### Middleware and handler order

The pause guard runs before the rate limiter, credential parsing, the signing-secret read, the Subscriber lookup, and any mutation, so a paused request performs no lifecycle work, touches no configuration secret, and consumes no throttle capacity. The POST then runs its own 5-per-60-second limiter, route-local URL-encoded body parsing, the handler, and a parser-error boundary that answers a rejected body with the invalid-link page. Both verbs are registered ahead of the global body parsers for the same reason the confirmation POST is. The GET is not rate limited: mail clients prefetch, and it mutates nothing.

#### The unsubscribe mutation

A valid POST performs one conditional atomic update:

- the transition is accepted from `pending`, `confirmed`, and `unsubscribed` alike, so a repeated submission is a no-op and every prior status yields the same generic `200` page;
- `_id`, `email`, `unsubscribeCredentialVersion`, `dailyCount`, `lastSentAt`, `bounced`, and SendLog history are preserved — unsubscribing is a status change, not a deletion, a reset, or a revocation, and the link just used must keep working;
- every confirmation credential the row holds is cleared in the same update — the active `confirmationTokenDigest` and `confirmationExpiresAt`, the confirmation send-attempt ownership and lease fields, the legacy raw `confirmToken` and `unsubToken`, and the bounded confirmation receipt `lastConfirmedTokenDigest` and `lastConfirmedTokenExpiresAt`. A pending row's outstanding link cannot later activate an address that asked to stop, and a confirmed row's original link can no longer be answered `alreadyConfirmed`, which stopped being true the moment the update ran; it becomes `invalid` like any unrecognised token, and cannot return the row to `confirmed`. The cleared set is derived from the confirmation clear list and the receipt definition rather than restated, minus `unsubscribedAt`;
- `unsubscribedAt` is written with `$ifNull`, so the first unsubscribe of the current lifecycle stands. Confirmation clears the field, so a reconfirmed address that unsubscribes again records the new lifecycle's time;
- no email is sent, and no credential is rotated or issued.

The resulting `unsubscribed` status is what makes the subscriber ineligible: both the real-time alert query and the hourly digest query select on `status: "confirmed"`, and neither selection rule was changed.

Clearing the confirmation credentials ends the current lifecycle only. Signing up again rotates a fresh pending confirmation credential onto the same document, `_id`, and `unsubscribeCredentialVersion`, and reconfirming it works normally; the unsubscribe credential emailed before any of that still opens the page and still unsubscribes afterwards.

#### Version comparison and the rotation race

After cryptographic verification, the persisted version is normalized through `resolveUnsubscribeCredentialVersion` before it is compared, so a document that physically lacks the field is version 1 and accepts a version-1 credential; a direct comparison would reject every legacy row. A stored version of 2 rejects a version-1 credential and accepts a version-2 one.

Physical absence is the only fallback. A persisted `null` is not a legacy row — nothing in the schema, its default, or any write path produces one — so it is treated like any other value outside the accepted range: the link is unusable at both verbs, the row is not mutated, and the malformed value is left exactly as found rather than repaired by a redemption request.

The update filter repeats the exact persisted version state that was validated: `$exists: false` when the row physically lacked the field, and the exact stored integer otherwise. It is never `{unsubscribeCredentialVersion: null}`, which would match a physical null and an absent field alike and so could state neither condition. A rotation that lands between the read and the update therefore loses the update, and that miss — like a row that disappeared — is reported as the same generic invalid result, disclosing neither.

#### Privacy and page security

No page renders a subscriber's address, status, counters, history, or internal id. The credential exists only in the incoming link and the hidden form field, is escaped where it is rendered, and is never logged; neither is the raw query, the body, nor a parser or provider error. No page loads an external script, stylesheet, image, font, or tracking resource, and no page carries JavaScript, a CAPTCHA, a cookie, or a redirect. Credentials have no expiry.

Redemption existing is not activation: `pauseUnsubscribePage` refuses both verbs while `PUBLIC_ACTIONS_PAUSED` holds, and signup, confirmation, real-time alerts, and the digest all remain paused.

## 10. Public-actions pause and scheduled jobs

`PUBLIC_ACTIONS_PAUSED` fails closed unless explicitly set to `false` or `0`. It blocks public request creation, subscription signup, both halves of the browser confirmation flow (section 9.5), both halves of the unsubscribe flow (section 9.7), claim and claim-extension mutations, real-time helper alerts, and hourly subscriber digests. The API mutations answer a paused request in JSON through `pausePublicAction`; the confirmation and unsubscribe routes answer in HTML through `pauseConfirmationPage` and `pauseUnsubscribePage`. It does not block fulfillment: a valid active claim token is already the authorization to record an order, and blocking that path could strand a helper who has already placed one.

The same variable is the activation switch for the unsubscribe signing secret: unpausing is what makes that secret a startup requirement (section 9.6).

`CRON_ENABLED=true` controls only the hourly expired-request cleanup backup to TTL deletion. The hourly digest, daily confirmed-subscriber `dailyCount` reset, and ten-minute SendLog failure monitor are registered independently of `CRON_ENABLED`; the digest additionally exits when public actions are paused.

## 11. Durable deferrals that constrain current behavior

- Cleanup of expired pending Subscribers; they stay notification-ineligible, so the current consequence is storage growth.
- Physical cleanup of expired confirmation receipts (`lastConfirmedTokenDigest`, `lastConfirmedTokenExpiresAt`) on rows that stay confirmed. Unsubscribing now clears the receipt outright, and the expiry comparison already prevents recognition after the original window, so the remaining consequence is stored data, not behaviour.
- Provider timeouts outside the confirmation email, and durable email-outcome persistence. Only `sendSubscriptionConfirmationEmail` currently carries an abort deadline.
- Browser rendering of the shared structured error envelope on the signup form, which must land before signup is unpaused.
- Create idempotency and reconciliation.
- Paid-but-unrecorded recovery beyond the in-memory, one-resend fulfillment safeguard.
- Physical-device and release backend configuration.
- Full privacy and accessibility review.
