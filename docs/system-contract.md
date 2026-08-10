# CommonPlate system contract

## 1. Scope and release boundary

CommonPlate currently supports one journey: **create → list → claim → fulfill → placed**. The iOS client and backend are for internal simulator/testing use; they are not ready for student distribution or TestFlight.

Current scope excludes authentication, chat, maps, payments, cancellation, pickup confirmation, and any no-show lifecycle. The legacy web fulfillment page remains disabled and cannot place an order.

## 2. Request lifecycle and availability

| Persisted state | Meaning | Effective availability |
| --- | --- | --- |
| `open` | Awaiting a helper | Available only before `expiresAt` and with at least five full minutes remaining to claim. |
| `claimed` | Reserved for one helper | Not publicly available while its active claim has not expired; it may become claimable again after claim expiry if the request itself remains eligible. |
| `placed` | Placement was recorded | Never available. |

Backend time is authoritative for availability, the five-minute claim threshold, and claim deadlines. Public list membership is effective availability, not simply the stored `status`; listed records are projected as `open`. `expiresAt` ends availability. `deleteAt` controls TTL retention: it initially matches `expiresAt`, while placement retains the request for seven days from `placedAt` by moving `deleteAt` without changing `expiresAt`.

### 2.1 NYU campus time and request availability windows

`America/New_York` is the canonical request timezone, named by IANA identifier so every conversion is DST-correct on its own. Backend time is authoritative for all request timing and availability; iOS presents and submits Later timing in NYU campus time even when the device is set to a different timezone (verified on a physical device configured to non-Eastern Phoenix time, with no source-text-only reliance).

Two backend-owned absolute instants define a request's window: `visibleFrom` (when helpers begin seeing it) and `expiresAt` (`visibleFrom` plus a three-hour duration). An ASAP request becomes visible from the backend creation instant; a Later request becomes visible from its accepted scheduled start. Both instants are written explicitly at creation and are never accepted from a client.

A Later start earlier than the creation instant is refused (`400 INVALID_REQUEST`) ahead of the daily-limit read, the write, the requester confirmation email, and helper notification, so a refused create has no side effect; the requester's Later selection is never silently converted to ASAP.

A future Later request is not publicly visible before its `visibleFrom`: the public list, helper-alert selection, and the claim mutation all apply the same visibility rule, and direct public detail (`GET /api/request/:id`) reveals no request content and answers `409 REQUEST_NOT_YET_AVAILABLE` (`"This request is not available to help with yet."`) rather than `404`, so "come back later" stays distinct from "no such request." Claiming before `visibleFrom` answers the same `409 REQUEST_NOT_YET_AVAILABLE`. Legacy rows persisted before `visibleFrom` existed carry no value for it and are treated as visible from creation, so they remain unaffected.

Presentation: the three-hour availability rule is explained once, where the requester chooses timing; downstream request/helper surfaces (lists, detail, requester and helper email, digest email, push) do not repeat it. The shared backend timing label for an ASAP request is `ASAP`; Later surfaces use the concrete backend-derived start/end window text instead of restating the rule.

## 3. Public and private data boundaries

The public request projection is allowlisted: `id`, vendor, food, pickup-window text and bounds, persisted/projection status, `createdAt`, and `expiresAt`. It is used for list and detail responses.

| Private data | Boundary |
| --- | --- |
| Requester email and pickup name | Never public. Pickup name is returned only in the successful claimant's claim response. |
| Claim token, token digest, claim deadline, claim timestamps | Never public. The raw token is claimant authorization; the backend persists only its digest. |
| Confirmation token, its digest, expiry, and send-ownership fields | Never public. The raw confirmation token exists only in the emailed link; the backend persists only its SHA-256 digest. |
| Used-confirmation-token receipt (`lastConfirmedTokenDigest`, `lastConfirmedTokenExpiresAt`) | Never public. |
| Unsubscribe signing secret (`UNSUBSCRIBE_SIGNING_SECRET`) | Never public and never emailed. It is the only thing that makes an unsubscribe link authentic; nothing derived from it is stored. |
| Participant verification codes, participant authority credentials, and participant identifiers | Never public. A raw code is emailed only to the address being verified; the backend stores no raw code, and a stored device authority credential is private to that installation. |
| `deleteAt`, requester-notification state, fulfillment/contact fields, and other internal fields | Never public. |
| Helper email | May be sent to the requester in the committed-placement email for coordination. |

### 3.1 Verified participant identity

