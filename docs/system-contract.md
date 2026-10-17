# CommonPlate system contract

## 1. Scope and release boundary

CommonPlate currently supports one journey: **create → list → claim → fulfill → placed**. The iOS client and backend are for internal simulator/testing use; they are not ready for student distribution or TestFlight.

Current scope excludes authentication, chat, maps, payments, cancellation, pickup confirmation, and any no-show lifecycle. The legacy web fulfillment page remains disabled and cannot place an order.

### 1.1 Accepted visual foundation (W4-F1)

CommonPlate's shared iOS presentation is native-first **Subtle Warmth**: a
restrained warm-neutral page canvas, bounded warm surfaces only where grouping
is genuinely useful, selective CommonPlate purple, and character primarily
through typography, spacing, hierarchy, and restrained color. Standard
shadows/elevation, card-per-fact, pill-everything, and purple-everywhere are
not part of the shared language. Home and participant verification use one
coherent page-level canvas rather than distinct full-page treatments.

Quiet Fraunces is reserved for CommonPlate brand and rare human-facing display
moments, with graceful system fallback; SF/system type remains for functional
and operational UI and all typography remains compatible with Dynamic Type.
Shared actions distinguish strong filled-purple primary actions, soft-purple
secondary actions, plain-purple-text tertiary actions, restrained red
destructive actions, and clearly inactive neutral disabled actions. Controls
remain moderately rounded rectangles that can grow or wrap without clipping.

Verified identity remains a simple native section with the masked address, one
clear verification indication, Change Email, and a visibly destructive Remove
Email action; final Home composition and placement remain requester-slice
owned. Participant verification is a more visibly branded but direct,
scrollable flow with standard Cancel, field-to-primary-action hierarchy, and
quiet inline code-lifetime help, not stacked form/section cards or decorative
containers. These presentation rules do not change identity or verification
runtime semantics.

### 1.2 Accepted first-use, Home, and requester presentation (W4-R1, W4-O1)