The NYU allowlist (`nyu.edu` and `stern.nyu.edu`) establishes only that an address is eligible to become a participant; it does not establish mailbox ownership, enrollment, a human identity, or equivalence between aliases, vanity addresses, or `+tag` variants. Mailbox control is established only when that exact normalized allowed address successfully completes the participant email-code verification flow. That resulting normalized address is the participant principal.

Participant identity is distinct from Subscriber identity, Push Installation identity, claim-token authorization, and unsubscribe credentials. A Participant is backend authority for an acting requester or helper; an Installation is only device-local notification-routing metadata, and a Subscriber is only the email-alert lifecycle. Neither substitutes for participant authority.

Participant actions require usable backend-verifiable participant authority. Request creation derives the requester principal from that authority and binds it to the Request; a caller-supplied legacy `email` field, when present, must match the verified principal and is never the source of the persisted requester identity. The atomic claim grant likewise binds the verified helper principal. These bindings remain private.

Fulfillment uses the helper principal bound to the claim, never a caller-entered helper email. A valid unexpired claim created before this binding existed remains narrowly fulfillable through its existing claim-token authorization only when `helperParticipantId` is physically absent; this compatibility path does not authorize a post-identity claim without participant binding.

After successful verification, an installation is designed to retain its private authority across ordinary launches while it remains usable; backend rejection, revocation, missing, or malformed stored authority requires verification again. A reinstall or new device has no automatic recovery and requires verification again. Change Email leaves the existing authority active until the replacement address has successfully verified, then applies the replacement only to future actions; existing request and claim bindings remain unchanged. These device-lifecycle properties are accepted runtime behavior, with physical Keychain/device proof still recorded as an environmental limitation in `docs/testing.md`.

On iOS, selecting Request Food requires usable verified participant identity before the request form is initially exposed. If no usable identity exists, iOS presents the existing participant-verification flow first; successful verification continues directly into Request Food, and an already-verified or restored identity enters Request Food directly, in both cases without another editable participant-email field. Request submission remains bound to this verified participant authority. If that authority is lost after the form was already legitimately admitted, the form and its in-progress draft are preserved rather than discarded, and recovery uses the same in-form reverification continuation Request Food already provides at submission; authority loss alone does not return the requester to the pre-form verification screen. Change Email continues to require reverification, per the device-lifecycle properties above.

Verified participant identity is app-level CommonPlate identity, not Request Food content. Home presents the currently verified participant identity (masked) or, when no identity exists yet, the standing verification requirement, and provides the Change Email entry from that same app-level surface; this is the sole identity-presentation source. Change Email preserves the current verified authority until the replacement address successfully verifies, consistent with the device-lifecycle properties above.

Participant verification and Change Email present their existing lifecycle action-first: NYU email → Send code → code entry → Verify, with the field and its action leading and supporting eligibility/purpose/replacement/revoked explanation visually secondary beneath. No verification-code, resend, expiry, credential, participant-principal, persistence, or authorization behavior is changed by this presentation.

Request Food contains no Contact section and no verified-participant-email row: it does not display the verified participant email and does not ask the requester to enter or reconfirm a participant email. It still submits using the accepted verified participant authority established before the form was reached (section 3.1 above). The requester email remains private participant identity and is not presented as information shared with helpers.

The legacy website has no participant-verification UX. Until the separate Week 6 work exists, website request creation is deliberately non-actionable and cannot bypass participant authority. This does not define later website verification behavior.

## 4. Claim contract

Claiming requires usable participant authority and is an atomic conditional mutation, so one eligible attempt wins and binds that verified helper principal. The winning response returns the raw token once; iOS keeps it only in private in-memory store state, while the backend keeps an HMAC digest. One live iOS app process holds at most one active claim. Navigating back does not release it; there is no release operation.

A claim lasts at most 15 minutes and is capped by `expiresAt`. Its holder may receive one five-minute extension only when the full extension fits before request expiry. A readable `INTERNAL_FAILURE` from claim is ambiguous: iOS does not automatically retry it and never permits ordering without a confirmed active claim and its raw token.

## 5. Fulfillment contract

Fulfillment requires a valid, unexpired active claim token. It reuses the verified helper principal atomically bound at claim grant, rather than trusting any helper email supplied by the caller. In one MongoDB transaction, the backend conditionally transitions the request from `claimed` to `placed` and creates its Fulfillment ledger record. A unique Fulfillment `requestId` index independently protects one fulfillment per request. The sole compatibility exception is an active pre-W3-I1 claim whose helper binding field is absent, as defined in section 3.1.

`orderNumber` is a digits-only string, not a number; leading zeroes are preserved. The requester email is submitted only after placement commits. Email failure does not undo placement, and failure to clean up the database session cannot replace the committed placement result.

Fulfillment `INTERNAL_FAILURE` is ambiguous. iOS performs one read-only request-status check, then permits at most one exact-payload CommonPlate-only resend using the retained in-memory token and submission. It never instructs the helper to place another external order.

## 6. Request-creation contract

Creation requires usable participant authority as well as strict backend validation for canonical and legacy request shapes, vendor, email when supplied, required text, scheduling bounds, and a still-usable scheduled end time. The backend derives and persists the requester identity from that authority. Where iOS can know an error locally, it validates before submission (including required fields, email, and scheduling/form constraints).

CommonPlate has one canonical supported-vendor catalog, `shared/vendors.json`, currently the accepted 11 dining locations. Backend request creation is authoritative over it. Both supported create payload shapes require `vendor` to match a catalog entry exactly, after the same trimming already applied to that field; case variants and other near-matches are refused rather than silently canonicalized. Structural shape validation still runs first, and vendor validation runs immediately after it, before the email allowlist below. A vendor that is present and non-blank but not in the catalog returns HTTP 400 with code `INVALID_VENDOR` and message `Choose a supported CommonPlate dining location.` Enforcement applies only to new request creation: existing persisted requests are neither migrated nor rejected on read. iOS consumes the same shared catalog for its vendor picker; the website form remains free-text, with backend enforcement still applying to it.

The requester principal must be an allowed NYU address. Both alert signup and food-request creation use the same `src/allowedEmailDomains.ts` helper with the same exact allowlist, normalization, and refusal of lookalikes and unlisted subdomains described in section 9.1. The allowlist establishes eligibility only; participant email-code verification is what proves control of the mailbox. Existing requests created on other domains are unaffected — the allowlist gates creation only.

The participant gate runs before payload validation, so an unverified caller neither creates a request nor learns whether its payload would otherwise be accepted. The legacy `email` field is optional because the backend already has the verified requester principal; if supplied, it must exactly equal that normalized principal or the request is refused with `403 PARTICIPANT_PRINCIPAL_MISMATCH`. A missing `email` is valid, while a blank or wrongly typed supplied `email` remains a structural `400 INVALID_REQUEST` failure alongside other malformed fields. `POST /api/request` keeps its two-key `{error: {code, message}}` envelope.

Refusal precedes the daily abuse-control count, the write, the requester confirmation email, and helper-alert notification. The iOS Request Food form carries no editable email field and supplies no legacy `email` at all; it relies entirely on the verified participant authority established before the form is reached (section 3.1). A backend `INVALID_EMAIL` on this path would indicate a stale or mismatched authority rather than free-form input the form itself validates. The legacy website is instead temporarily non-actionable because it cannot establish participant authority (section 3.1); its email input placeholder remains `abc123@nyu.edu`.

Creation has no operation identity. If iOS cannot confirm a create outcome, it blocks further creation for the lifetime of that `RequestStore`/app process to avoid duplicates. Durable reconciliation and backend idempotency do not exist. `REQUEST_CREATION_FAILED` therefore remains a Week 3 reconciliation concern rather than proof that no request was created.

### 6.1 Request → installation association

An iOS request-creation payload may carry the installation's existing `installationCredential`. A structurally malformed supplied credential is a structural failure: HTTP 400 `INVALID_REQUEST`, the same envelope as any other malformed payload. A structurally valid credential is used to establish or resolve installation identity through the existing installation-credential mechanism; only an opaque internal association is persisted on the Request, never the raw credential. This association is notification-routing metadata only — it is not authentication, not NYU participant identity, and not proof of a person. Reinstall creates a new installation and does not relink requests created by a prior installation; no email, APNs token, or other heuristic re-links them either. Request creation never depends on Apple notification permission or push-enabled state.

Association is best-effort against unexpected backend persistence failure: if establishing or persisting the association unexpectedly fails, request creation still proceeds and the request persists without an installation association. `installationId` is therefore optional persisted metadata; a downstream flow may not assume every iOS-created Request carries one, and its presence or absence carries no authentication or identity meaning.

## 7. Daily request abuse control