CommonPlate has one shared, role-free first-use experience (W4-O1). On a
fresh installation, iOS presents a single scrolling Welcome / How CommonPlate
Works story with no requester/helper chooser, role, account, or authority;
requesting and helping are actions, not permanent roles. The story teaches, in
order: someone posts a meal request; other students can find it on Home (and
can get notified when a new request is posted); someone chooses to help; the
helper places the order using their extra swipes (a text-only `Grubhub`
badge, no logo or brand asset); pickup details come back through CommonPlate,
which notifies the requester; and the requester then picks it up. The
helper-provided pickup timing is described only as approximate ("about
when") and is never represented as provider-confirmed readiness. The story
names no notification channel, claims no guarantee, prompts for no permission,
links to no alert setup, and teaches no in-app helper-message flow or
Screenshot Assistance. `Continue to Home` synchronously records local
completion and enters canonical Home; correctness never waits on a
presentation animation. The earlier slogan, ticket → arrow → bowl motif,
`I need a meal` / `I have extra meal swipes` chooser, and four-step
walkthroughs no longer exist.

Installations that had already completed the prior onboarding are
grandfathered: they are shown neither the new Welcome nor the discovery
treatment below. First-use completion and the helping-discovery record are
local, presentation-only state: neither is identity, a role, or backend
authority, neither is synchronized across devices, sent to the backend, or
required for any action, and no analytics authority is created. Completing
the Welcome records discovery as pending before or together with completion;
completed onboarding with no discovery record means grandfathered (discovery
complete), never pending. iOS exposes one local reset operation that clears
first-use completion first and then the discovery record, so the next first
use shows the Welcome again and an interrupted reset cannot produce
completed-without-record. Nothing in the app invokes it today; it is reserved
for a deletion slice (W4-P2) to invoke after its own accepted deletion
behavior, and onboarding neither detects nor owns deletion.

**First eligible request discovery.** After the Welcome is completed and while
discovery is pending, Home waits for a real eligible request and never
fabricates, reorders, or inserts one. Eligible means an ordinary open card in
the `Needs help` board; the student's own requests, the actively held
`Continue Helping` request, placed-order continuations, and any non-populated
board state (loading, unavailable, empty) are not eligible. The first
eligible request under the existing authoritative Home ordering is selected
(moving to the next eligible request if it disappears), and the treatment is
suppressed while the student holds an active helping reservation, returning
afterward if still pending. The treatment is temporary and presentation-only:
the real card gets lavender emphasis and an overlapping `View request` cue and
floats gently; the whole request card remains the single interaction surface,
no hit target or layout is added, and its accessibility label and trait are
unchanged. With Reduce Motion the same emphasized state is shown statically.
Discovery completes, and is persisted locally, when the student opens any
eligible request card from Home's `Needs help` board while the treatment is
active (touch or accessibility activation); deep-link or notification
navigation does not itself complete it. After completion the treatment does
not recur in ordinary use.

**Settings → How CommonPlate Works.** The existing Settings row opens a
two-destination reference hub rather than replaying onboarding: `Requesting a
meal` and `Helping someone`, each a concise reference path ending in `Return to
Home`, which returns to the canonical Home root. The hub is reachable
regardless of onboarding state, neither reads nor changes completion or
discovery state, and includes no Screenshot Assistance education.

Recurring Home presents `Request a meal`, `Find a request`, and the secondary
`Request alerts` action, followed by the utility/identity group. When a usable
verified participant identity exists, Home shows one masked verified address,
Change email, and Remove email; when it does not, Home does not fabricate an
address or require a standing verification explainer. Actions requiring
participant authority continue to present the existing verification flow on
entry. Request Food remains the existing requester flow: an unverified entry
uses the native participant-verification presentation before the form, and a
successful verification continues directly into the form without a second
participant-email field. The requester form's accepted timing, meal-swipe,
pickup-name, submission, refusal, and ambiguity semantics are unchanged.

Back controls retain stable native-looking chevron geometry and accessible
Back behavior across supported text sizes. Change email remains a quiet inline
action with an at-least-44-point touch target. Home and the Welcome and
reference screens retain their accepted responsive, scrolling, Dynamic Type,
and Reduce Motion fallbacks; functional titles use system typography, while
Quiet Fraunces remains limited to accepted brand/display moments. Dark-appearance
design for the first-use surfaces is not yet design-accepted (see the W4-O1
card in the weekly spec).

Routine/passive states default to native or inline treatment; important
non-failure states may use restrained inline emphasis; success is lightweight
by default; and no universal banner/card state system is implied. Outcome
uncertainty remains distinct from failure, using a calm blue-gray semantic
family, and every state remains distinguishable by more than color alone.
Actionable-state action choice and layout remain with the owning flow. User
facing role nouns are `student` and `helper`; motion and haptics are restrained,
meaningful, non-gamified, and Reduce Motion aware.

### 1.3 Accepted Home and navigation architecture (W4-H2)

CommonPlate has one primary product root: Home. There are no permanent Request, Help, Activity, or Settings tabs. Returning students enter the live open-request board directly rather than a recurring static launcher. Home is board-first, not role-first: CommonPlate does not create permanent requester/helper roles, and `Request a Meal` remains a prominent first-class creation action from Home. When the current student holds an active helper reservation, `Continue Helping` is a temporary priority state above the board; an ordinary open request the student posted does not itself create a separate personal Home status. Settings is a secondary shared utility route reachable from Home, not a permanent root.

#### Shared board and caller-relative ownership

A student's own open request remains visible on the shared board. Ownership is derived server-side: when `GET /api/requests` resolves valid optional participant authority, the response may include opaque caller-relative ownership metadata per request, computed by comparing the resolving verified participant to the request's persisted `requesterParticipantId`. The owner receives an affirmative ownership signal for their own request only; another verified participant receives no affirmative ownership signal for that request; anonymous/unresolved callers receive no participant-specific ownership truth. The response exposes no requester participant ID, requester email, credential, or another requester's identity; the existing public request privacy projection (section 3) is otherwise unchanged.

iOS represents this as own / notOwn / unresolved and must use only this authoritative signal — never an installation-local request-ID heuristic — to render the approved YOUR REQUEST presentation and to withhold the helper/reserve action from the owner. Unresolved ownership fails closed for helper actionability: the help/reserve action is not exposed or executable unless ownership resolves to notOwn. Participant-relative ownership is invalidated/reconciled across identity replacement (Change Email), consistent with the existing stale-response/current-participant fencing pattern used elsewhere (sections 3.1, 9.10).

The backend claim mutation authoritatively refuses a verified participant attempting to claim a request whose `requesterParticipantId` resolves to that same participant. This guard sits inside the existing atomic conditional claim mutation (section 4) as final mutation authority; the iOS action restriction is defense-in-depth, not the authority. A rejected self-claim creates no reservation/helper-binding/participation side effect, preserves existing claim status/visibility/expiry and one-active-reservation behavior, and reveals no requester identity.

#### Board continuity

An active claimed request is excluded from the shared board while `Continue Helping` represents it to that helper. Board ordering (ASAP first, then scheduled earliest to latest, otherwise canonical/source order; section 2.1) remains authoritative and unchanged by H2. Low Activity uses the real current board contents rather than fabricated/placeholder content. Empty Exchange and Exchange Unavailable are distinct, truthful states: Empty Exchange means zero currently eligible open requests; Exchange Unavailable means current request-list truth could not be established. W4-D2 (section 6.4) narrowly excepts this for one exact, ownership-resolved, authoritatively created request: that one card may render in `Your request(s)` during a `.loading`/`.unavailable` broader board without the board itself being treated as populated; no other stale requester/helper/discovery data is exempted.

#### Functional refresh

Native SwiftUI `.refreshable` is the sole refresh trigger/activation authority; H2 introduces no competing gesture, arming threshold, or second refresh/reload mechanism. All refresh interactions reuse the existing authoritative request reload (`fetchRequests()`); no second source of request truth exists. Initial unresolved Home loading may remain in the Loading presentation for at most 5 seconds before falling back to Exchange Unavailable if authoritative truth has not resolved; a user-initiated refresh may remain in the Refreshing presentation for at most 5 seconds, never a minimum — a result that resolves before the ceiling completes immediately. Timeout or cancellation never fabricates success, and a stale/cancelled fetch generation can never overwrite a newer generation's result (the existing stale-response/generation boundary). The success acknowledgment and the authored refresh presentation are governed by section 1.5 (W4-H3), which supersedes the earlier H2 recovery-only checkmark: a truthful successful refresh — healthy → healthy as well as each Unavailable → healthy destination — is acknowledged there, and a failure, timeout, cancellation, stale result, or unresolved unavailable is never acknowledged as success. Baseline Reduce Motion correctness (state, meaning, and operability preserved without relying on animation) remains accepted runtime behavior.

#### Settings, identity, and Request Alerts

Home reaches app-level utilities through one shared Settings route rather than permanent competing tabs. From Settings, `Change Email` actually presents the existing replacement verification flow (section 3.1); identity replacement (a successful Change Email) invalidates participant-relative state, including caller-relative ownership and cached Email Request Alert truth (section 9.10). An unverified participant's Request Alerts entry is an explicit `Verify NYU email` action rather than passive explanatory text or a bare disclosure chevron. The Request Alerts overlay's `Done` closes only its own overlay rather than performing ambient navigation. N0 Email Request Alert state (section 9.10) remains the sole authoritative Email On/Off source; a result or rejection resolved under authority a later Change Email has replaced cannot be silently applied to, or retire, the replacement identity. Email and Push remain independent channels (sections 8.6, 9.10); neither H2 nor Settings presentation infers or fabricates one channel's state from the other. Block management is reached at `Settings → Privacy & Safety → Blocked Students` for a verified participant (section 5.3); the Home Settings gear's interactive region is its full 44-point control.

### 1.4 Accepted Home continuous scroll composition (W4-H4)

Home is one coherent vertical scroll. The established header and priority area, `Continue Helping` when applicable, the caller-owned request preview when applicable, and `Needs help` all live inside that same scroll, in that order. `Continue Helping` retains its accepted priority (section 1.3) and the ownership preview follows it; `Needs help` follows ownership. There is no nested `Needs help` vertical scroll and no horizontal `Needs help` carousel. Exactly one native `.refreshable` is attached to that unified scroll.

#### Home ownership preview

Home presents the current participant's currently-open owned requests as a bounded, count-sensitive preview: zero owned requests render no ownership section; one renders `Your request` with one card and no `See all`; two render `Your requests` with both cards and no `See all`; three or more render the first two under the authoritative owned-request ordering plus a `See all` action; its visible label shows no count, and its accessibility label carries the full authoritative count of currently-open owned requests (for example `See all 4 requests`).

The two-card Home cap is presentation-only. Ownership authority and board ordering are unchanged from section 1.3: ownership remains the server-derived caller-relative signal, never an installation-local heuristic. An owned open request never appears under `Needs help`, including an owned request that the two-card preview does not itself display.

Within this dedicated owned-request zone (the Home preview and its `See all` destination), `RequestCardView`'s `YOUR REQUEST` eyebrow is suppressed, because the zone itself already establishes ownership. The eyebrow is preserved wherever a request card renders outside that zone (W4-R2).

#### See all

For three or more owned open requests, `See all` opens an ordinary subordinate destination containing the full currently-open owned-request set in the same authoritative ordering. It is not request history, not completed requests, not Edit/Remove, not requester management, and not a new root or tab.

#### Persistent Request a Meal

`Request a Meal` remains persistently available at the bottom of Home, outside the scrolling content, through a `ScrollView`-level `.safeAreaInset(edge: .bottom)`. That inset is the authoritative structural bottom accommodation: the final Home scroll content can be scrolled fully clear of the action rather than resting beneath it. The action carries a soft transparent-to-canvas transition above it instead of a hard opaque cutoff; that gradient is presentation only and supplies no scroll clearance of its own. There is no authored footer animation.

The action shares the same Home content column as request cards. One shared horizontal content-column inset of 24 points governs ownership cards, `Needs help` cards, and the persistent action together; they are not sized independently of each other. Authored bottom padding on the action is zero, so the remaining clearance is the device-provided home-indicator safe area, which remains native and is never overlapped or negatively adjusted.

#### Home freshness

Home resolves authoritative request data through the one existing reload path (`fetchRequests()`; section 1.3) when Home appears, and native pull-to-refresh provides manual freshness on demand. A student never has to force-quit and relaunch CommonPlate to see currently available requests.

A pull-to-refresh must actually apply the authoritative result it resolves. The lifetime of the authoritative fetch is independent of SwiftUI's own cancellation of the pull interaction: SwiftUI cancels a `.refreshable` action task as soon as the view owning the modifier is invalidated, and a refresh necessarily invalidates Home the moment it publishes its own in-flight state, so an authoritative fetch owned by that action task's lifetime would be cancelled on every pull and silently apply nothing. Transient cancellation of the refresh *caller* therefore never cancels the authoritative fetch operation.

This changes none of section 1.3's refresh authority. Native `.refreshable` remains the sole refresh trigger; there is no second refresh path, no reload authority beyond `fetchRequests()`, and no visible retry action. The initial-load and manual-refresh 5-second ceilings, the cancellation of whichever side loses the manual-refresh deadline, and the stale-response generation/collection-revision fencing that decides which result may be applied all remain exactly as recorded there; the success acknowledgment is superseded by section 1.5. Timeout or cancellation still never fabricates success.

H4 accepts refresh correctness only; the authored refresh presentation and success acknowledgment are accepted separately in section 1.5 (W4-H3).

### 1.5 Accepted Home refresh experience (W4-H3)

Home pull-to-refresh presentation and success acknowledgment. This section completes the refresh presentation that sections 1.3 and 1.4 deferred, supersedes the H2-era recovery-only checkmark, and supersedes the visible board copy `Needs help right now` and the visible `See all N` label recorded in section 1.4. It changes no refresh authority.

#### Authority is unchanged

Native `.refreshable` remains the sole refresh trigger, spinner, and loading authority. `fetchRequests()`, the 5-second deadlines, cancellation, generation/collection-revision fencing, and concurrency semantics, and `RequestStore` truth, are exactly as recorded in sections 1.3 and 1.4. There is no custom drag gesture, release threshold, or `Release to refresh` state. The authored settle and the acknowledgment are presentation only: they never trigger a refresh, decide whether one succeeded, delay or suppress refreshed data, or alter the deadline. The refreshed hierarchy is never delayed for the acknowledgment.

#### Header and rest layout

The CommonPlate header stays visually stationary during pull, active refresh, and settle, and scrolls away normally during ordinary upward scrolling of a legitimately long Home; it is not permanently sticky. Ownership between the pull-band header and the in-scroll header is derived from scroll position only, never from refresh state or timers, and exactly one header and one Settings affordance are perceived and accessibility-exposed at a time. The permanent Home rest layout, the short-content scroll range, and the fixed bottom `Request a Meal` composition (section 1.4) are unchanged.

#### Truthful success acknowledgment

A truthful successful refresh — a user-initiated native refresh whose authoritative result resolved before the deadline, was applied under the generation fence, and resolves to a healthy Home — is acknowledged by a bare 18×18 purple check and a VoiceOver-only `Updated` announcement, exactly once per eligible refresh. This applies to healthy → healthy (whether or not visible content changed) and to every Unavailable → healthy destination: the ordinary board, Continue Helping, Your request(s), and the combined Continue Helping + Your request(s) state.

The check is opacity-only: no circle or badge, no text, no scale or bounce, no haptic, and no success dwell. No visible `Updated` text appears anywhere on Home. The announcement does not move accessibility focus, and the check is neither focusable nor a persistent accessibility element.

A failure, timeout, cancellation, stale or superseded result, failed fetch (a failed refresh of a previously healthy Home preserves the existing stale-healthy behavior), or an Unavailable refresh that remains Unavailable receives neither the check nor the announcement, and no failure copy, motion, or haptic is added.

#### Authored post-refresh settle

After a truthful successful refresh and once the native spinner is visually gone, the dynamic Home content is held in a 36 pt transient lane rather than snapping to rest, and the check sits fixed and horizontally centered 18 pt below the header band — below CommonPlate, above `Needs help`, clear of `at NYU`, not in the permanent rest gap, and not travelling with the content.

- **Standard Motion:** the lane holds still for about 0.35 s; the check holds 200 ms and fades during one about 0.4 s ease-in-out return of the content to rest; the whole authored treatment is about 0.75 s. There is no overshoot, bounce, or oscillation, and the spinner and check never appear together.
- **Reduce Motion:** the same lane and fixed check geometry; a 0.5 s static hold, the same 200 ms check hold, then one about 0.2 s ease-out return. No alternate success state or directional or celebratory motion exists, and the spinner remains native.

#### Context-bound lifetime and stale retirement

The acknowledgment is presented only if, at the moment it would begin, Home is still the presented destination and the scroll position is still within the top/header-owned refresh context. Otherwise both the check and the announcement are suppressed together; a suppressed acknowledgment is never queued, deferred, or replayed, and suppression never cancels the refresh or discards its data. A new refresh or repeated pull retires any older pending or visible acknowledgment, so an older check never stacks with a new spinner and at most one `Updated` is announced per eligible refresh.

#### Successful-recovery fallback

For a successful Unavailable → healthy recovery whose native reading is already at or within 6 pt of rest, with no transient lane in which to present the acknowledgment, neither the check nor `Updated` is emitted. The recovered data applies normally, no overlay is placed over ordinary Home content, and the recovered Home remains accessibly represented. The runtime cannot independently observe a visually open lane in every case; that accepted residual is recorded in the weekly spec and is not a guarantee that this fallback is never taken while a lane is visually open.

#### Board copy and ownership overflow

The Home board heading is `Needs help` in every state. For three or more owned open requests the heading remains `Your requests` and the trailing action is `See all` with no visible count; its accessibility label retains the full open-request count (for example `See all 4 requests`), it keeps a minimum 44 pt target, and at large Dynamic Type it may move below the heading. There is no `See all` for zero, one, or two owned requests. The destination, its full carried request set and order, and ownership semantics are unchanged.

#### Verification boundary

The rendered pull feel, VoiceOver announcement and focus behavior, accessibility frames, and hit-testing while the authored offset is active were verified manually on a physical iPhone by Faith, using a Debug build with a temporary LAN endpoint against a synthetic stub backend; they are not established by the automated suite. Release, Archive, and TestFlight behavior is not established (section 11).

## 2. Request lifecycle and availability

| Persisted state | Meaning | Effective availability |
| --- | --- | --- |
| `open` | Awaiting a helper | Available only before `expiresAt` and with at least five full minutes remaining to claim. |
| `claimed` | Reserved for one helper | Not publicly available while its active claim has not expired; it may become claimable again after claim expiry if the request itself remains eligible. A claimed request carrying the post-Yes external-order-risk authority (section 5.3) is never claimable or advertised again. |
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
| Participant Block records, the post-Yes `externalOrderAffirmed` request marker, the `contactMessageWithheld` marker, and `blockFenceEpoch` | Never public and never projected on any list, detail, requester, placement, or error response (section 5.3). A caller sees only its own Blocks as interaction context, and only affirmative-only restriction signals on its own reservation. |
| Placed-order evidence (`PlacementEvidence` row, its image bytes, MIME type, and `byteLength`) | Never public and never projected on any list, detail, helper-facing, or error response. It is absent from the fulfillment email, from every notification, and from every log (section 5.4). |
| Helper email | May be sent to the requester in the committed-placement email for coordination. |

### 3.1 Verified participant identity

The NYU allowlist (`nyu.edu` and `stern.nyu.edu`) establishes only that an address is eligible to become a participant; it does not establish mailbox ownership, enrollment, a human identity, or equivalence between aliases, vanity addresses, or `+tag` variants. Mailbox control is established only when that exact normalized allowed address successfully completes the participant email-code verification flow. That resulting normalized address is the participant principal.

Participant identity is distinct from Subscriber identity, Push Installation identity, claim-token authorization, and unsubscribe credentials. A Participant is backend authority for an acting requester or helper; an Installation is only device-local notification-routing metadata, and a Subscriber is only the email-alert lifecycle. Neither substitutes for participant authority.

Participant actions require usable backend-verifiable participant authority. Request creation derives the requester principal from that authority and binds it to the Request; a caller-supplied legacy `email` field, when present, must match the verified principal and is never the source of the persisted requester identity. The atomic claim grant likewise binds the verified helper principal. These bindings remain private.

Fulfillment uses the helper principal bound to the claim, never a caller-entered helper email. A valid unexpired claim created before this binding existed remains narrowly fulfillable through its existing claim-token authorization only when `helperParticipantId` is physically absent; this compatibility path does not authorize a post-identity claim without participant binding.

After successful verification, an installation is designed to retain its private authority across ordinary launches while it remains usable; backend rejection, revocation, missing, or malformed stored authority requires verification again. A reinstall or new device has no automatic recovery and requires verification again. Change Email leaves the existing authority active until the replacement address has successfully verified, then applies the replacement only to future actions; existing request and claim bindings remain unchanged. These device-lifecycle properties are accepted runtime behavior, with physical Keychain/device proof still recorded as an environmental limitation in `docs/testing.md`.

On iOS, selecting Request Food requires usable verified participant identity before the request form is initially exposed. If no usable identity exists, iOS presents the existing participant-verification flow first; successful verification continues directly into Request Food, and an already-verified or restored identity enters Request Food directly, in both cases without another editable participant-email field. Request submission remains bound to this verified participant authority. If that authority is lost after the form was already legitimately admitted, the form and its in-progress draft are preserved rather than discarded, and recovery uses the same in-form reverification continuation Request Food already provides at submission; authority loss alone does not return the requester to the pre-form verification screen. Change Email continues to require reverification, per the device-lifecycle properties above.

Remove Email is a distinct app-level action from Change Email and requires explicit confirmation. Safe removal forgets only the current installation's verified participant identity and immediately returns that installation to unverified; Request Food and Help require verification again. It performs no backend Participant deletion and rewrites no historical Request, reservation, fulfillment, or RequestParticipation ownership. W3-H2 participation remains bound to the original verified principal: removing and reverifying as the same principal does not bypass prior participation, while a genuinely different verified principal does not inherit the former principal's history. Subscriber/email-alert state and Push Installation/preferences remain independent.

Remove Email is refuse-only while participant-bound work or recovery makes forgetting unsafe, and remains unavailable until the app has established removal safety for the current process. An active H1 reservation or participant-authorized fulfillment state, including unresolved ambiguous-fulfillment recovery, blocks removal. An unresolved W3-D1/W4-D2 request-create recovery also blocks removal, in both the stable-unresolved and identity-unavailable states (section 6.4). Unknown or inconclusive H1 reconciliation fails closed rather than allowing removal. I4 performs no assisted release, fulfillment mutation, D1 mutation, or backend identity deletion.

While removal safety has not yet been established, Settings shows a loading presentation only for as long as a relaunch-reconciliation read is actually in flight; once that read has failed or otherwise remains unresolved and is no longer actively running, Settings instead shows `Remove Email is temporarily unavailable.` with no spinner (W4-R2). This is presentation only: it changes no removal-eligibility semantics, and Remove Email remains blocked in both cases exactly as this section already requires.

Verified participant identity is app-level CommonPlate identity, not Request Food content. Home presents the currently verified participant identity when one exists and provides the accepted app-level identity controls; this is the sole identity-presentation source. When no usable verified participant identity exists, Home need not present a standing verification explainer; actions that require verified participant authority present the existing verification flow on entry. Change Email preserves the current verified authority until the replacement address successfully verifies, consistent with the device-lifecycle properties above.

Participant verification and Change Email present their existing lifecycle action-first: NYU email → Send code → code entry → Verify, with the field and its action leading and supporting eligibility/purpose/replacement/revoked explanation visually secondary beneath. No verification-code, resend, expiry, credential, participant-principal, persistence, or authorization behavior is changed by this presentation.

Request Food contains no Contact section and no verified-participant-email row: it does not display the verified participant email and does not ask the requester to enter or reconfirm a participant email. It still submits using the accepted verified participant authority established before the form was reached (section 3.1 above). The requester email remains private participant identity and is not presented as information shared with helpers.

The legacy website has no participant-verification UX. Until the separate Week 6 work exists, website request creation is deliberately non-actionable and cannot bypass participant authority. This does not define later website verification behavior.

## 4. Claim contract

Claiming requires usable participant authority and is an atomic conditional mutation, so one eligible attempt wins and binds that verified helper principal. A verified participant may hold at most one active reservation across requests, app processes, devices, and installations; different verified participants may reserve independently. The winning response returns the raw token once; iOS keeps it only in private in-memory store state, while the backend keeps an HMAC digest. Subscriber and Push Installation identities are neither participant identity nor reservation authority.

An active reservation lasts at most 15 minutes and is capped by `expiresAt`. Leaving, backgrounding, or terminating CommonPlate does not release it. Relaunch resolves the active reservation from verified participant authority; it never persists or reconstructs the raw claim token. Continuation establishes an active reservation only from a current reservation whose embedded request is `claimed`; explicit absence establishes none, while transport, server, decoding, authority, or contradictory-response failures remain unknown and do not fabricate lifecycle state or clear warning state. A restored reservation captures the exact participant authority that established that reservation lifecycle, so a later Change Email affects future actions but does not rewrite authority for the restored reservation. A backend rejection retires a presented participant credential only when it is still the app's current credential; a stale rejection cannot retire a newer replacement.

Reservation actions require the reservation's exact authority. The raw token remains the preferred in-process path; verified participant authority is the additive continuation path when that token no longer exists. Explicit release atomically invalidates a currently authorized reservation and immediately returns the request to availability when otherwise eligible; a request carrying the post-Yes external-order-risk authority is instead retired in place and never returns to availability (section 5.3). Local reservation state clears only after `released: true` is confirmed. A release cannot reopen a placed request or another participant's reservation, and released authority cannot later extend, release, or fulfill. Release, extension, and fulfillment use conditional lifecycle mutations, so concurrent operations have one coherent winner; iOS also mutually excludes their local in-flight and ambiguous-fulfillment states.

Its holder may receive exactly one five-minute extension only when the full extension fits before request expiry; a participant Block does not withhold it (section 5.3). iOS offers extension only while that remains true; backend timing and mutation results remain authoritative. A readable `INTERNAL_FAILURE` from claim is ambiguous: iOS does not automatically retry it and never permits ordering without a confirmed active claim and its raw token or reservation-scoped continuation authority.

## 5. Fulfillment contract

Fulfillment requires a valid, unexpired active reservation authorized by its raw claim token or, after continuation, its exact reservation-scoped participant authority. The raw-token path remains preferred whenever a token is still held. Fulfillment reuses the verified helper principal atomically bound at claim grant, rather than trusting any helper email supplied by the caller. Every new fulfillment also requires one valid placed-order screenshot (section 5.4). In one MongoDB transaction, the backend conditionally transitions the request from `claimed` to `placed`, creates its Fulfillment ledger record, and creates its private `PlacementEvidence` row; the three commit or abort together. A unique Fulfillment `requestId` index independently protects one fulfillment per request. The sole compatibility exception is an active pre-W3-I1 claim whose helper binding field is absent, as defined in section 3.1.

`orderNumber` is a digits-only string, not a number; leading zeroes are preserved. The requester email is submitted only after placement commits. Email failure does not undo placement, and failure to clean up the database session cannot replace the committed placement result.

Fulfillment `INTERNAL_FAILURE` is ambiguous. iOS performs one read-only request-status check, then permits at most one exact-payload CommonPlate-only resend using the retained in-memory submission (including the identical screenshot, section 5.4) and its exact original authorization (raw token or reservation-scoped participant authority). It never instructs the helper to place another external order.

After a confirmed placement, iOS ends the client helper lifecycle at once: the active reservation and its claim authorization are cleared. The success presentation is presentation only, has no lifecycle authority, and retires itself when it returns the helper to Home (section 5.2); it neither gates nor authorizes a new claim. There is no Got It, Done, or other acknowledgement control.

Fulfillment remains request/claim-bound: the requester placement email is addressed to the requester's own submitted address, tied to this specific request and its committed placement, never to a general participant contact channel. For a verified-helper placement, that email's `Reply-To` may carry the claim-bound helper's own verified email address, so the requester can coordinate directly with the helper about that order, except when the pair is fenced by a Block, in which case no helper address is sent (section 5.3). Where the accepted implementation cannot establish a verified helper address for the placement (the pre-W3-I1 compatibility path in section 3.1), no `Reply-To` address is fabricated or substituted; the email is sent without one. V1 therefore does not guarantee that participants' real email addresses remain mutually hidden from one another. Private, request-scoped email relay and mutual participant-address privacy (W3-M1) are deferred to V2/post-pilot; product and privacy-facing copy must describe this V1 direct-coordination behavior truthfully rather than promising hidden addresses.

### 5.1 Helper participation continuity (W3-H2)

Once a verified W3-I1 participant principal has successfully acquired reservation authority over request R — the atomic claim-grant conditional mutation actually committing for that principal — that same principal can never successfully acquire R again. This is durable: release and passive claim expiry do not erase it, and it survives across devices, reinstalls, and newly issued authority for the same principal. A failed or raced attempt that never wins authority consumes no participation. Other eligible verified participants remain able to acquire R independently. This invariant is separate from and does not alter section 4's one-active-reservation-across-requests invariant; both apply to the same claim attempt without conflict.

The invariant is bound to the exact normalized verified W3-I1 participant principal, never to device, installation, or push identity. Reverification of the same principal preserves enforcement. A successful Change Email to a genuinely different verified email establishes a different participant principal for future actions; the historical participation record remains bound to the original principal and does not constrain the new principal. This does not create a hidden cross-email human identity.

Participation history is durable, append-only backend state: the `RequestParticipation` collection records one row per successful `(requestId, participantId)` acquisition, written once inside the same transaction that grants the claim, and never updated or cleared by release, expiry, or a later reacquisition attempt. `Request.helperParticipantId` remains current-holder state only (overwritten on reclaim, `$unset` on release) and is not the source of historical truth. A unique `(requestId, participantId)` index is the sole concurrency primitive behind "at most one successful acquisition per participant per request"; `claimRequest` consults this collection before its own conditional grant filter, and a race that slips past the pre-check still loses the transaction on that index. This index is explicitly established during application startup (`RequestParticipation.createIndexes()`, before the process listens), so claim traffic is never accepted against a database that has not established the guarantee. Backend claim rejection remains authoritative for stale or racing clients regardless of what a client believes.

A request a verified participant has previously successfully held is excluded from that participant's own eligible request-list results; every other eligible participant's list is unaffected, because the exclusion is scoped to exactly the resolving caller's own participant id. Participant-aware request-detail responses may expose only the resolving caller's own already-participated boolean for that request, alongside the existing public request projection and privacy boundary (section 3); a caller with no verified participant identity is answered as though anonymous, never refused. Caller-specific detail responses use the existing cache-isolation boundary that prevents one participant's resolved result from leaking into another's rendered state. iOS does not expose or execute Reserve unless authoritative eligibility for the current request and the caller's current participant key resolves to eligible; a stale or mismatched resolution — including one resolved for a since-changed participant identity — is never treated as eligible.

If a placement has durably committed but the client lost usable completion state, an authoritative backend read of participant-scoped placed-request truth (`Request.status === "placed"` plus its retained `helperParticipantId` binding) reports it on relaunch or reconstruction. Confirmed placement completes the helper relationship, so iOS reconciles that report to the ordinary helper-available state and reconstructs no success presentation, haptic, or acknowledgement gate. It never recreates reservation authority or a raw claim token, and never exposes a second Place Order or other second-external-order affordance for that request. The read is bounded by the request's existing retained lifetime (`deleteAt`/`PLACED_RETENTION_MS`, section 2): a request at or past its retention horizon is not reported as placed merely because TTL deletion is asynchronous. Fulfillment already releases the participant's reservation lock server-side on placement (section 4).

### 5.2 Helper Message suppression (W4-U1.1)

The helper's optional fulfillment Message remains fulfillment/email-only and is filtered authoritatively at the fulfillment mutation by the same deterministic, provider-free filter that governs requester text (section 6). A matching Message never blocks legitimate placement: the transaction in section 5 still commits exactly once, the Message is not persisted, and it is not included in the requester placement email, which is still sent without it. No participant text is sent to any external moderation provider.

The only durable suppression truth is a content-free `contactMessageSuppressed` marker (`select: false` on the Request model), written in the same atomic placement update. The Request schema carries no `contactMessage` field. Neither the marker nor any response names the matched term, category, or field. Pre-filter placed rows that still carry a persisted Message are not migrated and expire with the existing placed retention (section 2).

Suppression status is distinct from provider email status (`notificationStatus`, section 8.2): provider acceptance is not delivery, and suppression is never inferred from email status or from Message absence. The fulfillment response and the participant-scoped placed read (`GET /api/participant/active-reservation`) carry an affirmative-only `messageSuppressed: true` to the placing helper; it is absent otherwise, never an explicit `false`, and the public request list/detail projection is untouched (section 3).

Fixed Pickup ETA: fulfillment accepts exactly `ASAP`, `15 minutes`, `30 minutes`, `45 minutes`, or `60 minutes` (after trimming); any other value, including free text, is refused before fulfillment work. ETA is therefore not moderated text.

**Ambiguity recovery.** The Section 5 recovery contract is unchanged. After the single read-only status check proves placement, iOS may make one additional participant-scoped placed read solely to establish suppression, and only when the submission carried a non-blank Message. An inconclusive result leaves suppression unestablished: confirmed placement is applied with or without it and suppression is never fabricated. Relaunch does not reconstruct transient suppression UI. If the one manual repeat of an exact resend receives `REQUEST_ALREADY_PLACED`, the existing already-recorded notice is shown without a suppression statement.

**Success presentation.** When authoritative fulfillment truth establishes both placement and suppression, the helper success state is the ordinary success presentation with headline `Thanks for helping someone out.` and a subordinate `Message not sent` card (`Your message didn’t meet CommonPlate’s guidelines.`); it does not claim failure, shows neither email-result line, and introduces no retry, edit, acknowledgement, or second-order control. Ordinary non-suppressed success variants are unchanged. Automatic return to Home occurs exactly once. When VoiceOver is not running at resolve, Home follows an approximately 2-second readable dwell. When VoiceOver is running at resolve (read once per confirmation), Home occurs at the later of that dwell and successful completion of the complete success announcement, with at most one repost on interruption, no second haptic, and a bounded active-time fallback so the screen cannot remain indefinitely (9 seconds in the accepted implementation, never more than 10). The announcement carries the same strings as the visible state.

### 5.3 Participant blocking and interaction fencing (W4-U1.3)

**Block authority.** A Block is a durable, owner-scoped `ParticipantBlock` record in its own collection, unique per ordered `(blocker, blocked)` pair and with no TTL, so it outlives the Request that supplied its context (`deleteAt`). It carries the two private participant references (`select: false`, never projected) and only an interaction-context snapshot: the blocked party's role (`requester` or `helper`), the request's dining location, and the request's creation time. No name, NYU email, participant identifier, or order content is stored for or projected from it, and the snapshot is deleted with the row on Unblock.

Block is contextual only. `POST /api/request/:id/block` names a request and nothing else; the backend resolves the counterpart from the request's private participant authority. There is no student directory, global person lookup or search, arbitrary-email Block, or participant-ID Block. A helper may Block the requester of a request the helper could legitimately have opened (visible now); a requester may Block only the recorded helper of the requester's own placed, still-retained request; every other target, a request not yet visible, and a self-target are refused as `404 REQUEST_NOT_FOUND`. Repeating a Block for the same ordered pair is an idempotent no-op that keeps the original snapshot. The iOS client offers the helper-side entry only; the requester → helper creation authority is backend-only and its client surface belongs to R3.

**Pair fence.** A pair is fenced while a Block exists in either direction. The two directions are separately owned records: a fence persists after one is removed if the other remains, and no response exposes the owner or direction of any Block as a field. Unblock (`DELETE /api/participant/blocks/:blockId`) removes only the caller's own record, prospectively: it never resurrects an expired request or an old reservation, and never alters `RequestParticipation`, placement, fulfillment, or pickup truth. A record that is missing and a record owned by someone else are the same `404 BLOCK_NOT_FOUND`. `GET /api/participant/blocks` returns only the caller's own records, as interaction context.

**Where the fence is enforced (server-authoritative, never UI-only).**

- *Board discovery:* a caller's list excludes requests authored by any participant fenced from them, applied in the query ahead of the fixed list limit. Anonymous and unresolved callers have no participant authority and are unfiltered.
- *Request Detail:* a fenced counterpart's request is answered exactly as a request that does not exist (`404`), ahead of the not-yet-available refusal, so a request ID does not bypass the fence. Exempt, because it is not new interaction: the request's own requester, and the participant currently holding the request as helper (its placement, or its live unexpired reservation).
- *Claim:* inside the claim transaction, in the same snapshot as the grant and ahead of the participation check, answered as an ordinary `404 REQUEST_NOT_FOUND`. Every Block write also writes both participants' private `blockFenceEpoch`, and every claim writes the claimant's own Participant document, so a concurrent Block and claim conflict and one is retried against a snapshot that contains the other: no reservation is granted across a committed Block.
- *Not fenced:* Add 5 minutes (extension), release, and placement. A Block fences new interaction; it never strips a reservation or placement the participant already legitimately holds.

**Block while helping.** While the caller holds a live reservation on the request, the Block body must carry `externalOrderPlaced`; without it the request is refused `400 BLOCK_EXTERNAL_ORDER_ANSWER_REQUIRED`.

- *`No` (`externalOrderPlaced: false`):* Block and the ordinary release commit in one transaction through the one accepted release mutation, so the request returns to ordinary availability for other eligible helpers. While `PUBLIC_ACTIONS_PAUSED` governs release, neither commits (`503 PUBLIC_ACTIONS_PAUSED`), and a reservation that moved after the attempt began (an extension) commits neither (`409 RESERVATION_STATE_CHANGED`).
- *`Yes` (`externalOrderPlaced: true`):* the Block commits with the reservation left untouched, and, in the same transaction, a private, content-free, `select: false` request marker `externalOrderAffirmed` is written, pinned to the exact reservation the answer was given for (same helper binding and deadline). A `Yes` is accepted at the expiry boundary only while the request is still `claimed`, still bound to the same helper, not released or re-claimed, and the request itself unexpired.
- *Refused `Yes`:* if the caller no longer owns the reservation (it was released, re-claimed by another helper, placed, retired, or the request expired), the operation answers `409 RESERVATION_STATE_CHANGED` and writes no Block, no fence bump, and no marker, and touches nothing of another helper's reservation. It never reports Block success while failing the post-Yes transition.
- Block and Unblock are safety controls and are not behind `PUBLIC_ACTIONS_PAUSED`; the `No` branch is gated only because it includes release.

**Post-Yes request.** While `externalOrderAffirmed` exists the request is never claimable and never advertised: the shared effective-availability predicate, the claim filter, the board, detail, helper alerts, digests, and push eligibility all exclude it, whatever its stored status or deadline says. This holds after the helper's Stop, after passive reservation expiry, and after Unblock, and it ends only with the Request itself (ordinary `deleteAt` retention). The marker is never projected on any list, detail, requester, placement, or error response.

- *Add 5 minutes* remains available under the ordinary one-use and fit-before-expiry rules and never answers differently because a Block exists, in either direction.
- *Stop helping* remains available, is an ordinary release-class mutation for pause, rate limiting, authorization, version-pinning, and in-flight/ambiguous-fulfillment exclusion, and for a marked request retires the reservation in place: the deadline, claim-token digest, helper binding, and one-use marker are removed and the helper's active-reservation lock is cleared, while the request stays `claimed` and never becomes `open`. No placement is fabricated, the external order is never claimed cancelled, the request is not offered to another helper, and the Block remains effective. A Stop without the marker is the existing release unchanged. The retired authority can no longer extend, release, or fulfill, and answers like an ordinarily released reservation; the stopped helper cannot resume it, may help another eligible request, and cannot re-claim this one (section 5.1).
- *Concurrency:* Stop, extension, fulfillment, and expiry resolve through the existing conditional, version-pinned mutations to one coherent winner. A fulfillment that wins is authoritative `placed` truth; a later Stop cannot undo it.
- *Finish helping* keeps ordinary authoritative fulfillment, ambiguity, and success.

**Active-reservation read.** `GET /api/participant/active-reservation` adds two affirmative-only fields to a live reservation, each absent rather than `false` when not established: `directContactRestricted: true` when a pair fence exists in either direction (it states that optional direct contact is unavailable, never who blocked whom), and `stopReturnsHome: true` when the marker exists and no pair restriction remains (so a requester-blocked helper's read is the same with or without the marker). They carry no Block owner, direction, or marker.

**Placed-order continuity and direct contact.** A Block never refuses, alters, or undoes placement, and never reverses a placed order. For a fenced pair the placement transaction still commits exactly once; the optional helper Message is not persisted or emailed (the content-free `contactMessageSuppressed` marker plus a second content-free `contactMessageWithheld` marker, written in the same atomic update); and the requester email carries the order facts without the helper `Reply-To` (section 5), re-checked after commit and withheld when the answer cannot be read. A Message withheld by the fence is reported only to the placing helper (`messageSuppressed` with `messageWithheld`, never a filter verdict), and iOS shows the ordinary success with no `Message not sent` card for it. Direct participant-to-participant contact stays unavailable for a fenced pair after placement; any support destination belongs to W4-T1 and is not fabricated here.

**iOS presentation (runtime truth, not layout).**

- *Entry.* Before helping, Request Detail's contextual `•••` → `Block this student` → a centered confirmation (`Block this student?`, `Block student`, `Cancel`) → Home. While the reservation is held, the canonical Helping screen's contextual `•••` → `Have you already placed the Grubhub order?` with neutral `Yes, already placed` / `No, not yet` / `Cancel` and no explanation below; `Your message won’t be shared.` appears once before the choices only when a Message draft exists, read from the live draft (no draft is persisted for Block). `No, not yet` → Home. A failed Block shows the alert title `Couldn’t block` with the existing truthful mapped message and is never presented as success. An outcome iOS cannot confirm is never retried, never presented as a success or release, and points the helper to Blocked Students. Block is mutually excluded with an in-flight release, extension, or fulfillment.
- *Restricted Helping (after `Yes` and on reconstruction).* Retains reservation context, Add 5 minutes (or its ordinary replacement states), Stop helping, `Open Grubhub`, `After you order`, `Order number`, `Pickup ETA`, and `Finish helping`; suppresses the Message, direct contact, and the Helping safety menu once a Block is active. Control composition is identical for the caller-owned and reconstructed states and reveals no ownership.
- *Immediate caller-owned `Yes`.* A compact accent `BLOCK ACTIVE` status with the muted line `You can continue or stop helping.` appears directly beneath the `After you order` heading, and the Helping view may orient to the After-you-order region once. The orientation does not focus a field, open Pickup ETA, or change lifecycle authority; Cancel, `No, not yet`, and failure never show it, and a restricted state merely loaded after relaunch does not scroll.
- *Reconstructed unknown-direction.* Shows the neutral `Direct contact is unavailable. You can still finish this order.` The client never infers who owns the Block from the direction-agnostic restriction.
- *After Unblock.* Only the ephemeral caller-owned marker is cleared. The direction-agnostic restriction is re-established through the authoritative active-reservation read; if that read fails or is superseded the conservative restriction stays, never cleared by assumption.
- *Stop and Back destination.* A confirmed Stop ends at Home, never Active Requests, while a restriction exists or `stopReturnsHome` is reported (so after the helper's own Unblock and after relaunch too). Restricted Helping reached through Block → `Yes` resolves Back to Home, including from a legacy Active-Requests-rooted stack. Other `.activeRequests` callers are unchanged and belong to W4-R5.
- *Block management.* `Settings → Privacy & Safety → Blocked Students`, offered only with a verified participant: anonymous context rows (muted `Requester`/`Helper`, semibold dining location, regular timestamp, never truncated), a stable trailing `Unblock` lane, direct Unblock with no confirmation and no permanent footer, an empty state, and a fresh read that does not keep a stale Unblock failure. Available while operationally paused.
- *Home Settings gear.* The gear's interactive region is the full 44-point control (visual ring unchanged).

**Accepted limitations.**

- *Requester timing/state inference.* V1 never exposes a Block owner or direction, but a post-Yes stopped request keeps its existing claimed-like projection past an ordinary reservation's duration, so a requester who understands normal timing can infer an exceptional safety lifecycle and may suspect they were blocked. U1.3 does not claim resistance to this inference and adds no requester copy or state; removing it needs a generic requester lifecycle presentation owned by a later slice.
- *Deleted request.* A late `Yes` against a physically absent (TTL-deleted) request may answer `404 REQUEST_NOT_FOUND`; it writes nothing and reports no success.
- *Lost authority.* A Block + `Yes` that loses reservation authority before commit fails with `409 RESERVATION_STATE_CHANGED` rather than creating the Block; there is no mixed Block-succeeded/protection-failed state.
- *Unrecorded order.* A helper who affirms an external order and then Stops leaves CommonPlate with no fulfillment details for the requester, who is given no explanation, and consumed daily request quota is not restored.
- *No later requester Block.* After `I picked it up` removes the continuation from active Home, V1 offers no requester → helper Block entry for that helper; existing Blocks remain manageable.
- Block continuity across completed account deletion and same-email recreation is not provided here (W4-P2); different verified NYU email principals remain distinct (section 3.1).

### 5.4 Required placed-order evidence and manual fulfillment (W4-H1a)

**Requirement.** Every new successful helper fulfillment requires exactly one placed-order screenshot, in both authorization shapes (raw claim token and participant continuation) and in the section 5.3 `Yes, already placed` blocked-pair state, which adds no exception. The backend never commits a new fulfillment without a valid image; there is no compatibility path and no screenshot-less placement for older clients. Placements committed before this requirement remain historical data with no evidence row. The screenshot is required regardless of the Screenshot Assistance setting, and the only hard requirements are an attached, supported-type, structurally valid, bounded image. It is evidence the helper supplied, not proof that the order is genuine: nothing recognizes text, checks for Grubhub content, or judges authenticity, OCR is never a gate, and selecting or submitting it starts no analysis and transfers nothing to any AI provider.

**Transport and refusal.** The image travels as `fulfillment.placedOrderScreenshot: { mimeType, imageBase64 }` inside the existing fulfillment body. The fulfillment route owns a bounded `express.json({ limit: "3mb" })` parser, registered (`registerFulfillmentRoute`) ahead of the unchanged 100 KB global parser and behind the route's rate limiter; the shared parser limit is unchanged for every other route. Accepted types are `image/jpeg` and `image/png`; the value must be strict base64 and a structurally valid image of that type, with a decoded size of at most `1_500_000` bytes. Validation order is participant authority, then the ordinary payload, then the screenshot, then the section 5.2 Message filter, then the transaction. A missing, malformed, oversized, or wrong-type screenshot is a definitive `400 INVALID_PLACED_ORDER_SCREENSHOT` (`The order screenshot is missing or can’t be used.`), distinct from `INVALID_FULFILLMENT_PAYLOAD`, returned before any mutation and without saying which check failed. A request body over the parser ceiling answers the same code; any other unreadable body answers `INVALID_FULFILLMENT_PAYLOAD`. The route's parser-error boundary logs nothing, because a parser error can carry a slice of the raw body; an error that did not come from the parser is passed on unchanged and is never reported as a definitive 400, since it can follow a committed placement.

**Private persistence.** `PlacementEvidence` holds one row per Request: `requestId`, `image` (a Buffer, `select: false`), `mimeType`, `byteLength`, `deleteAt`, and timestamps. A unique `requestId` index (`placement_evidence_request_unique`) is the database-level guard that a resend or race can never produce a second row, and a `deleteAt` TTL index (`placement_evidence_deleteAt_ttl`, `expireAfterSeconds: 0`) removes it. Both are established at startup before the process listens (`PlacementEvidence.createIndexes()`). The schema also rejects an empty or over-cap image and an out-of-range `byteLength`. The row is created with the placement session immediately after the Fulfillment ledger row, so Request `placed`, Fulfillment, and PlacementEvidence commit or abort together: a failure inserting the row, including a uniqueness violation, aborts the whole placement, and a placed Request never exists without its evidence. Its `deleteAt` is the same `placedAt + PLACED_RETENTION_MS` value, computed once, that the placed Request carries (seven days, section 2). There is no object storage, signed URL, filesystem path, upload lifecycle, or general attachment system, and the QA reset deletes the row with its Request. Requester pickup confirmation does not delete it.

**Privacy.** The evidence never appears in the public Request DTO, list or detail projections, the fulfillment response, the participant-scoped placed read, the requester fulfillment email, any notification, or any log. No route in this slice returns the bytes; a requester-private, participant-authorized read belongs to W4-R3. The helper cannot replace the screenshot after placement commits. Request and account-deletion classification of `PlacementEvidence` belongs to W4-P2/R5; until they classify it, evidence outlives an early-deleted Request until its own TTL.

**Manual fulfillment fields.** Order number (digits-only, section 5), fixed Pickup ETA (section 5.2), and the optional Message (filtered, fenced, and suppressed as in sections 5.2 and 5.3) are entered manually. Screenshot Assistance disabled, unavailable, or never used changes nothing about this path.

**iOS selection and gating.** The Helping page's After you order section lists, in order: Order screenshot (right-aligned `Required`), Order number, Pickup ETA, the optional Message when not suppressed, the direct-coordination disclosure, and the pinned `Finish helping`, which stays disabled until a valid screenshot is attached and every other required field is valid and the store permits a submission. A missing screenshot is an incomplete state, not an error: it produces no red message and no tap-to-validate behavior. Before selection the control reads `Choose Grubhub screenshot` with no accompanying privacy or explanatory line; after a valid attachment it reads `Screenshot attached` with a `Change` action (VoiceOver `Change order screenshot`) that replaces the one image through the same picker. The selection lives only in the owning store's private in-memory state; it is neither published nor persisted, and the view never holds the bytes. Before it is sent, the image is read and normalized on the device off the main thread: only the latest selection applies, JPEG and PNG are accepted, other source formats (for example HEIC) are re-encoded to JPEG, the longest edge is at most 2000 px and is never upscaled, JPEG quality is `0.7` with exactly one fallback re-encode at `0.5`, and the result must be within `1_500_000` bytes. A failure at any step, or a definitive backend refusal before commit, fails closed to an unattached chooser and sends nothing: `This image can’t be used. Choose another screenshot to continue.` Network, claim, placement, and other unrelated failures keep their existing classifications and copy and are never mapped to that message.

**Ambiguity and relaunch.** The retained submission snapshot carries the exact screenshot bytes. The section 5 bounded recovery (one read-only status check, at most one exact-payload CommonPlate-only resend with the original authorization) resends the identical image. A selection, Change, or clear arriving after a submission was issued never alters that snapshot. A resend that finds `REQUEST_ALREADY_PLACED` uses the existing path; ambiguity is never turned into screenshot reselection, release, cancellation, or a second-order affordance. The screenshot is never persisted, so after a relaunch that restores a still-claimed, unfulfilled reservation the helper re-enters fulfillment data and selects the screenshot again, with `The order screenshot needs to be added again before you continue.` shown at the chooser. A relaunch after placement reconstructs no success presentation, haptic, or second-order affordance (section 5.1).

**Success and return.** Success begins only on authoritative placed truth (the fulfillment response or the bounded status check) and ends the helper lifecycle as section 5 states. It plays one semantic haptic and one VoiceOver announcement, then returns to Home exactly once, per section 5.2; there is no Got It, Done, or acknowledgement control. When placement succeeds but requester-email provider submission fails, the ending is unchanged: `Thanks for helping.` with the secondary line `We couldn't email the requester.`, then the same automatic return to Home. There is no email retry, placement retry, second-order action, alternative notification, or failure screen, and email failure never undoes placement. The section 5.2 Message-suppressed presentation and the section 5.3 blocking behavior are unchanged.

**Request Detail.** The pre-fulfillment note about verifying an NYU email before helping is removed with no replacement. `Start helping` remains offered to an otherwise eligible unverified participant and still begins the existing verification flow; no claim precedes successful verification, and verification and claim authority are unchanged.

## 6. Request-creation contract

Creation requires usable participant authority as well as strict backend validation for canonical and legacy request shapes, vendor, email when supplied, required text, scheduling bounds, and a still-usable scheduled end time. The backend derives and persists the requester identity from that authority. Where iOS can know an error locally, it validates before submission (including required fields, email, and scheduling/form constraints).

CommonPlate has one canonical supported-vendor catalog, `shared/vendors.json`, currently the accepted 11 dining locations. Backend request creation is authoritative over it. Both supported create payload shapes require `vendor` to match a catalog entry exactly, after the same trimming already applied to that field; case variants and other near-matches are refused rather than silently canonicalized. Structural shape validation still runs first, and vendor validation runs immediately after it, before the email allowlist below. A vendor that is present and non-blank but not in the catalog returns HTTP 400 with code `INVALID_VENDOR` and message `Choose a supported CommonPlate dining location.` Enforcement applies only to new request creation: existing persisted requests are neither migrated nor rejected on read. iOS consumes the same shared catalog for its vendor picker; the website form remains free-text, with backend enforcement still applying to it.

The requester principal must be an allowed NYU address. Both alert signup and food-request creation use the same `src/allowedEmailDomains.ts` helper with the same exact allowlist, normalization, and refusal of lookalikes and unlisted subdomains described in section 9.1. The allowlist establishes eligibility only; participant email-code verification is what proves control of the mailbox. Existing requests created on other domains are unaffected — the allowlist gates creation only.

The participant gate runs before payload validation, so an unverified caller neither creates a request nor learns whether its payload would otherwise be accepted. The legacy `email` field is optional because the backend already has the verified requester principal; if supplied, it must exactly equal that normalized principal or the request is refused with `403 PARTICIPANT_PRINCIPAL_MISMATCH`. A missing `email` is valid, while a blank or wrongly typed supplied `email` remains a structural `400 INVALID_REQUEST` failure alongside other malformed fields. `POST /api/request` keeps its two-key `{error: {code, message}}` envelope.

Refusal precedes the daily abuse-control count, the write, the requester confirmation email, and helper-alert notification. The iOS Request Food form carries no editable email field and supplies no legacy `email` at all; it relies entirely on the verified participant authority established before the form is reached (section 3.1). A backend `INVALID_EMAIL` on this path would indicate a stale or mismatched authority rather than free-form input the form itself validates. The legacy website is instead temporarily non-actionable because it cannot establish participant authority (section 3.1); its email input placeholder remains `abc123@nyu.edu`.

Request creation now has an exact logical operation identity and durable ambiguity recovery (section 6.3). A caller that presents no operation identity still receives the pre-D1 non-idempotent behavior described above.

#### Requester text filtering (W4-U1.1)

Requester-authored text another participant can read is filtered authoritatively at `POST /api/request` by a deterministic, provider-free filter (`src/participantTextFilter.ts`); no participant text is sent to any external moderation provider, and Screenshot Assistance is not a moderation mechanism. The filtered values are exactly each active Meal item's `name` and `details` and `orderDetails`. Derived `food` is not independently filtered, and `vendor` is allowlisted rather than free text. The filter is a bounded, high-precision list, not a guarantee that all objectionable text is refused: phonetic respellings, reversed text, adjacent-word concatenation, masked ordinary profanity, and non-English lexicons are deliberately not covered.

Filtering applies only to a genuinely new create attempt: it runs after participant authority, exact-operation reconciliation (an exact replay is answered by reconciliation and is never re-filtered, section 6.3), and canonical validation, and strictly before the daily-limit read and every creation effect. A match returns `422 REQUEST_TEXT_NOT_ALLOWED` in the shared structured error envelope with the neutral message `Keep request details respectful and food-related.` The refusal is definitive and pre-mutation: no Request, no operation-ledger row, no quota use, no confirmation email, and no helper push or email. It never names the matched term, category, or field, and nothing about the match is logged.

iOS treats the refusal as a definitive non-create for a fresh transmission, and as a post-lookup refusal — never recovery proof — for an already-issued operation identity. The requester sees the same neutral copy as a section-level notice beneath the heading `What would you like?` above the Meal fields, shown only after a refusal, with the draft and Screenshot Assistance state preserved and no modal, sheet, or new retry control. The notice retires when any submitted authored value, or the participant authority it was answered under, changes.

### 6.1 Request → installation association

An iOS request-creation payload may carry the installation's existing `installationCredential`. A structurally malformed supplied credential is a structural failure: HTTP 400 `INVALID_REQUEST`, the same envelope as any other malformed payload. A structurally valid credential is used to establish or resolve installation identity through the existing installation-credential mechanism; only an opaque internal association is persisted on the Request, never the raw credential. This association is notification-routing metadata only — it is not authentication, not NYU participant identity, and not proof of a person. Reinstall creates a new installation and does not relink requests created by a prior installation; no email, APNs token, or other heuristic re-links them either. Request creation never depends on Apple notification permission or push-enabled state.

Association is best-effort against unexpected backend persistence failure: if establishing or persisting the association unexpectedly fails, request creation still proceeds and the request persists without an installation association. `installationId` is therefore optional persisted metadata; a downstream flow may not assume every iOS-created Request carries one, and its presence or absence carries no authentication or identity meaning.

### 6.2 Meal-swipe quantity requirement

V1 supports meal swipes only — no Dining Dollars, no other payment source. Every request shape `POST /api/request` accepts requires an integer meal-swipe quantity, minimum 1 and maximum 5; this applies identically to the canonical/iOS shape and to `legacyWebSchema`, and the backend does not create a helper-visible request from either shape without one. The backend is authoritative for this validation on every accepted shape; invalid, missing, fractional, or out-of-range values cannot create a request. On iOS, the requester selects the quantity from a bounded picker offering exactly 1, 2, 3, 4, or 5.

The quantity is persisted once as Request-owned truth and included in the privacy-safe helper request projection, which remains allowlisted. Helpers see it in the Active Requests list/card before opening Request Detail, in `RequestDetailView` before the Reserve action, in active-reservation presentation, and in `FulfillRequestView` order context after reservation — the same authoritative value throughout, sourced from the active claim's request rather than a stale pre-claim copy. The existing new-request helper email (text and HTML) and push alert carry the same authoritative quantity concisely (e.g. `Meal swipes: 2`), via the existing `sendNewRequestAlert()` and `buildHelperNewRequestPayload()` composition paths reused by both immediate creation and the W3-N3 eligibility sweep; W3-N3's eligibility, timing, deduplication, and tap-routing behavior is unchanged.

Because current database contents are disposable test data, no backward-compatibility, migration, fallback, default, or optional representation exists for pre-C1 Request documents, and no backend exception, default, or fallback quantity is introduced for any accepted request shape to avoid this requirement. Legacy website UI parity is deferred: the current legacy website form cannot supply the required quantity, so its submissions are rejected by the same backend validation as any other missing-field submission until later parity work supplies it; this is an accepted consequence, not a defect. CommonPlate does not process payments, reimburse participants, connect Grubhub accounts, or place the external order.

The `Meal swipes: N` presentation is technically correct but its user-facing meaning and visual hierarchy are a Week 4 deferral; Week 4 must not reopen this section's data semantics, backend behavior, validation rules, or notification content.

### 6.3 Durable request-create recovery (W3-D1)

One intentional request submission mints one exact logical create-operation identity, carried in the `x-commonplate-operation-id` header. Replay or reconciliation of that logical operation uses the same identity; payload similarity, timestamps, recency, and request-list matching are never identity. A genuinely new intentional submission mints a new identity even when its payload is identical, and remains subject to normal quota rules. A caller that presents no identity receives the ordinary non-idempotent behavior of section 6 above, unchanged.

**Backend idempotency.** The backend binds the operation to the requester participant. A minimal durable ledger (`RequestOperation`) — not a field on the Request document — records the operation identity, the owning participant, and a pointer to the created Request; the Request and its ledger row are created in one transaction, so the two writes can never diverge. A unique index on the operation identity is what makes "at most one Request per logical operation" true under real concurrency: a racing create for the same identity loses with a duplicate-key error and reconciles to the winner's already-decided outcome instead of writing a second Request. Sequential and concurrent replay of an already-created operation converge on the same authoritative Request and consume no additional daily quota. Cross-participant replay is refused generically (`403 OPERATION_UNAUTHORIZED`) with no detail about the other participant's request.

**Bounded recovery.** While the Request an operation created remains active/actionable under the accepted request lifecycle, the same operation identity reconciles to that Request. The ledger row survives the Request's own TTL cleanup, so once the Request is gone the operation resolves as terminal expired/unrecoverable (`410 OPERATION_EXPIRED`) rather than falling through to a fresh create — cleanup of the original Request can never make an expired operation identity reusable. An expired operation can never resurrect or create another Request; a later intentional request uses a fresh operation identity.

**iOS durable recovery.** Once transmission of a request-create operation may have begun, iOS durably persists the exact unresolved operation — participant-bound, and including the exact submitted request fields needed for replay — so it survives app/process termination. No raw participant credential is persisted in that record. While a write-uncertain operation remains unresolved, iOS blocks another logical create until authoritative reconciliation resolves it. Launch reconciliation reuses the exact persisted operation identity and payload.

**Authoritative outcomes.** First successful create answers `201`; replay/reconciliation of an already-created operation answers `200` with the same authoritative Request; a terminal expired/unrecoverable operation answers `410 OPERATION_EXPIRED`; a successfully received `400 INVALID_OPERATION_ID` is a definitive non-create; `403 OPERATION_UNAUTHORIZED` is a hard authorization outcome; every other pre-write rejection (`INVALID_VENDOR`, `PARTICIPANT_PRINCIPAL_MISMATCH`, `INVALID_REQUEST`, `REQUEST_LIMIT_REACHED`, rate limiting) is also definitive and retires the operation. `REQUEST_CREATION_FAILED` remains write-uncertain — it can follow a write attempt — and keeps the operation open/blocking rather than retiring it, as does transport loss, timeout, or an unreadable response.

**Architecture rationale.** The ledger is a separate, permanently retained collection rather than a field on the Request document because Request documents are TTL-deleted (`deleteAt`, section 2) once a request stops being active/actionable; storing the durable identity only there would silently free it for reuse the moment cleanup ran, which is the exact "cleanup makes an expired operation fresh again" defect this design forbids. Operation identity must remain non-reusable even after the Request it created is cleaned up. The ledger stores identity, owning participant, and a pointer to the created Request only — never request content — because this is a minimal recovery/idempotency primitive, not a request-history product, and must not be repurposed as one. The Request and its ledger row are created in one transaction, and the ledger's unique operation-identity index is the sole primitive behind "at most one Request per logical operation" under real concurrency. Ledger rows are retained permanently rather than on their own TTL: each row is a handful of bytes, and freeing them after some duration would eventually let the same resurrection defect resurface, only delayed. This permanent minimal-tombstone retention is the accepted V1 tradeoff; cleanup cannot be introduced for this ledger later unless another mechanism independently preserves the non-reusability of retired operation identities.

### 6.4 Exact request-create terminal reconciliation and Success→Home continuity (W4-D2)

D2 extends W3-D1's bounded recovery (section 6.3) so one issued request-create operation can always converge on at most one authoritative terminal outcome whenever its stable recovery identity remains readable, even when the detailed persisted request payload cannot be decoded. No heuristic, content matching, timestamp, recent-request lookup, or local clearing may establish that outcome.

**Stable recovery identity.** The durable pending-operation record carries a recovery identity — the exact operation ID, the non-secret participant-identifier segment, an explicit recovery-envelope version, and a stable backend/environment authority identity — that is independently decodable from the evolving detailed request payload. A payload decode failure can never prevent identity recovery. Pre-D2 records (pre-R4 legacy and R4 current shapes) remain recoverable to at least operation ID and participant identifier; they carry no recorded authority identity.

**Exact-operation terminal authority.** Backend authority, bound to one exact operation ID and resolved only after participant authority, atomically does exactly one of: returns the existing created outcome; preserves terminal expired/non-resurrection (`410 OPERATION_EXPIRED`); refuses unauthorized cross-participant access generically; or durably establishes terminal **NO-CREATE** for that exact operation when no create has won. An absent ledger row is never terminal authority by itself. Terminal no-create occupies the same unique operation-identity authority as a created operation, so a racing or later-arriving original create for that identity cannot commit a Request once terminalization has won. A terminalized operation is permanent: every later replay, reconciliation, or terminalization of that identity returns the same terminal no-create outcome and can never create. Terminalization consumes no daily quota, sends no notification, creates no Request, and never reads, stores, or requires request content. The endpoint is side-effect free except for the terminal no-create write, and every outcome carries `Cache-Control: private, no-store` and `Vary: x-commonplate-participant`.

**Recovery classification.** During recovery, a response produced before exact ledger reconciliation is not proof the operation can no longer create: `RATE_LIMITED`, `PUBLIC_ACTIONS_PAUSED`, participant-authority refusals, route-level `404`, and post-`not-found` validation/quota codes (`INVALID_VENDOR`, `PARTICIPANT_PRINCIPAL_MISMATCH`, `INVALID_REQUEST`, `REQUEST_TEXT_NOT_ALLOWED`, `REQUEST_LIMIT_REACHED`) all keep the operation pending rather than retiring it. `INVALID_OPERATION_ID` and `OPERATION_UNAUTHORIZED` remain definitive. `OPERATION_EXPIRED` remains terminal. `REQUEST_CREATION_FAILED`, transport loss, timeout, and an unreadable response remain write-uncertain. Ordinary fresh-submission semantics (a single transmission of a freshly minted operation ID) are unchanged by any of this: a pre-write rejection still proves that attempt created nothing and still retires that record without arming the block. `REQUEST_TEXT_NOT_ALLOWED` (W4-U1.1, section 6, Requester text filtering) follows this same split: a definitive pre-write non-create for a single transmission of a freshly minted operation ID, and a post-lookup refusal that is never recovery proof for an already-issued identity. A recorded backend/environment authority that does not match the currently reachable authority, or a pre-D2 record with no recorded authority, is never sufficient to treat a `not-found`/`404`/no-create answer as terminal; unresolved state is preserved unless the recorded authority can be reconciled.

**User-visible recovery states.** `Posting request…` is the only initial in-progress presentation; there is no separate `Checking your request` screen. The **stable unresolved state** (reconciliation has finished at least once, or authority is mismatched, without reaching a terminal outcome, and none is actively in flight) shows `Your request may have posted` / `CommonPlate couldn't confirm whether your request posted.`, primary action `Check again` (exact-operation reconciliation only; never resubmits, never mints a new operation ID; while in flight the action label becomes `Checking…` and the requester stays on the same screen), secondary action `Go to Home` (navigation only, no mutation). **Exact recovery identity unavailable** shows `We can't safely confirm what happened to this request.` / `To prevent a duplicate, CommonPlate won't submit another request.` with no check/retry/clear action; normal navigation away remains possible. **Authoritative terminal NO-CREATE** always shows `Your request wasn't posted`: **Path A** (the frozen `CreateRequestPayload` is actually readable) adds `Your request details are still here. Return to your request to review them before submitting again.` and primary action `Return to request`, which restores the preserved information into the existing Request Food form without submitting, reconciling, or reusing the old operation ID — the next intentional Submit mints a fresh operation ID; **Path B** (the payload is genuinely unreadable — confirmed reachable when a stable identity is readable but its payload is not) adds `You'll need to enter the request details again.` and primary action `Start a new request`, which opens the ordinary empty form with no reconstruction, guessing, or content-matching. Both paths carry secondary action `Go to Home` and neither is offered before authoritative NO-CREATE. **Authoritative CREATED** preserves the existing successful posted flow. Neither unresolved state nor the NO-CREATE state receives a success/failure haptic. Remove Email stays blocked in both unresolved states, presenting `CommonPlate can't remove your email while a request tied to it is unresolved. This helps prevent a duplicate request.`

**Success→Home continuity.** After authoritative CREATED, the newly created requester-owned request card rises in on `Posting request…`, settles, shows `Request posted` (Success), and — during Home reveal — the same card visually continues into its first slot under `Your request(s)` rather than a Success card disappearing and a separately materialized Home card reappearing. Final Home-card layout width is fixed from first appearance and text does not reflow/resize/wrap differently during the transition. This holds for both zero-existing-request and multi-existing-request landings. Requester-owned Home ordering is newest-created-first; ASAP vs. Later does not reorder requester-owned requests; helper/discovery ordering is unchanged. Reduce Motion uses substantially reduced displacement/crossfade for this sequence; the existing single success haptic, concise VoiceOver announcement, and accepted timing/dwell (~1.6 seconds total) are preserved. This narrowly supersedes W4-R2's Success presentation and W4-H2/W4-H4's requester-owned ordering only; it does not reopen either slice's broader navigation, Timing, draft-lifetime, D1-ambiguity, Home information-architecture, continuous-scroll, refresh, or CTA-position contracts.

When a valid, fully visible real Home first-slot target is available, standard motion lands the continuity card into that measured slot (no guessed offsets, no duplicate-card/empty-slot artifact); Reduce Motion applies its existing bounded movement + crossfade to that same valid target. When no safe, usable real Home landing target can be captured (including an off-screen target), the continuity card does not travel toward a guessed position and Home is not force-scrolled: the continuity card stays spatially fixed and fades out while Home's real card for the exact created request fades in at its actual slot, as one coordinated crossfade during the existing landing window, with no hard retirement swap. This fallback applies regardless of motion preference and preserves the same final Home destination and the same ~1.6-second Success dwell.

**Exact-created-request Home continuity.** After authoritative request creation, if the ownership-resolved exact created request is already trusted in local/continuity/store state, that exact request may render in `Your request(s)` even while the broader Home request-list fetch remains `.loading` or `.unavailable`. This exception is scoped only to that one exact, ownership-resolved, authoritatively created request: it never fabricates, reuses, or exposes stale broader Home/requester/helper/discovery data, and the overall loading/unavailable board is never treated as populated merely because this one card is visible. It guarantees the Success→Home fallback above always has a real Home card to hand off to. When the broader authoritative Home fetch later resolves, normal reconciliation and requester ordering resume without duplicate cards or stale local-only persistence. This is a narrow local-authority continuity exception scoped to this one D2 flow, not a general Home cache policy, and does not reopen W4-H2's board-first architecture, ownership-partition mechanism, `Continue Helping` priority, or helper/discovery semantics.

**Engineering-owned** (provided the contract above holds): exact endpoint path/method, DTO names, status/code vocabulary for terminal no-create, ledger schema change, recovery-envelope layout/versioning, authority-identity derivation, and row-6 retry scheduling.

## 7. Daily request abuse control

CommonPlate attempts to limit each email to three requests per NYU/New York calendar day (`startOfCampusDay`, not the requesting process's local timezone). The backend counts before creating, serially in the handler; this is best-effort abuse control, not an atomic quota transaction. A failed count read fails closed. Concurrent create requests can exceed the limit. Atomic enforcement is deferred to Week 5 if usage requires it.

Ordinary Request Food presentation does not continuously advertise this limit. Only an actual `REQUEST_LIMIT_REACHED` refusal tells the requester to try again after midnight Eastern/New York time.

### 7.1 Participant-authorized request-creation eligibility read (W4-Q1)

`GET /api/participant/request-eligibility` lets the currently verified participant authoritatively read whether they are presently eligible to attempt another request under the daily abuse-control quota above. The principal is derived only from `resolveParticipantAuthority`, never from a caller-supplied email, participant ID, installation ID, Subscriber identity, or request-list identity; authority resolution happens before any count, exactly as it does for `POST /api/request`.

The read shares its substantive quota authority with `POST /api/request` (`src/requestDailyQuota.ts`): the same exact-principal `Request.countDocuments` basis, the same `startOfCampusDay`/`America/New_York` campus-day boundary, and the same three-request threshold. Neither the read nor its extraction changes create's existing principal, count filter, threshold, serial best-effort behavior, count-failure handling, D1 replay ordering, or write path; the quota remains the best-effort, non-atomic abuse control described above, and concurrent creates can still exceed it.

The successful response exposes only the accepted binary product state — `{ "eligibility": "eligible" }` or `{ "eligibility": "exhausted" }` — with no count used, count remaining, reset timestamp, quota-dashboard data, email, participant ID, credential, or request content. A count/database failure answers unavailable/error and never fabricates either successful result.

The result is advisory and current only as of that read. It is not a reservation of quota and does not guarantee that a later `POST /api/request` will pass validation, pause/configuration, rate-limiting, D1, database, or then-current quota checks; another request or race may change state after an `eligible` answer. `POST /api/request` remains the sole authoritative create-time quota enforcement.

The read is side-effect free — it performs no Request, RequestOperation, participant, notification, subscription, or installation mutation — and uses its own read-sized rate-limit bucket rather than consuming `POST /api/request`'s create allowance. The response carries `Cache-Control: private, no-store` and `Vary: x-commonplate-participant` on every outcome, including a mounted rate-limited refusal, so one participant's answer can never be cached or reused for another or for an unverified caller.

On iOS, `RequestService` owns the participant-authorized read and strict DTO decoding; `RequestStore.resolveRequestCreationEligibility()` owns the current authority-scoped load and its stale-response fence, mirroring `resolveStaleParticipationEligibility`. Missing authority, transport/server/decoding failure, cancellation, a stale/superseded-identity result, or an unmapped server refusal all resolve to unknown and are never coerced to eligible; a current `PARTICIPANT_AUTHORITY_INVALID` refusal feeds the same participant-authority-retirement lifecycle every other participant-gated store method already uses. No Q1 result is persisted or reused as durable quota truth.

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

### 8.4 Reservation warning

At five minutes remaining before an active reservation's backend-authoritative `claimExpiresAt`, CommonPlate warns once. While the app scene is active and visible, the in-app reservation warning owns presentation and the request-keyed local notification is canceled, so there is no duplicate system warning. While inactive or backgrounded, the local notification owns presentation. If an already-visible in-app warning loses active-scene ownership, CommonPlate retires that in-app warning and restores the local-notification path immediately; active re-entry reconciles back to truthful in-app ownership.

The local notification title is `"5 minutes remain"`. Its stable identity is derived from the request id, so scheduling, extension rescheduling, cancellation, and relaunch reconciliation affect the same reservation warning without touching other notification kinds. Warnings are rescheduled after a successful extension and canceled when the reservation ends through release, fulfillment, expiry, or authoritative continuation absence.

A reservation-warning tap is routing context, not authority. It routes only after current continuation truth confirms the matching active reservation. A stale warning for reservation A cannot route to newer reservation B. A terminated-app tap can cold-launch CommonPlate, restore the matching reservation through participant authority, and route to it; unknown continuation truth produces temporary-unavailability recovery rather than fabricating absence or a reservation.

### 8.5 Later eligibility notification dispatch

Helper notification initiation follows the event a request becomes helper-eligible, not the event it was created. For an ASAP request, creation and helper eligibility are the same event, so ASAP creation-time behavior is unchanged. For a future Later request, no helper email or helper push initiation occurs before its authoritative `visibleFrom`; when `visibleFrom` arrives and the request becomes effectively helper-eligible, it enters the existing helper-notification lifecycle on the next eligibility sweep.

Notification discovery is not bounded by `createdAt`: an older request is not permanently omitted merely because its creation predates an ordinary lookback, and a still-eligible request remains recoverable after a missed or interrupted sweep. Email and push remain independent, and existing per-recipient (`SendLog`) and per-installation (`PushDelivery`) deduplication remain the sole duplicate-send guards. Existing pause, effective-availability, recipient-eligibility, provider classification/no-retry behavior, payload contracts, and helper push tap routing are unchanged by eligibility-time dispatch.

A pre-existing future Later request created before this behavior existed, once identifiable as having eligibility after creation, is transition-compatible with the eligibility sweep rather than permanently unreachable.

Provider acceptance for eligibility-time dispatch carries the same meaning as elsewhere in this section: submission only, never delivery, reading, or pickup. A real future Later request has been observed end to end: no helper email or push initiation before `visibleFrom`, and eligibility-time initiation — confirmed email submission and physical APNs delivery to an intended installation — after it. That observation establishes correct no-early-dispatch and first-eligible-sweep timing on the observed request; it does not by itself establish that an old-`createdAt` request survives the former lookback omission, which is separately established by real-Mongo integration coverage (`docs/testing.md`).

### 8.6 Push enable/disable management truth (W3-N2)

Email and push remain independent channels: changing one never automatically creates, confirms, enables, disables, or rewrites the other, and participant verification never creates or confirms a Subscriber or changes push state (section 3.1).

Stable Push **On** requires all three of: Apple notification authorization permitting delivery, a current APNs token, and authoritative backend Installation synchronization confirming `enabled: true`. iOS does not present On before that complete sequence completes.

Stable Push **Off** requires the same authoritative backend-confirmed `enabled: false`; iOS never optimistically flips to Off before that confirmation.

For a synchronization request whose backend result is ambiguous, iOS presents neither stable On nor stable Off. The unresolved desired enable/disable state is persisted and survives relaunch. Authorization refresh and relaunch do not automatically retry the ambiguous mutation, so relaunch cannot silently reverse the unresolved user choice. An explicit retry reasserts only the same declarative desired state through the existing synchronization contract; it cannot make relaunch or backend reconciliation choose the opposite state.

Apple permission truth remains distinct from CommonPlate backend Installation state: denied or revoked Apple permission may be presented as Needs Permission, while a backend reconciliation failure is never mislabeled as an Apple permission failure.

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

**Confirmation-email provider-submission failure (W3-N2).** A confirmation-email provider-submission failure is operational/internal truth, not public Subscriber-lifecycle truth. The public response is the same generic accepted `202` above rather than a distinct status or code; it makes no claim that a confirmation email was submitted, delivered, or received. Existing lifecycle cleanup/rollback (section 9.3), send-lease handling, and sanitized internal logging remain unchanged and still run before the response is sent. `CONFIRMATION_EMAIL_UNAVAILABLE` is retired as public runtime behavior; invalid NYU email, malformed input, rate limiting, and public-action pause retain their existing distinct error behavior because none of those reveal Subscriber lifecycle state. A user who does not receive a confirmation email may explicitly retry signup.

**Accepted V1 response-timing limitation.** An already-confirmed address requires no confirmation-email provider submission, while a pending address may wait on that provider during signup, so response timing may differ between these cases even though response content and status do not. Faith has explicitly accepted this timing side channel as a known V1 limitation. Timing equalization — artificial delays, unnecessary provider calls for confirmed addresses, or asynchronous architecture solely for timing parity — is not current behavior and is not required for V1 acceptance.

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

### 9.8 Participant-authorized email unsubscribe (W3-N2)

`POST /api/participant/email-alerts/unsubscribe` authorizes one explicit in-app "Turn off email alerts" operation, gated by the same participant-authority mechanism as request creation and claim (section 3.1). The route accepts no body: it never takes a caller-supplied email or Subscriber ID, and the only address ever acted on is the exact normalized address `resolveParticipantAuthority` resolves the caller's credential to.

Participant identity, Subscriber identity, and Push Installation identity remain distinct (section 3.1). This route does not create, read, or otherwise touch Subscriber state beyond the one declarative mutation below, and no Participant ID is ever persisted onto a Subscriber.

The operation is one unconditional atomic update matched by the resolved email, not a read-then-branch, so absent, pending, confirmed, and already-unsubscribed Subscriber cases are indistinguishable to the caller: all converge externally to the same result, `{ "email": { "unsubscribed": true } }`. An absent Subscriber performs the update against zero matching documents and still reports the same result, because there is nothing to turn off and the declarative result is already true.

The mutation sets `status: "unsubscribed"`, writes `unsubscribedAt` only if not already set (`$ifNull`), and clears the same confirmation-credential fields the existing emailed-link unsubscribe clears (section 9.7) — the active `confirmationTokenDigest`/`confirmationExpiresAt`, confirmation send-attempt ownership/lease fields, the legacy raw `confirmToken`/`unsubToken`, and the bounded confirmation receipt. It does not touch `unsubscribeCredentialVersion`: unsubscribing is not credential revocation, and an already-emailed unsubscribe link must keep working afterward.

This is declarative and idempotent, matching `PUT /api/installations/push`: a repeated call, a retry after a dropped response, or concurrent calls from two devices holding the same participant credential all converge on the same result with no special-casing. It is rate-limited in its own bucket, matching the installation-push and claim mutation buckets, so it cannot spend, or be spent by, another public action's allowance, and it is registered ahead of the global body parsers and behind `PUBLIC_ACTIONS_PAUSED` like the other participant-gated routes.

Existing signed emailed unsubscribe credentials and browser GET/POST unsubscribe behavior (section 9.7) remain fully supported and unchanged; this route is an additional path for the browser-only, no-current-credential, reinstall, and already-delivered-link cases participant authority can reach that an emailed link cannot.

### 9.9 iOS email-alert state truth (W3-N2)

iOS may present Email Alerts Off only after the backend confirms the declarative result of section 9.8. That local Off presentation is not a durable Subscriber-status cache and cannot itself establish a future On state: iOS still cannot infer Email Alerts On from a generic signup `202`, signup presentation history, participant credential possession, or prior confirmation (section 9.1). A later signup or reconfirmation attempt returns to the existing `Check your email` presentation rather than continuing to show a stale Off.

### 9.10 Participant-authorized Email Request Alert state read (W4-N0)

`GET /api/participant/email-alerts/state` lets a verified participant authoritatively read whether their CURRENT verified NYU email presently has active Email Request Alerts. Gated by the same participant-authority mechanism as section 9.8: the principal is derived only from `resolveParticipantAuthority`, never from a caller-supplied email, query parameter, or body field, so no arbitrary-address lookup is possible.

The response is minimal privacy-safe truth only — `{ "email": { "active": boolean } }` — with no Subscriber id, credential, or other lifecycle field. `active` is `true` exactly when the resolved principal has a Subscriber row with `status: "confirmed"` (section 9); absent, `pending`, and `unsubscribed` all read `false`. This is deliberately narrower than real-time alert/digest send eligibility (section 8.1), which additionally requires `bounced: false`: N0 reports Subscriber lifecycle On/Off only and does not represent bounce or other provider-delivery state. A read that cannot establish current truth — an unauthorized, unavailable, or failed lookup — never reports `false` as a substitute for unknown; the caller must treat it as unresolved rather than as confirmed Off.

The read is side-effect free: it performs no signup, confirmation, unsubscribe, or other Subscriber mutation, and changes no Push, provider, or delivery behavior. The response carries `Cache-Control: private, no-store` and `Vary: x-commonplate-participant`, matching the existing caller-specific isolation on `GET /api/requests`, so a result for one participant credential is never cached or reused for another or for no credential at all. A result or an authority-invalid rejection resolved under a participant authority that a later Change Email has since replaced cannot become truth for, or retire, the replacement credential — only the still-current credential's own outcome is applied, mirroring the existing W3-I1 stale-response fence.

Existing signup, confirmation, unsubscribe (sections 9.1–9.8), Push (section 8.6), and local `Check your email` presentation-history semantics (section 9.9) are unchanged by this read; the local presentation history remains non-authoritative and is never treated as N0 truth.

## 10. Public-actions pause and scheduled jobs

`PUBLIC_ACTIONS_PAUSED` fails closed unless explicitly set to `false` or `0`. It blocks public request creation, subscription signup, both halves of the browser confirmation flow (section 9.5), both halves of the unsubscribe flow (section 9.7), claim, claim-extension, and release mutations, real-time helper alerts, and hourly subscriber digests. The API mutations answer a paused request in JSON through `pausePublicAction`; the confirmation and unsubscribe routes answer in HTML through `pauseConfirmationPage` and `pauseUnsubscribePage`. It does not block fulfillment: a valid active claim token or reservation-scoped continuation authority is already authorization to record an order, and blocking that path could strand a helper who has already placed one. It also does not block participant Block, Unblock, or Blocked Students management, which are safety controls (section 5.3); the one pause-governed part is the reservation release inside a helper's `No, not yet` Block, which commits neither the Block nor the release while paused.

The same variable is the activation switch for the unsubscribe signing secret: unpausing is what makes that secret a startup requirement (section 9.6).

`CRON_ENABLED=true` controls only the hourly expired-request cleanup backup to TTL deletion. The hourly digest, daily confirmed-subscriber `dailyCount` reset, and ten-minute SendLog failure monitor are registered independently of `CRON_ENABLED`; the digest additionally exits when public actions are paused.

Notification-management correctness (W3-N2, sections 8.6 and 9.8–9.9) does not itself change this pause boundary or authorize production/TestFlight unpause. Deployed secrets/provider configuration, signed build environment, and provider proof remain separate release gates (section 11).

## 11. Durable deferrals that constrain current behavior

- An application-level provider-wide send-volume ceiling for real-time helper-alert email. None exists today; a provider quota or rate-limit refusal is handled through the existing per-subscriber `SendLog` failure path rather than by pre-emptively skipping subscribers. Revisit during Week 5 production email configuration, and only if actual provider rate or quota evidence requires one.
- Cleanup of expired pending Subscribers; they stay notification-ineligible, so the current consequence is storage growth.
- Physical cleanup of expired confirmation receipts (`lastConfirmedTokenDigest`, `lastConfirmedTokenExpiresAt`) on rows that stay confirmed. Unsubscribing now clears the receipt outright, and the expiry comparison already prevents recognition after the original window, so the remaining consequence is stored data, not behaviour.
- Provider timeouts outside the confirmation email, and durable email-outcome persistence. Only `sendSubscriptionConfirmationEmail` currently carries an abort deadline.
- Browser rendering of the shared structured error envelope on the signup form, which must land before signup is unpaused.
- Paid-but-unrecorded recovery beyond the in-memory, one-resend fulfillment safeguard.
- Physical-device and release backend configuration.
- Full privacy and accessibility review.
- Release/Archive/TestFlight `aps-environment` signing and build-configuration alignment. Debug and simulator alignment is proven; a signed Release/Archive/TestFlight build has not been verified. This, along with release backend/APNs reachability and configuration and the remaining activation/unpausing decisions in section 10, gates distribution — see section 1. Physical-device push proof for helper new-request routing (section 8.3) and requester-fulfillment push (section 8.2) has passed on a development device, but that is not evidence about a signed Release build.
- W4-S3 (section 15) ships with ZERO qualified local providers. Apple local-provider evaluation, qualification, and production enablement, multi-screenshot accuracy/consistency, and the mixed manual/AI meal and post-edit provenance presentation questions are not settled and are owned by W4-S2 (weekly spec). Checkout/review input is accepted Requester behavior as of W4-R4.1 (section 14.8) and is no longer an S2-owned deferral. The S3 physical-iPhone smoke used a temporary development LAN backend configuration; it does not establish Release/TestFlight endpoint behavior or local-model quality.
- Participant-blocking surfaces owned elsewhere (section 5.3): the requester → helper Block entry and any placed-order continuation presentation (W4-R3), requester-facing resolution of a post-Yes stopped request (R3 or a later slice with explicit product authority), Report and its follow-up with Block (W4-U1.2, not carded), Block continuity across completed account deletion and same-email recreation (W4-P2), final trust/privacy/support presentation and any order-support destination (W4-T1), and retirement of the legacy Active Requests destination and its foreground-warning routing (W4-R5). U1.3 verification limits are in `docs/testing.md`.
- W3-D1 (section 6.3) integrated physical-iPhone runtime scenarios — commit/terminate/relaunch/reconcile, terminal-expiry non-resurrection, and a fresh operation after expiry — were not executed before acceptance. Faith explicitly accepted W3-D1 with this remaining limitation (`docs/testing.md`). Automated/simulator/backend evidence for D1 does not establish real physical-device process termination, relaunch sequencing, or network-interruption convergence at the post-commit boundary.

## 12. AI screenshot proposal (W4-S1)

Screenshot assistance is an optional, non-authoritative aid to the existing Request Food form. Manual entry remains fully usable whether or not AI is used, is On, or produces useful output. `POST /api/request/screenshot-proposal` is a distinct route, DTO, and response vocabulary from request creation: it can never call `createRequest`, mint or consume an `x-commonplate-operation-id`, create or update a `RequestOperation`/`Request`, consume daily request quota, send a requester/helper notification, or enter D1 ambiguity recovery. Only the requester's later, existing, explicit Submit action can construct `CreateRequestPayload` and enter `RequestStore.createRequest(...)`; AI has zero Request/D1/submission authority. iOS admits at most one active `PhotosPicker` screenshot selection at a time.

**Eligibility is accident prevention, not authenticity verification.** The deterministic gate (`evaluateEligibility` in `src/screenshotEligibility.ts`) only guarantees that the selected image sufficiently resembles a supported category for CommonPlate to attempt optional extraction; it never claims or implies that Grubhub genuinely produced the image or that OCR proves origin. The Requester eligible categories are exactly three (the third added by W4-R4.1, section 14.8): a Grubhub cart/bag screenshot; a detailed historical/past Grubhub order screenshot satisfying strict H5 — legible image, exact `View order` title, `Order information` heading, and a quantity-prefixed item line; and a Grubhub checkout/review screenshot as defined in section 14.8. Orders list/index, confirmation/tracking, receipt/payment-only, item-detail, menu/browse, and other Grubhub screens remain unsupported independent inputs; a receipt/payment sheet by itself remains unsupported. The cart/bag rule excludes checkout-context phrasing (`review your delivery order`, `place your delivery order`, `place your pickup order`, and their pickup equivalents) so a checkout screen is classified as checkout/review (section 14.8) rather than satisfying the cart rule merely by containing a cart phrase as a substring. H5's quantity-prefix requirement is not relaxed to improve OCR recall: a genuinely supported historical-order screenshot may be rejected when on-device OCR fails to recognize H5-required evidence. This is an accepted V1 limitation, not an implementation defect, because manual entry remains available.

A compound screenshot (unsupported foreground UI — a modal, popup, receipt, or payment surface — visible alongside a supported category) may be eligible when the visible supported evidence independently satisfies its own deterministic category rule; unsupported foreground UI neither automatically disqualifies nor independently qualifies a screenshot. Eligibility, and the independent meal-swipe corroboration signal, are evaluated only against `localEvidenceText` — on-device Apple Vision OCR text produced and sent by iOS before the provider is ever called — never against anything the OpenAI provider itself returns; validating a provider's claim against evidence the same provider produced is not independent corroboration.

**Proposal allowlist and partial proposals.** Eligibility does not require a complete proposal. AI may propose only location, literal food, and meal swipes; timing, preferred pickup time, and pickup name remain manual in all cases regardless of what the `RequestFoodFormDraft` seams could technically hold. Zero safely proposed fields is "no useful extraction," not successful prefill. Location is proposed only when independent OCR evidence resolves unambiguously to exactly one current `shared/vendors.json` entry; older/generic or historical venue text that cannot be resolved to exactly one current entry (e.g. against the two current distinct Upstein entries) omits the location proposal rather than guessing. A proposed `mealSwipes` value survives only when it is an integer `1`–`5` and the literal `1M`-style marker count in the independent OCR evidence matches it exactly; a mismatch drops the value rather than coercing it. A bare, unlabeled yes/no modifier value is sanitized/discarded; a genuinely labeled value (e.g. "No Side," "No Bag," "Yes Bag") is unaffected. Sections 14 and 14.8 extend this allowlist (structured Meal items, the deterministic Dining Dollars estimate, and the deterministic menu path) and narrowly supersede the literal-marker-only rule for `mealSwipes` with the bounded top-level-meal inference in section 14.8; provider output remains unable to supply the menu path or any money value.

**Adversarial and schema safety.** Raw provider output is never proposal authority by itself. Presence of any forbidden field (`pickupName`, `timing`, `preferredPickupTime`, `action`, `submit`, `reasoning`, `explanation`) refuses the output before schema parsing even runs, independent of whether the rest of the shape is otherwise valid. All remaining output passes a `.strict()` schema before any of it can populate a `RequestFoodFormDraft` seam. Prompt-injection or schema-escape attempts embedded in image text cannot reach the final proposal, the UI, logs, or any persisted state.

**Manual precedence and generations.** Manual requester edits always outrank an AI-proposed value for the same field. Replacing the selected image clears only fields still holding a still-AI-proposed value from the prior generation; a manually-edited field is never reverted or overwritten by a new generation. A stale, replaced, or disabled analysis can never mutate the current draft state.

**Data handling.** CommonPlate deliberately persists no raw screenshot, no OCR output, and no provider request/response content; only content-free operational analytics (success/failure/latency classification, never extracted values or image data) may be recorded, and any in-memory/temporary artifact used during a single proposal request does not survive past that request's completion or failure. Provider direction is the OpenAI API; standard OpenAI API retention is the accepted V1 boundary — CommonPlate does not claim Zero Data Retention or Modified Abuse Monitoring. **W4-S3 consent authority (section 15):** the single app-level Screenshot Assistance control is the sole authority for both local and external Screenshot Assistance processing. A screenshot may be transferred to the provider only while valid Screenshot Assistance consent exists, established by an explicit `Turn On` on the Off → On disclosure and bound to the Screenshot Assistance purpose, OpenAI, and the selected screenshot images. There is no first-use third-party disclosure before screenshot selection and no per-attempt external-AI prompt. Off revokes the consent, prevents any local or external processing and any new provider transfer, and retires pending attempts.

## 13. Requester journey integration (W4-R2)

R2 delivers the authoritative requester loop: Home → `Request a Meal` → existing verification when needed → pushed `Request Food` → manual or optional Screenshot Assistance draft/review → explicit Post → Posting → authoritative Success, definitive failure, or D1 ambiguity → authoritative Home re-entry.

**Navigation.** Request Food is a pushed subordinate destination on `ContentView`'s existing root `NavigationStack` (analogous to Settings), not a sheet and not a nested local `NavigationStack`. It uses ordinary stack Back navigation. Entry-verification sequencing, mounted-draft preservation, `RequestStore`/D1 authority, and authoritative successful re-entry to Home (section 3.1, section 6.3) are unchanged.

**Early request-creation eligibility boundary.** R2 consumes W4-Q1's authoritative read (section 7.1) only after verified participant authority exists. For an already-verified identity, `Request a Meal` performs an authoritative Q1 read before the form is exposed; eligible continues to Request Food, exhausted surfaces the limit before form investment. For an identity not yet verified, verification precedes the Q1 read; cancellation or unsuccessful verification never queries Q1. Missing authority, error, cancellation, or unknown/stale Q1 state is never treated as eligible. An eligibility read that cannot resolve presents a retryable state — title `Requesting is temporarily unavailable`, body `Try again in a moment.`, and a `Try Again` action that performs a fresh Q1 read — distinct from the unchanged, non-retryable exhausted state (`Daily request limit reached. Try again after midnight Eastern Time.`). Final `POST /api/request` quota enforcement (section 7) remains the sole authoritative create-time check; R2 owns only this early boundary/presentation.

**Draft lifetime.** An unfinished Request Food draft survives ordinary departure from the pushed route and background/foreground transitions for the current app process/session — a bounded in-memory lifetime, not durable cross-launch persistence. Returning Home and reopening `Request a Meal` restores the same draft: dining location, order details, meal swipes, pickup name, ASAP/Later state, chosen Later time, valid AI-proposed values, and manual edits made after those proposals. Manual values continue to outrank AI; stale or replaced analysis can never overwrite the restored draft; AI retains zero Request/D1/submission authority (section 12). Successful authoritative request creation clears the completed draft.

**Timing.** ASAP/Later selection preserves all existing timing authority (section 2.1). With ASAP selected, no secondary time selector is shown, and Timing states the three-hour expiration once. With Later selected, a row of nearby valid quick-time choices plus `Choose time` is shown; `Choose time` opens the native iOS time-selection control, and an exact chosen time becomes the active Later value, replacing the `Choose time` label in place. `America/New_York`, existing Later bounds/validation, and backend-derived three-hour availability (section 2.1) are unchanged.

**Screenshot Assistance completion acknowledgement.** After every successfully completed Screenshot Assistance analysis, a compact inline `✓ Screenshot checked` acknowledgement appears beneath the Screenshot Assistance area, alongside a `Change` action that reopens the picker to select and analyze another screenshot. No dynamic explanatory second line is shown, and no screenshot count is shown. This presentation is inline, compact, never modal or a toast, uses no success haptic, and the newest result replaces the previous acknowledgement in place. It communicates only that analysis completed, independent of whether any field changed, and does not alter manual precedence, S1's proposal-only authority, or the absence of AI auto-submit.

**Screenshot Assistance entry and the Off-state re-entry path (W4-S3 supersedes R2's first-use consent).** The pre-S3 first-use disclosure (`Use Screenshot Assistance?` / `Continue` / `Not now`) and its Decline-turns-Off behavior no longer exist; the only disclosure is the Off → On disclosure defined in section 15. While Screenshot Assistance is On, choosing a screenshot proceeds through Screenshot Help (if not yet completed on this installation) and the photo picker, then on-device routing, with no further disclosure or consent prompt; selecting and locally analyzing screenshots sends nothing off-device. When Screenshot Assistance is Off, Request Food shows a discoverable `Screenshot Assistance` / `Off` / `Turn on Screenshot Assistance` row; tapping it presents the section 15 disclosure, and only `Turn On` enables Screenshot Assistance and continues into the same Help/picker step. `Not Now` leaves it Off and establishes nothing. Toggling Off/On does not reset previously recorded Screenshot Help completion; enabled state and Help-completion state remain independent. The remote-transfer authority is the standing consent established by that disclosure (section 15).

**Screenshot Help.** `What should I screenshot?` opens a temporary local overlay over Request Food — never a permanent subpage or root destination — presented as a centered modal popup with Request Food dimmed behind it, sharing the disclosure's outer modal geometry, and showing cart and past-order examples. An enlarged example detail exposes a local Back only when it actually returns to the overview. `Got it` is the overall dismissal, returning to the exact same Request Food task and unfinished draft. Only approved production-design assets are used; no real screenshots, research fixtures, or other unapproved imagery may enter production assets or Git history.

**Submission, Posting, and outcomes.** Duplicate-submit protection, D1 ambiguity, and definitive-failure/draft-preservation behavior (sections 5, 6.3) are unchanged. Posting shows one native indeterminate `ProgressView` tinted CommonPlate purple. On authoritative creation, Success replaces it immediately with no delay, firing exactly one success haptic at that boundary, holding Success for approximately 1.6 seconds, then dismissing natively to authoritative Home re-entry. D1's unresolved-ambiguity state remains distinct from definitive failure and receives no success/failure haptic while unresolved.

**Home ownership presentation.** R2 forces no insertion, reordering, pulse, highlight, fade, or auto-scroll into Home; the returning requester relies entirely on H4's authoritative fetch and ownership presentation (section 1.4) to reflect a newly created request. Within the dedicated owned-request zone, `RequestCardView`'s `YOUR REQUEST` eyebrow is suppressed and preserved everywhere else (recorded in section 1.4). This is narrowly superseded by W4-D2's Success→Home continuity (section 6.4): a fresh create now inserts the exact created request immediately, ownership-resolved, as part of the accepted card-continuity handoff. R2's other Posting/Success/D1-ambiguity presentation, navigation, Timing, and draft-lifetime contract is otherwise unchanged.

## 14. Structured meal requests and multi-screenshot evidence (W4-R4)

R4 replaces the pre-R4 flat `food` + `pickupName` + meal-swipes-only request representation with a structured requester representation, and extends Screenshot Assistance (section 12) to jointly analyze up to five screenshots of one logical Grubhub order. Faith accepted W4-R4 on 2026-09-29 (weekly spec section 7).

### 14.1 Structured requester representation

Every accepted `POST /api/request` shape (the canonical/iOS shape and `legacyWebSchema` alike) now carries one of exactly two mutually exclusive menu paths, `menuPath`: `meal-exchange` or `dining-dollars` (wire values; `MEAL_EXCHANGE_PATH` / `DINING_DOLLARS_PATH` in `src/structuredRequest.ts`).

- `mealSwipes` remains the shared bounded integer field, now spanning 0–5: Meal Exchange requires 1–5 active meal swipes; Dining-Dollars-only requires exactly 0.
- `mealItems[]` carries exactly one active Meal item per active Meal Exchange swipe (never more, never fewer); each item's canonical fields are `name` (required, non-blank) and `details` (optional, non-blank when present). Dining-Dollars-only requests carry no meal items.
- `estimatedDiningDollarsCents` is an exact positive integer count of cents, never a float. On Meal Exchange it is an optional top-up estimate bounded at `$25.00` (2,500 cents); on Dining-Dollars-only it is a required whole-order estimate bounded at `$50.00` (5,000 cents).
- `orderDetails` is required, non-blank free text on Dining-Dollars-only requests and forbidden on Meal Exchange requests.
- `pickupName` is removed from the R4 structured requester contract. A payload that still carries `pickupName` is refused with the same generic structural failure as any other malformed payload (`src/createRequestRoute.test.ts`).
- The persisted single-line `food` field is retained only as a backend-derived compatibility summary (`deriveFoodSummary`), deterministically composed once at creation from the structured fields above. It is never client-authoritative, never an inference or default, and exists so already-accepted downstream projections, emails, push payloads, and digest lines (section 8) can keep rendering it without an R4-caused redesign; the structured fields themselves are projected alongside it for a later, separately routed H1 consumption sync.

An invalid combination for the chosen path (e.g. a Dining-Dollars-only request carrying meal entries, a Meal Exchange request with fewer meal entries than swipes, or an out-of-range estimate for the path chosen) is refused as a generic structural failure; nothing is defaulted, repaired, or coerced into the other path. Unrelated legacy compatibility behavior not actually changed by this contract (daily abuse control, installation association, W3-D1/W4-D2 recovery) is unchanged.

### 14.2 Requester UI behavior

Request Food lets the requester choose between Meal Exchange and Dining Dollars; a Dining-Dollars-only request is a fully supported request shape, not a degraded path. Required fields left empty remain visually neutral — no red/invalid treatment on an untouched or focus→blur-empty required field — while the incomplete state keeps `Post request` disabled; only a non-empty invalid value (e.g. an out-of-range Dining Dollars amount) may show field-specific validation feedback after blur. Switching between Meal Exchange and Dining Dollars clears branch-specific visible validation while preserving appropriate already-entered values; it does not otherwise reset the form. The Dining-Dollars ordering field is labeled `What are you ordering?` with example treatment `e.g. Chicken Wings`. A populated Meal summary is content-driven, and stored `Details` wraps fully without an ellipsis. The expanded Meal editor preserves the accepted editing semantics (no Cancel action, right-aligned `Optional` label, compact `Done` footer that collapses locally without a server save). `Post request` uses the accepted adaptive placement: bottom-anchored for a short form, flowing with content once the form grows past the viewport (e.g. Later expanded).

### 14.3 Screenshot Assistance (multi-screenshot evidence)

Screenshot Assistance remains optional and manual-first (section 12); R4 extends it to accept up to five screenshots representing one logical Grubhub order, jointly analyzed as evidence for that one order rather than as independent per-image proposals. Overlapping evidence across screenshots must not duplicate logical order content (e.g. the same item counted twice because it appears in two screenshots). A screenshot that is unsupported or ineligible under the existing deterministic gate (section 12) remains fail-closed independent of how many other screenshots in the same selection are eligible. Screenshot Assistance still never auto-submits, and requester-entered values remain authoritative over any screenshot-derived value.

**Manual authority and provenance.** Meal item (`name`) and Details are independent authority/provenance units, tracked per field rather than per Meal. A current non-empty manual value in either field is preserved on a later eligible rerun; clearing a field removes that field's manual protection, and a later valid reproposal may then fill it again. An untouched, still-screenshot-derived value remains eligible to be updated by a later eligible rerun. The requester-facing screenshot provenance label is `Suggested` (it replaced `Filled from screenshot` in W4-R4.1); it reflects only current screenshot provenance, never a permanent historical "was once suggested" marker, and `Manually selected` marks an explicit requester-owned value or path. The collapsed and expanded Meal UI both present exactly one Meal-level provenance badge, using OR semantics: the badge shows if the Meal item OR the Details field is still screenshot-derived. The badge means "Some content in this meal came from Screenshot Assistance," not that every field in that Meal is screenshot-derived; the underlying field-level provenance model is not collapsed by this single badge.

### 14.4 Rerun qualification and feedback

Only a successfully completed, eligible Screenshot Assistance analysis establishes completed-run state; an unsupported, ineligible, failed, cancelled, or nil outcome does not. The first eligible success on a given draft never shows rerun-only preserved-entry feedback. A later eligible success that preserves one or more requester-owned manual values may show exactly `Screenshot checked. Your existing entries were kept.` — and only that later-success case. This feedback is temporary, inline, non-blocking, and non-layout-reserving; it retires cleanly on view disappearance and on Screenshot Assistance disablement, and stale cleanup cannot clear newer feedback or leave the UI in a stranded feedback state.

### 14.5 Current-cart Dining Dollars proposal authority

Screenshot Assistance's Dining Dollars estimate is never provider (OpenAI) authority — it is populated only by a deterministic, independent OCR rule evaluated against on-device `localEvidenceText` (section 12), the same evidence-independence boundary S1 already established. Strong, explicit current-cart/order-level evidence (e.g. a literal `3M + $2.00` marker) may support a proposal of 3 meal swipes plus an estimated `$2.00`. An arbitrary item- or modifier-level `+$2.00` (e.g. a paid modifier) does not by itself establish a Dining Dollars proposal. Ambiguous evidence fails closed — no proposal — rather than guessing. Section 14.8 extends this authority to one deterministic order-level `Total` for the Dining-Dollars-only whole-order estimate on a current cart/review. A historical/past-order money proposal remains a deferral, not an accepted V1 behavior, if still current per the deferral ledger (section 11).

### 14.6 D2 boundary

W4-D2 (section 6.4) remains the sole request-create recovery/terminal authority. R4 introduces no competing terminal, recovery, or pending-operation semantics; R4's pending-operation compatibility work consumes D2's terminal-recovery authority rather than defining its own.

### 14.7 Deferrals

Hardware-keyboard Tab traversal into the mounted hidden Meal editor is deferred to W4-A1 and is not an R4 acceptance blocker (weekly spec section 7). A read-only latency diagnosis found that `RequestFoodDraftSession` ownership may cause requester draft mutations to invalidate `ContentView`/`HomeExchangeView` behind the pushed requester form; this was not established as an R4 cause and was not fixed in R4 — it is routed to W4-A1's existing cross-screen tint/content-column stabilization work, not absorbed into R4. Release/Archive/TestFlight signing and any provider environment beyond the observed Screenshot Assistance run remain outside R4's boundary and are owned elsewhere.

### 14.8 Screenshot-assisted menu path, checkout/review input, and path-conflict assistance (W4-R4.1)

R4.1 extends Requester Screenshot Assistance so independent on-device evidence can propose the menu path (`MEAL_EXCHANGE` or `DINING_DOLLARS`) and switch the form's selector. Faith accepted W4-R4.1 on 2026-10-07 (weekly spec). It narrowly supersedes: the two-category eligibility and the checkout/review exclusion in section 12; R4's requester-only `menuPath` and single shared Dining Dollars draft amount; the literal-`M`-only swipe-count rule; and section 14.5's top-up-only money authority. It retains S1's provider forbidden-field and independent-evidence rules, R2's draft/consent journey, R4's structured wire and other manual/provenance rules, and S3's shared runtime, consent, and qualification contract (section 15). Screenshot Assistance remains optional, proposal-only, and manual-first; it never auto-submits, and explicit `Post request` remains authoritative.

**Provider authority.** `menuPath` and `diningDollarsOrderTotalCents` stay in the forbidden provider-field list; a provider that returns either is refused before schema parsing. The proposed path and Total are CommonPlate-validated proposals derived only from independent on-device evidence, evaluated identically by the backend (`src/screenshotEligibility.ts`, `src/screenshotProposalValidation.ts`) and on device (`RequesterOrderDeterministicEvidence`, `RequesterOrderOutputValidator`), pinned by `shared/screenshot-conformance-vectors.json`. The proposal response carries an optional `menuPath` and `diningDollarsOrderTotalCents`; the iOS decoder treats an absent or unrecognized value as no proposal.

**Checkout/review eligibility.** The third category is a Grubhub checkout/review screenshot with the explicit heading `Review your pickup order` or `Review your delivery order` (the complete supported set; generic `Review your order` is not supported) plus order-specific content: either a `Your order` section containing a quantity-prefixed item line, or a `Your payment` section containing a `Payment method` summary row. The existing legibility minimum and strict H5 are unchanged. `Place your ... order` call-to-action text, generic checkout words, item count, prices, totals, or a cropped summary do not qualify on their own. A quantity-prefixed item counts only inside `Your order`; that scan stops at the first later `Your payment` heading whether it is valid, duplicated, or malformed, and a duplicate heading never reopens it. Payment attribution ends when structure leaves the bounded `Your payment` section (`Order confirmation`, `Receipt`, another top-level section); a valid later `Payment method` row uniquely inside that same section remains attributable, no numeric line-distance cutoff is used, and ambiguous or duplicate/conflicting payment structure fails closed. Intermediate controls such as `Apply a promo code` do not by themselves end the section. In a multi-image selection only individually eligible images contribute pixels and evidence. Eligibility remains accident prevention, not proof of authenticity.

**Deterministic path evidence.** The path is resolved only from independent evidence of eligible screenshots, never provider output or plausibility.
- *Meal Exchange:* explicit `Meal Exchange` wording in a provider venue/menu identity (such as `Crave NYU - Meal Exchange`); bounded literal `1M`–`5M` order-level subtotal/total notation that resolves without conflict; or a canonical selected meal-based payment such as `Use 1 Meal + Dining Dollars`, whose embedded `Dining Dollars` words never open a Dining Dollars path and which supplies no swipe count or amount. `3M + $2.00` is Meal Exchange with a possible top-up only when the existing top-up corroboration succeeds. Meal Exchange wording alone supplies no count or amount.
- *Dining Dollars, review:* a supported review whose single `Payment method` row inside bounded `Your payment` is uniquely associated with canonical `Dining Dollars`. The association is valid when the tender is immediate or inline, or when at most one non-authoritative observation intervenes between the row and the tender (that observation supplies zero authority) with no structural departure, no second `Payment method` row, and no duplicate or conflicting recognized tender. Two or more intervening observations, fuzzy or substring matching, restaurant or logo recognition, and incidental or alternative `Dining Dollars` text grant nothing. A payment-method signal establishes path only, never an amount.
- *Dining Dollars, current cart:* a supported current cart with no Meal Exchange identity, no order-level `M` notation, no conflicting Meal Exchange evidence, and one unambiguous dollar-denominated order-level `Total`. All conditions are required; dollar signs, item prices, or venue-name guesses alone establish nothing.
- *No evidence or conflict:* a selected Dining Dollars method together with Meal Exchange evidence, conflicting evidence across the logical selection, or no accepted signal omits the path proposal and preserves the requester's selection; branch-dependent values whose meaning needs the disputed path are omitted. Unresolved or out-of-range `M` notation alone establishes no path or count. Real Grubhub screenshots are structural exemplars only; restaurant identity is never authority.

**Order-level Total and bounded device-derived geometry.** One clearly labeled, unambiguous dollar `Total` on a supported current cart/review may populate the requester-editable Dining-Dollars-only whole-order estimate within the existing 1–5,000-cent bounds; an out-of-bounds Total is omitted, never clamped. Item prices, a subtotal alongside a distinct Total, tax, fees, discounts, promos, crossed-out prices, arbitrary amounts, and unrelated tender values are never Total authority, and a Total is never chosen because it is largest, last, arithmetically compatible, nearest by index, or within N lines. Conflicting final amounts, split-payment ambiguity, an unidentifiable Total, or Meal Exchange/Dining Dollars conflict omit the path and/or amount. Existing text-only Total association remains authoritative where it succeeds; otherwise Swift may derive a minimal same-image relation from transient Vision geometry: the Total is authoritative only when exactly one authoritative exact `Total` label exists, exactly one amount-only candidate is on the same row (at least 50% vertical overlap of the shorter box) and to the right of it, geometry is valid, there is no competing association, and classification, cents, and observation ownership are consistent. Raw Vision boxes stay transient on device and are never transmitted, persisted, logged, or fixtured. Only privacy-safe derived relation evidence (`localTotalGeometry`: per-image observation IDs, `total-label`/`amount` classification, parsed cents, geometry-valid flag, and same-row/right-of relation facts) accompanies `localEvidenceText`; cross-image edges are forbidden. The backend validates it against the same image's text evidence and fails closed on missing, malformed, duplicate, contradictory, or cross-image claims. It cannot re-derive raw geometry, and this narrow trust supplies no authority outside Screenshot Assistance proposal generation. A path-only result on a checkout/review is a useful proposal without a fabricated amount or food.

**Path authority and application.** A valid deterministic path is applied before branch-dependent fields, then only the active branch's field rules run. The untouched initial/default path is not requester authority: default Meal Exchange plus deterministic Dining Dollars evidence auto-switches to Dining Dollars, and a same-value re-select of the default stays non-manual. Manual path authority begins only when the requester actually changes the selected path; the first actual change makes the new path requester-owned (`Manually selected`) and a later actual change moves that authority. A provider or store write never creates manual authority.

**Path-conflict assistance.** When a requester-owned path conflicts with the opposite deterministic path for the current analyzed result, the path is preserved and neutral assistance appears between the field label/provenance and the current selector: `We found Dining Dollars` or `We found Meal Exchange`, with a compact filled `Switch` action and a distinct `×` dismiss control (44×44 hit target). The current path keeps `Manually selected` while the conflict is pending.
- `Switch` is explicit requester acceptance of only the proposed path: switch to it, remove the row, clear the superseded manual-path provenance, and apply valid path-specific screenshot values, shown as `Suggested`. It never auto-submits.
- `×` preserves the requester-owned path and its provenance, removes the row, and rejects the opposite-path recommendation for this analyzed result only; the same result never later silently switches the path, while a genuinely fresh or reanalyzed result may propose it again.
- Dismissal rejects the path recommendation, not all assistance: independently valid path-independent evidence (such as dining location or general order details) may remain. Rejected path-specific evidence is never reinterpreted for the retained path: a Dining Dollars Total never becomes Meal Exchange evidence, Dining-Dollars-only evidence never invents a swipe count or Meal 1 structure, and Meal-Exchange-only evidence never becomes a Dining Dollars amount.
- The row is neutral assistance (not warning, error, or destructive), uses existing semantic tokens, reflows with Dynamic Type, and adds no modal, toast, lock, or other copy. Stale or cancelled results never resurface a row.

**Branch state and amounts.** The draft keeps two in-memory amount values — the optional Meal Exchange top-up (1–2,500 cents) and the required Dining-Dollars-only whole-order amount (1–5,000 cents) — and the wire field `estimatedDiningDollarsCents` is derived only from the active branch. Switching, by requester or Screenshot Assistance, preserves the inactive amount and never copies, reinterprets, truncates, validates, or submits it. A current-cart top-up proposal fills only the Meal Exchange value; a labeled Total fills only the Dining-Dollars-only value. Shared dining location and timing stay shared; Meal Exchange keeps its bounded swipes and per-swipe Meal entries; Dining-Dollars-only keeps its own order-details text with zero submitted swipes and no Meal items; switching never clears inactive branch data, clears branch-specific visible validation and stale focus, and a newly active branch must satisfy its own validation before Post enables. Frozen D2 payload restoration reconstructs only the submitted branch.

**Meal-swipe count.** Literal `M` notation remains authoritative, and a returned count survives only when on-device evidence establishes it. When literal `M` notation is absent, the path resolves to Meal Exchange without conflict, and the validated top-level item list is not withheld by the overlap rule, a count `N` (2 ≤ N ≤ 5; `N = 1` is not proposed) is inferred only if every counted entry has quantity exactly 1, is independently grounded as a top-level OCR line in at least one eligible screenshot (modifier and bullet lines never ground an entry; one ungrounded entry disengages the whole inference), and no two counted entries share a normalized top-level name across multiple screenshots. Modifiers, add-ons, and extras never inflate the count, a count is never inferred from an arbitrary item count or from provider output alone, present-but-unresolved notation is never repaired, and the inference never feeds path resolution or unlocks a top-up estimate.

**Requester-owned meal-swipe mismatch.** When the requester owns `mealSwipes = M` and a successful eligible analysis deterministically establishes valid `N > M`, M is preserved and assistance appears above the swipe control (hierarchy: `Number of meal swipes` label with `Manually selected`, then the row, then the control): `We found N meals`, a filled `Use N swipes` action, and a distinct `×` (44×44). It is not shown for `N == M` or `N < M`. `Use N swipes` adopts N and the result's screenshot-derived higher-index Meal content, removes the row and `Manually selected`, shows `Suggested`, and never auto-submits. `×` keeps M and `Manually selected`, removes the row, and rejects only this result's surplus screenshot-derived Meal content above M; a later manual increase does not resurrect it, requester-owned content is never erased, and a genuinely new analysis may propose again. When assistance was previously accepted at a larger count and the requester later decreases the count, the lower count wins, the higher-index accepted content stays preserved in the draft and may be restored by increasing the count, inactive meals stay excluded from submission, and no warning is shown.

**Provenance.** Affected requester runtime surfaces use `Suggested` for an editable value proposed by Screenshot Assistance and `Manually selected` for an explicit requester-owned value or path; a later requester edit restores requester authority and removes screenshot provenance under the existing per-field rules. This terminology does not change any Helper surface.

**Privacy and trust.** Raw OCR, raw geometry, screenshots, and screenshot-derived diagnostics are never logged, persisted, or fixtured. Synthetic structural vectors stand in for real screenshots, and provider/model evaluation is not R4.1 proof.

## 15. Shared Screenshot Assistance runtime and local-first routing (W4-S3)

S3 replaces the requester-shaped Screenshot Assistance implementation with one shared, schema-neutral runtime plus workflow-specific adapters. Requester behavior in sections 12–14 is Requester workflow policy; it is not generalized to any future workflow, and S3 settles no Helper Screenshot Assistance policy (W4-H1 owns that).

**Shared runtime and adapters.** `ScreenshotAssistanceRuntime<Workflow: ScreenshotWorkflow>` owns provider routing, local capability/qualification enforcement, the attempt fence, the local-attempt deadline, and enforcement that no external transfer begins without a current, exactly bound, single-use runtime transfer permission, which exists only while valid Screenshot Assistance consent and the current attempt both hold (below). Its one input is the complete ORDERED screenshot selection (`ScreenshotSelection`, pixels); that ordered selection, not per-image calls, is the logical input. Preprocessing, Vision OCR, and other evidence derivation are private to the workflow/provider adapters and are not part of the shared contract. Eligibility, derived evidence, raw output shapes, validation, what an outcome may change, user-visible copy, and when an external attempt is offered belong to the workflow adapter and its consuming store. The Requester adapter (`RequesterOrderWorkflow`) and its providers live under `Services/ScreenshotAssistance/Requester/`. A test-only, non-shipping second-schema workflow proves the runtime is not requester-shaped; it creates no production qualification and is not reachable in production. `shared/screenshot-conformance-vectors.json` is a drift guard that the backend (`src/screenshotConformanceVectors.test.ts`) and the on-device validator (`ScreenshotConformanceVectorTests`) must both satisfy, so the fail-closed eligibility and validation rules cannot diverge; a vector changes only by deliberate edit reviewed against both suites.

**Local providers are qualification-gated and fail closed.** A local provider may run only for an exact qualification entry binding workflow (schema id, schema version, validator version), provider (id, prompt/model/provider-strategy version, shipping distribution), evidence/input strategy (`ocrFlattenedText`, `ocrLayoutAware`, `directImageMultimodal`), an explicit OS major.minor band, device model set, and a build-derived implementation fingerprint. Unknown or later OS bands, unknown devices, a changed fingerprint, and any unqualified combination behave as local-not-qualified. The production registry (`ScreenshotQualificationRegistry.production`, `Services/ScreenshotQualificationProduction.swift`) currently contains ZERO entries. Device/model availability, including Apple Intelligence or Foundation Models being available, never authorizes invocation: qualification is decided before a provider is asked anything, so an unqualified provider is not even asked for availability, and Foundation Models is not invoked without a matching entry. The Apple OCR→flattened-text Requester candidate remains NOT QUALIFIED; evaluation, qualification, and production enablement are W4-S2's. A non-shipping provider can be admitted only by an injected test registry, and nothing in the app target may construct one.

**Local failure never authorizes transfer; bounded local attempts.** Local unavailability, non-qualification, failure, timeout, or invalid output never authorizes external transfer by itself and leaves manual entry available. One local attempt has a finite deadline (20 seconds, engineering-owned, not derived from physical-device measurement; no production combination reaches it today). The orchestration returns control at the deadline, on provider completion, or on cancellation — whichever settles first, exactly once — without waiting for a non-cooperative provider; a late completion is stale and has no state effect. The abandoned provider computation is not terminated, and a provider that synchronously blocks the main actor cannot be pre-empted.

**Screenshot Assistance consent authority (Requester).** Screenshot Assistance has one app-level On/Off authority, surfaced in the H2 `SettingsView` route and in the Request Food Off-state row. There is no separate Requester/Helper toggle and no separate stored "enabled" state apart from consent: On exists only while a valid consent record exists, and Off holds none.

- **Off** means no local Screenshot Assistance AI processing, no external Screenshot Assistance AI processing, and no new external screenshot transfer. Manual Request Food flows remain fully available. `analyzeScreenshot` refuses while Off.
- **Off → On requires the disclosure first.** Attempting to turn Screenshot Assistance On — from Settings or from the Request Food Off-state row — presents a centered modal before enablement: title `Turn on Screenshot Assistance?`; body `Screenshot Assistance can help fill in details from screenshots you add to CommonPlate. Some screenshots may be sent to OpenAI to generate these suggestions.`; recovery line `You can turn Screenshot Assistance off anytime in Settings.`; actions `Turn On` and `Not Now`. The copy carries no on-device, model-routing, qualification, or fallback-architecture language, and mentions no OCR text, because the actual external transfer is the selected screenshot images only (on-device OCR evidence goes only to CommonPlate's own backend, section 12).
- **`Turn On`** enables Screenshot Assistance and establishes the valid external-transfer consent. From the Request Food row it then continues into the Help/picker step; from Settings it only enables. **`Not Now`** leaves Screenshot Assistance Off, establishes no consent, and persists nothing.
- **Standing consent.** While valid consent remains active, no per-attempt external-AI permission popup or other repeated prompt appears; qualified local processing (when one exists) and the accepted OpenAI fallback may both proceed under the standing consent.
- **On → Off** revokes the consent, blocks all future local and external Screenshot Assistance processing and any future external transfer, retires the current selection generation and fences any in-flight local or external attempt (a transfer already in flight cannot be recalled, but its result is never applied), and prevents stale results from applying. Turning Screenshot Assistance On again never revives a prior generation or inherits the revoked consent: it requires the disclosure and a fresh `Turn On`.
- **Consent binding.** The consent record is bound to exactly the Screenshot Assistance purpose, OpenAI as provider, and the selected screenshot images as the transferred data class. It is honored only while it equals the current binding; a materially different provider, purpose, or materially broader transferred-data contract cannot silently inherit it and requires a truthful new disclosure first.
- **Fail closed.** An absent, unreadable/corrupt, or mismatched consent record is Off. Legacy or default preference state — the pre-revision `isAIAssistanceEnabled` value, whether explicitly set or defaulted On, and the pre-S3 `thirdPartyConsentRecorded` value — is never read as consent and never creates it. No migration screen, notice, or legacy-compatibility path exists.

**External fallback under standing consent (Requester).** When an attempt is otherwise eligible, no qualified local provider produced the outcome (the production registry is empty today), and current participant authority exists, the store runs the one terminal external attempt automatically under the standing consent: no popup, no tap, and nothing but the selected screenshot images (plus the existing S1 local-evidence payload to CommonPlate's own route, section 12) is sent. Local unavailability, non-qualification, or failure alone never authorizes transfer; without standing consent no transfer occurs. The runtime still requires a current, exactly bound, single-use transfer permission minted for the exact attempt token and exact evaluation of that attempt, carried by a shared single-use flag (copies cannot mint a second transfer), consumed at the first validity check, and failing closed on any mismatch (another attempt, fence, runtime, or retired generation). That permission is an internal fencing guard, not a user decision; it is minted only while the attempt is current and Screenshot Assistance is On. A new or replaced selection, Screenshot Assistance turned Off, view departure or retirement, cancellation, loss of participant authority, a stale or superseded attempt, or an already consumed permission retires the pending attempt, and no later unauthorized transfer or result application can occur. Current participant authority is evaluated at the fallback decision and re-read inside the runtime synchronously immediately before the provider is invoked; if it is gone, there is no provider call and the permission is spent, and the ordinary local-outcome treatment is presented. If authority is lost while an admitted form remains mounted, local Screenshot Assistance may still run under normal qualification, external AI is not attempted, no Screenshot Assistance-owned verification prompt appears, and manual entry remains available. Defense-in-depth backend participant authorization on `POST /api/request/screenshot-proposal` is unchanged (section 12). The consent-authority revision made no backend route or contract change.

**Local privacy boundary and evidence.** Content-bearing artifacts used for local analysis — screenshots, normalized images, OCR text, prompts, proposal fields, and local-model inputs/outputs — do not leave the device by any route, are not persisted, and are never emitted to any analytics or observability service. Only an authorized external attempt sends the selected screenshots (and the existing S1 local-evidence payload, section 12) to the existing provider route. Optional evidence/provenance (`ScreenshotEvidenceSet`: per field key, one or more entries of screenshot index, exact source text, optional normalized region) is in-memory and attempt-scoped, returned beside a validated outcome, released with the attempt, not `Codable`, and unused by the Requester store and view; S3 introduces no user-visible evidence presentation.

**No shipping observability dependency.** The iOS app has no Datadog or other third-party observability package, SDK initialization, or Screenshot Assistance telemetry. The external-transfer boundary (no request after cancellation, retirement, a stale or replayed permission, or loss of participant authority; exactly one request for a valid authorized attempt) is enforced by the runtime and the networking layer themselves and is proved by transport request counts and store state. The W4-OBS1 observability slice was retired and is not part of the accepted runtime.

**Unchanged by S3.** Requester eligibility semantics, multi-screenshot/overlap behavior, manual precedence, deterministic validation, no auto-submit, stale-result fencing, and failure behavior are as in sections 12–14 except for the S3 consent/ordering/Settings supersession recorded above. The consent-authority revision also leaves unchanged local-first routing, empty-registry/qualification fail-closed behavior, the local-attempt deadline, the qualification fingerprint, requester manual authority, and the absence of auto-submit.

**Verification limits.** Faith's physical-iPhone walkthrough of the revised consent flow confirmed: the disclosure appears before enablement on an Off → enable attempt; `Not Now` leaves Screenshot Assistance Off; `Turn On` enables it; On → Off disables and revokes; and a later enable attempt shows the disclosure again. Manual Request Food remained available while Off. Source and unit tests prove consent, authority, fencing, and wiring but do not themselves prove SwiftUI presentation. A brief perceptible delay between tapping the enable control and the disclosure appearing was observed on device; consent sequencing was correct and nothing became enabled before the disclosure, so it is a presentation-responsiveness item routed to the weekly spec's Candidate Stabilization deferral, not an accepted-behavior defect. The earlier S3 physical-iPhone smoke (iPhone 16 Pro, iOS 26.3.1, Apple Intelligence On, Debug build against a temporary development LAN backend) observed the real `PhotosPicker` and preprocessing path, the empty-registry fallback path, and retirement without late application under the pre-revision consent model; it is retained only as evidence of the picker, preprocessing, and retirement boundaries, not of the consent behavior. Neither walkthrough establishes Apple local-model quality or qualification, Release/TestFlight signing or endpoint behavior, or production provider reachability (`docs/testing.md`; section 11).