CommonPlate attempts to limit each email to three requests per NYU/New York calendar day (`startOfCampusDay`, not the requesting process's local timezone). The backend counts before creating, serially in the handler; this is best-effort abuse control, not an atomic quota transaction. A failed count read fails closed. Concurrent create requests can exceed the limit. Atomic enforcement is deferred to Week 5 if usage requires it.

Ordinary Request Food presentation does not continuously advertise this limit. Only an actual `REQUEST_LIMIT_REACHED` refusal tells the requester to try again after midnight Eastern/New York time.

## 8. Email and notification truth

Provider acceptance means only that CommonPlate submitted an email to the provider. It does not prove delivery, reading, or pickup; no email result is described as verified delivery.

| Record/state | Owner and meaning |
| --- | --- |
| `Request.notificationStatus` (`pending`, `sent`, `failed`) | Requester placement-email submission state only, recorded after committed placement. |
| `SendLog` (`sent`, `fail`) | Helper-alert and digest send ledger / duplicate-send guard. It is not requester placement-email state. |

### 8.1 Real-time helper-alert selection and dispatch

For each new eligible request, every `confirmed`, non-bounced Subscriber is considered for a real-time email alert — not a bounded or round-robin-selected subset. There is no 1-hour per-subscriber cooldown, no per-subscriber daily send cap, and no ordinary round-robin selection gating which confirmed subscribers receive an alert. A subscriber enrolled in both email and push may receive both for the same request; the two channels are independent.

`SendLog`'s unique `(requestId, subscriberId)` claim-before-send index still provides per-pair duplicate-send prevention, and one subscriber's provider failure does not stop the remaining eligible subscribers from being attempted. A successful real-time send still sets `lastSentAt` and increments `dailyCount` on the Subscriber, because the hourly digest still reads both fields for its own eligibility; digest behavior is unchanged by real-time selection. Provider acceptance for a real-time alert carries the same meaning as elsewhere in this section: submission only, never delivery, reading, or pickup.

CommonPlate has no internal provider-wide send-volume ceiling. A provider quota or rate-limit refusal surfaces through the existing per-subscriber `SendLog` `fail` outcome and per-subscriber failure isolation above; it is not pre-empted by silently skipping subscribers. Introducing an application-level ceiling is deferred until Week 5 production email configuration, and only if actual provider rate or quota evidence requires one.

`POST /api/request` never waits on real-time helper-alert fan-out. The `201` response is built and sent from the persisted document first; helper-alert dispatch is started only afterward, detached, through a total entry point that cannot throw and cannot leave an unhandled promise rejection. A slow, large, or failing fan-out cannot delay the requester's response, cannot turn a successful creation into `REQUEST_CREATION_FAILED`, and cannot produce a second response on a request whose headers are already sent. The requester confirmation email remains awaited before the response, unchanged.

### 8.2 Requester-fulfillment push

After a request's placement has durably committed, CommonPlate may best-effort submit a requester-fulfillment push to the originating associated installation only (the Request's stored association from section 6.1). If that installation is missing, disabled, invalidated, or lacks a usable APNs registration, no push is sent; there is no fallback or heuristic recipient. Requester-fulfillment push is independent of placement success and of the existing fulfillment email — neither affects the other. At most one requester-fulfillment provider submission is claimed for the same request + installation, matching the existing dedup discipline used for helper push. Provider acceptance means submission only, never delivery, display, opening, or reading.

Notification title: `"Your order was placed"`. Body: `"A helper placed the order for your request."` The payload carries only privacy-safe routing data; it never carries pickup name, requester or helper email, order number, claim token or claim state, the installation credential, or any other private fulfillment field. The requester-fulfillment notification intent and the helper new-request notification intent remain distinct; a requester notification tap opens Home and presents a one-time "Your order was placed." notice.

A physical device has received a real requester-fulfillment push while running, tapped it to open Home, and seen the one-time notice. That device result covers submission-to-tap-to-notice on the observed device; it does not extend provider acceptance beyond submission (see the section header) and does not establish Release/Archive/TestFlight signing or environment behavior, which remains a separate gate (section 11).

### 8.3 Helper new-request push tap routing

A helper new-request notification tap carries a request id as routing context only. Only current backend truth from `GET /api/request/:id`, read at the moment of the tap, decides where the tap goes — the payload itself never establishes availability.

- If the backend confirms the request is currently open, the tap opens that request's detail flow.
- If the backend confirms the request is no longer available (a non-open status, or an authoritative not-found), the tap shows a "no longer available" notice and returns to the active-requests list.
- If current backend truth cannot be established (a transport failure, timeout, unexpected server response, or a malformed response), the tap shows a distinct "temporarily unavailable" notice rather than claiming the request is gone, and also returns to the active-requests list. Neither notice discloses an internal error code or any requester-private detail.

Each valid tap is routed exactly once, in the order it was made. A routing attempt that does not reach one of the outcomes above — including one interrupted by app startup ordering, such as a cold launch from a terminated state — does not consume the tap: the tap remains available to a later attempt rather than being silently lost. When more than one attempt is in flight for the same tap, at most one of them may apply a navigation or recovery outcome, and an older tap can never overwrite or retire a newer one.

A physical device has received a real helper new-request push while CommonPlate was terminated, tapped it to launch the app, and been routed to that request's detail flow rather than to Home — including the cold-launch case described above. Background-state tap routing to the specific request has also been physically observed. These device results do not establish Release/Archive/TestFlight signing or environment behavior, which remains a separate gate (section 11).

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

Alert signup additionally accepts only NYU addresses. The exact allowlist is `nyu.edu` and `stern.nyu.edu`, compared against the whole normalized domain after the final `@` — never by suffix or substring, so `fake-nyu.edu`, `nyu.edu.example.com`, and unlisted subdomains such as `law.nyu.edu` are all refused. Plus-addressing on an allowed domain is accepted. A non-allowlisted address is part of the same strict schema and so is refused with the identical HTTP 400 `INVALID_EMAIL` envelope, before any Subscriber lookup or mutation; its message is `Enter an NYU email address ending in @nyu.edu or @stern.nyu.edu.` The allowlist gates signup only: it never affects confirmation or unsubscribe, and existing Subscriber rows on other domains keep their lifecycle. `src/allowedEmailDomains.ts` is the single implementation, shared with food-request creation (section 6).

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

iOS remembers one thing about signup across app launches, in `UserDefaults` under a single key: the normalized address it last submitted and the device time at which the generic accepted response arrived. That record is presentation history — this installation submitted this address and saw the generic response — and never subscription truth. Because the 202 is identical for a new, pending, confirmed, and unsubscribed address, the record does not establish that a Subscriber exists, that the address is pending, confirmed, or still subscribed, that a confirmation email was submitted or delivered, that alerts are active, or that the person still controls the address; nothing in the app is named or read as subscription status, and no client may treat local state as any. Restoring it only re-presents the existing `Check your email` copy, which claims none of those things. It is written only by a generic accepted response, replaced only by a later one, and removed only by `Use a different email` — which sends nothing and unsubscribes nothing — or by the record itself being unreadable, carrying no valid timestamp, or holding an address the NYU allowlist no longer accepts, each of which is discarded in favor of the editable form. No failure writes or deletes it. Restoring performs no network request: no endpoint reports subscription status, and none is consulted. No confirmation credential, unsubscribe credential, Subscriber ID, or backend status is persisted on the device in any form.

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

- An application-level provider-wide send-volume ceiling for real-time helper-alert email. None exists today; a provider quota or rate-limit refusal is handled through the existing per-subscriber `SendLog` failure path rather than by pre-emptively skipping subscribers. Revisit during Week 5 production email configuration, and only if actual provider rate or quota evidence requires one.
- Cleanup of expired pending Subscribers; they stay notification-ineligible, so the current consequence is storage growth.
- Physical cleanup of expired confirmation receipts (`lastConfirmedTokenDigest`, `lastConfirmedTokenExpiresAt`) on rows that stay confirmed. Unsubscribing now clears the receipt outright, and the expiry comparison already prevents recognition after the original window, so the remaining consequence is stored data, not behaviour.
- Provider timeouts outside the confirmation email, and durable email-outcome persistence. Only `sendSubscriptionConfirmationEmail` currently carries an abort deadline.
- Browser rendering of the shared structured error envelope on the signup form, which must land before signup is unpaused.
- Create idempotency and reconciliation.
- Paid-but-unrecorded recovery beyond the in-memory, one-resend fulfillment safeguard.
- Physical-device and release backend configuration.
- Full privacy and accessibility review.
- Release/Archive/TestFlight `aps-environment` signing and build-configuration alignment. Debug and simulator alignment is proven; a signed Release/Archive/TestFlight build has not been verified. This, along with release backend/APNs reachability and configuration and the remaining activation/unpausing decisions in section 10, gates distribution — see section 1. Physical-device push proof for helper new-request routing (section 8.3) and requester-fulfillment push (section 8.2) has passed on a development device, but that is not evidence about a signed Release build.
