//
//  RequestDetailView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

/// Keys the W3-H2 stale-detail eligibility `.task` so SwiftUI cancels and
/// restarts the read whenever the request changes, or whenever the
/// authoritative participant identity changes (e.g. Change Email completing
/// while this screen is open) — a result resolved for a superseded identity
/// must never be applied to the replacement one. Not `private`: shared with
/// `RequestDetailView.renderedEligibility(resolved:currentKey:)` below and
/// exercised directly by focused tests, matching this file's existing
/// pattern of testable `static func` helpers (`opensClaimedFlow`,
/// `shouldDismiss`).
struct StaleParticipationTaskKey: Equatable {
    let requestID: String
    let identity: ParticipantIdentityPresentation?
}

/// A `StaleParticipationEligibility` result, bound to the exact
/// `(requestID, verified identity)` key it was resolved for. Storing the key
/// alongside the result — rather than the result alone — is what lets
/// rendering itself, not just the async read, refuse to honor a result that
/// belongs to a principal that is no longer current: the moment
/// `identityStore.identity` changes, `RequestDetailView` recomputes the
/// current key on its very next render and this stored result stops
/// matching it, synchronously and before the replacement identity's own
/// `.task` read has even had a chance to complete.
struct ResolvedStaleParticipation: Equatable {
    let key: StaleParticipationTaskKey
    let eligibility: RequestStore.StaleParticipationEligibility
}

/// How a claim attempt is presented to the helper. Backend codes are mapped
/// deliberately, with a fallback for anything unrecognized, per the error
/// contract in docs/system-contract.md. The stable code itself stays on
/// the request-scoped `RequestStore` event; only the copy lives here.
enum ClaimPresentationError: Equatable {
    /// HTTP 409 `REQUEST_ALREADY_CLAIMED`. Locked message.
    case alreadyClaimed
    /// Expired, out of claimable time, already placed, or missing — one calm
    /// "no longer available" register rather than four error states.
    case noLongerAvailable
    /// `REQUEST_NOT_YET_AVAILABLE`. Deliberately not folded into
    /// `noLongerAvailable`: a scheduled request that has not started yet is the
    /// opposite situation, and the helper can come back for this one.
    case notYetAvailable
    /// `PUBLIC_ACTIONS_PAUSED`.
    case publicActionsPaused
    /// `RATE_LIMITED`.
    case rateLimited
    /// The claim POST may have been applied server-side without iOS seeing the
    /// credentials. Never retried automatically.
    case ambiguous
    /// A claim on *this* request is already in flight for this helper.
    case operationInProgress
    /// A claim on a *different* request is in flight. Nothing has been started
    /// for this one and nothing is held yet — it is a short wait, not a
    /// commitment made elsewhere.
    case otherClaimInProgress
    /// A confirmed reservation on a different request is already held.
    case existingActiveClaim
    /// A confirmed placement result is still waiting to be acknowledged.
    case pendingPlacementAcknowledgement
    /// A definitive claim failure that does not have a more specific mapping.
    case couldNotStart

    var message: String {
        switch self {
        case .alreadyClaimed:
            // Locked race-conflict copy. Must match the backend's own message
            // for HTTP 409 REQUEST_ALREADY_CLAIMED exactly.
            return RequestDetailView.alreadyClaimedNotice
        case .noLongerAvailable:
            return RequestDetailView.noLongerAvailableNotice
        case .notYetAvailable:
            return RequestDetailView.notYetAvailableNotice
        case .publicActionsPaused:
            // Single source for the backend-confirmed helper-pause sentence.
            return RequestDetailView.helperPauseNotice
        case .rateLimited:
            return "Too many attempts. Please wait a moment and try again."
        case .ambiguous:
            return "We couldn’t confirm whether your reservation succeeded. Don’t place a Grubhub order. CommonPlate can’t recover this result in the current session, and the request may disappear from the public list until an unresolved reservation expires."
        case .operationInProgress:
            return "You’re already starting to help with this request."
        case .otherClaimInProgress:
            return RequestDetailView.otherClaimInProgressTitle
                + ". " + RequestDetailView.otherClaimInProgressNotice
        case .existingActiveClaim:
            return "You’re already helping with another request. Finish that one or wait for its reservation to end."
        case .pendingPlacementAcknowledgement:
            return RequestDetailView.pendingPlacementTitle
                + ". " + RequestDetailView.pendingPlacementNotice
        case .couldNotStart:
            return "We couldn’t start helping with this request. Please try again in a moment."
        }
    }

    static func map(_ error: Error) -> ClaimPresentationError {
        guard let serviceError = error as? RequestServiceError else {
            return .couldNotStart
        }

        switch serviceError {
        case .notFound:
            return .noLongerAvailable
        case .serverError(let code, _):
            switch code {
            case ClaimErrorCode.requestAlreadyClaimed:
                return .alreadyClaimed
            case ClaimErrorCode.requestExpired,
                 ClaimErrorCode.requestInsufficientTime,
                 ClaimErrorCode.requestAlreadyPlaced,
                 ClaimErrorCode.requestNotFound,
                 // W3-H2: a stale Reserve tap on a request this participant
                 // already successfully held once before. Reuses this exact
                 // presentation — no new copy — per the accepted
                 // marketplace-presentation contract.
                 ClaimErrorCode.requestAlreadyParticipated:
                return .noLongerAvailable
            case ClaimErrorCode.requestNotYetAvailable:
                return .notYetAvailable
            case ClaimErrorCode.publicActionsPaused:
                return .publicActionsPaused
            case ClaimErrorCode.rateLimited:
                return .rateLimited
            default:
                // Includes INVALID_REQUEST_ID and other definitive codes that
                // do not have a specific helper action. Claim INTERNAL_FAILURE
                // is translated to ambiguousClaimOutcome before this mapping.
                return .couldNotStart
            }
        case .ambiguousClaimOutcome:
            return .ambiguous
        case .operationInProgress:
            return .operationInProgress
        case .otherClaimInProgress:
            return .otherClaimInProgress
        case .existingActiveClaim:
            return .existingActiveClaim
        case .unacknowledgedPlacement:
            return .pendingPlacementAcknowledgement
        default:
            return .couldNotStart
        }
    }
}

struct RequestDetailView: View {
    /// Shown when claiming is refused with `PUBLIC_ACTIONS_PAUSED`.
    static let helperPauseNotice = "Helping with this meal is temporarily unavailable."

    /// Locked race-conflict copy, identical to the backend's HTTP 409
    /// `REQUEST_ALREADY_CLAIMED` message.
    static let alreadyClaimedNotice = "Someone else just started helping with this request."

    /// Shared "unavailable" register for expired, out-of-time, already-placed,
    /// and missing requests. Matches the backend's own `REQUEST_EXPIRED` message.
    static let noLongerAvailableNotice = "This request is no longer available."

    /// Matches the backend's own `REQUEST_NOT_YET_AVAILABLE` message. Reachable
    /// only for a scheduled request opened before its start — the public list
    /// does not carry one — so it says what to do rather than treating it as a
    /// failure.
    static let notYetAvailableNotice = "This request is not available to help with yet."

    /// Shown when a helper new-request notification tap could not be
    /// resolved against current backend truth (transport, timeout, server,
    /// or decoding failure). Never used when the backend has confirmed the
    /// request is actually gone — that is `noLongerAvailableNotice`.
    static let temporarilyUnavailableNotice = "This request is temporarily unavailable. Try again."

    let request: FoodRequest
    @ObservedObject var store: RequestStore
    /// Observed, not owned. Browsing this screen needs no identity; reserving
    /// does, and the gate below has to see the same verified identity every
    /// other participant action does.
    @ObservedObject var identityStore: ParticipantIdentityStore
    @ObservedObject var verificationCoordinator:
        ParticipantActionVerificationCoordinator
    @Binding var path: [AppRoute]

    /// The last W3-H2 stale-detail eligibility result the `.task` below
    /// actually resolved, bound to the exact key it was resolved for. `nil`
    /// before any read completes. Never read directly by the body — see
    /// `staleParticipationEligibility` below, which is what actually gates
    /// rendering and is what refuses to honor a result once it no longer
    /// matches the current request/identity key.
    @State private var resolvedStaleParticipation: ResolvedStaleParticipation?

    /// This screen's current W3-H2 stale-detail eligibility key: exactly the
    /// request and the verified participant identity currently in effect.
    /// Recomputed on every render, so a change to `identityStore.identity`
    /// (e.g. Change Email completing) invalidates a stored result the very
    /// next render — synchronously, without waiting for a new `.task` read.
    private var staleParticipationKey: StaleParticipationTaskKey {
        StaleParticipationTaskKey(requestID: request.id, identity: identityStore.identity)
    }

    /// The rendered W3-H2 stale-detail eligibility: `.unresolved` — never
    /// actionable — unless `resolvedStaleParticipation` was resolved for
    /// exactly the current `staleParticipationKey`. This is what keeps a
    /// result resolved for one verified principal from ever exposing Reserve
    /// under a different one, even transiently: no asynchronous coordination
    /// is required for correctness here, because this check runs on every
    /// render, including the very first one after identity changes and
    /// before its own `.task` read has had a chance to complete. Only a
    /// confirmed `.eligible` answer, for the current key, ever exposes
    /// Reserve; a failed, superseded, or mismatched-key read reads as
    /// `.unresolved` rather than being treated as permission.
    /// `claimRequest`'s own conditional grant remains the authoritative
    /// backstop regardless of this state.
    private var staleParticipationEligibility: RequestStore.StaleParticipationEligibility {
        Self.renderedEligibility(resolved: resolvedStaleParticipation, currentKey: staleParticipationKey)
    }

    /// The pure identity-key gate itself, factored out of the computed
    /// property above so it can be exercised directly by focused tests
    /// (`RequestDetailStaleParticipationTests.swift`) rather than only
    /// through source inspection — the same testable-`static-func` pattern
    /// this file already uses for `opensClaimedFlow` and `shouldDismiss`.
    /// `.unresolved` whenever `resolved` is `nil` or was resolved for a
    /// different key than `currentKey`; otherwise the resolved eligibility
    /// itself.
    static func renderedEligibility(
        resolved: ResolvedStaleParticipation?,
        currentKey: StaleParticipationTaskKey
    ) -> RequestStore.StaleParticipationEligibility {
        guard let resolved, resolved.key == currentKey else {
            return .unresolved
        }
        return resolved.eligibility
    }

    /// The W3-H2 stale-detail action boundary: `startClaim()` below must
    /// consult this — not merely trust that an already-materialized Reserve
    /// button implies permission — before starting verification or a claim.
    /// Deliberately calls `renderedEligibility(resolved:currentKey:)` above,
    /// not a separately reimplemented comparison: the render gate and the
    /// action gate must always agree, and `currentKey` is derived fresh from
    /// live state at the moment of the call, not a value captured when the
    /// button was drawn. This is what makes a button materialized for
    /// principal A harmless the instant identity changes to principal B —
    /// SwiftUI's next render, `.task` cancellation, and any async read are
    /// all irrelevant to this property; only the synchronous key comparison
    /// at the moment of the tap is.
    static func canStartClaim(
        resolved: ResolvedStaleParticipation?,
        currentKey: StaleParticipationTaskKey
    ) -> Bool {
        renderedEligibility(resolved: resolved, currentKey: currentKey) == .eligible
    }

    /// The single rule for entering the claimant-only flow: a confirmed claim
    /// for *this* request exists in memory. There is no loading, optimistic, or
    /// error path into it.
    static func opensClaimedFlow(
        activeClaim: ActiveClaimPresentation?,
        requestID: String
    ) -> Bool {
        activeClaim?.requestID == requestID
    }

    /// The fulfillment route to open once a claim is confirmed or continued:
    /// always the active claim's own request, never this screen's pre-claim
    /// value-type copy. Any field confirmed or set at claim time — W3-C1's
    /// meal-swipe quantity included — must come from here, not from a value
    /// captured before the claim existed.
    static func fulfillmentDestination(activeClaim: ActiveClaimPresentation) -> AppRoute {
        .fulfillment(activeClaim.request)
    }

    static func shouldDismiss(
        for notice: ClaimUnavailableNotice?,
        requestID: String
    ) -> Bool {
        notice?.requestID == requestID
    }

    /// A request detail follows its own newest queued terminal event, not the
    /// FIFO head Active Requests presents. The head may belong to an unrelated
    /// request whose notice was produced earlier and is still unacknowledged.
    private var matchingClaimUnavailableNotice: ClaimUnavailableNotice? {
        store.claimUnavailableNotice(for: request.id)
    }

    /// Suppressed once the helper is being sent back to Active Requests: the
    /// notice belongs on the list they land on, not on the screen leaving view.
    private var inlineClaimError: ClaimPresentationError? {
        guard matchingClaimUnavailableNotice == nil,
              let claimError = store.claimError(for: request.id) else {
            return nil
        }
        return ClaimPresentationError.map(claimError)
    }

    var body: some View {
        Form {
            Section("Food request") {
                Text(request.diningSpot.name)
                    .font(.headline)
                if let address = request.diningSpot.address {
                    Text(address)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(request.foodDescription)
                Text(request.timingDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                // V1 meal-swipe requirement (W3-C1). Shown before the Reserve
                // action below, so a helper knows the exact requirement before
                // committing. Every request carries one, so this is never
                // conditional on its presence.
                Text("Meal swipes: \(request.mealSwipes)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("request-meal-swipes")
            }

            Section {
                if Self.opensClaimedFlow(activeClaim: store.activeClaim, requestID: request.id) {
                    // Already reserved by this helper. Offering the claim action
                    // again would only produce a refusal, so this screen becomes
                    // a way back into the reservation they already hold.
                    continueHelpingLink
                } else {
                    switch staleParticipationEligibility {
                    case .unresolved:
                        // Not yet known, or a failed/superseded read — never
                        // treated as permission to Reserve. Nothing renders
                        // here rather than inventing new "checking…" copy;
                        // the `.task` below re-resolves this whenever the
                        // request or the authoritative identity changes.
                        EmptyView()
                    case .alreadyParticipated:
                        // W3-H2 stale detail Reserve truth: this verified
                        // participant already successfully held this exact
                        // request once before and can never reacquire it.
                        // Reuses the existing refused-reservation copy — no
                        // new explanatory text — per the accepted
                        // marketplace-presentation contract.
                        Text(Self.noLongerAvailableNotice)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("claim-error")
                    case .eligible:
                        claimSection
                    }
                }
            }
        }
        .navigationTitle("Request")
        .task(id: staleParticipationKey) {
            // The key is captured before the asynchronous read starts, and
            // re-derived (not reused) after it completes: `identityStore` is
            // a live reference, so re-reading `staleParticipationKey` below
            // reflects whatever is authoritative *now*, not what it was when
            // this task began. A result is only ever written for the exact
            // key it was resolved for.
            let key = staleParticipationKey
            let result = await store.resolveStaleParticipationEligibility(for: request.id)
            guard !Task.isCancelled, key == staleParticipationKey else { return }
            resolvedStaleParticipation = ResolvedStaleParticipation(key: key, eligibility: result)
        }
        // Confirmed claim success is the only thing that opens the flow, and it
        // opens it by pushing a route rather than by flipping a presentation
        // flag this screen would then have to keep in sync with store state.
        // Closing the flow belongs to the claimant screen itself: a manual Back
        // leaves `activeClaim` untouched, so this does not fire and the
        // reservation survives the navigation.
        .onChange(of: store.activeClaim?.requestID) { _, _ in
            if let activeClaim = store.activeClaim,
               Self.opensClaimedFlow(activeClaim: activeClaim, requestID: request.id) {
                path = AppRoute.appending(
                    Self.fulfillmentDestination(activeClaim: activeClaim),
                    to: path
                )
            }
        }
        // A stale detail screen must never outlive the backend's verdict. The
        // whole helper flow is unwound, not just this level: the claimant screen
        // this detail opened may still be above it, and the notice belongs on
        // the list the helper lands on.
        // A sheet, so this screen stays mounted and the helper returns to the
        // same request they were looking at.
        .sheet(isPresented: isPresentingVerification) {
            ParticipantVerificationView(
                store: identityStore,
                cancel: { verificationCoordinator.helperCancelled(requestID: request.id) }
            )
        }
        .onChange(of: identityStore.identity) { previous, current in
            guard case .claim(let requestID)? =
                    verificationCoordinator.helperIdentityDidChange(
                        requestID: request.id,
                        from: previous,
                        to: current,
                        path: path,
                        claimAlreadyActive: Self.opensClaimedFlow(
                            activeClaim: store.activeClaim,
                            requestID: request.id
                        )
                    ),
                  requestID == request.id else {
                return
            }
            // The coordinator clears before returning the exact request ID.
            performClaim()
        }
        .onChange(of: path) { _, currentPath in
            verificationCoordinator.helperNavigationChanged(
                requestID: request.id,
                path: currentPath
            )
        }
        .onChange(of: matchingClaimUnavailableNotice?.id) { _, noticeID in
            if let noticeID,
               let notice = matchingClaimUnavailableNotice,
               notice.id == noticeID,
               Self.shouldDismiss(for: notice, requestID: request.id) {
                path = AppRoute.returningToActiveRequests(from: path)
            }
        }
        .onDisappear {
            verificationCoordinator.helperDisappeared(requestID: request.id)
        }
    }

    /// Open exactly while the identity store has a flow running. Dismissing
    /// goes through `cancelVerification()`, so an abandoned flow is abandoned in
    /// one place — and abandoning it reserves nothing.
    private var isPresentingVerification: Binding<Bool> {
        Binding(
            get: {
                verificationCoordinator.isPresentingClaimVerification(
                    requestID: request.id
                )
            },
            set: { isPresented in
                if !isPresented {
                    verificationCoordinator.helperSheetDismissed(
                        requestID: request.id
                    )
                }
            }
        )
    }

    @ViewBuilder
    private var continueHelpingLink: some View {
        if let activeClaim = store.activeClaim {
            NavigationLink(value: Self.fulfillmentDestination(activeClaim: activeClaim)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.continueHelpingTitle)
                    Text(ActiveRequestsView.reservedUntilText(activeClaim.claimExpiresAt))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("claim-continue")
        }
    }

    @ViewBuilder
    private var claimSection: some View {
        let inlineClaimError = self.inlineClaimError

        if let inlineClaimError {
            Text(inlineClaimError.message)
                .foregroundStyle(
                    inlineClaimError == .publicActionsPaused
                        ? Color.secondary
                        : Color.red
                )
                .accessibilityIdentifier("claim-error")
        }

        // Rather than leave the helper tapping an action that can only be
        // refused, send them to the reservation that is blocking this one.
        if inlineClaimError == .existingActiveClaim, let activeClaim = store.activeClaim {
            // The claimant screen this pushes sits on top of a *different*
            // request's detail. Leaving it truncates the path back to Active
            // Requests, so both levels come off at once and the helper is not
            // returned to a stale detail for a request they never claimed —
            // the same exit the other two entry points get.
            NavigationLink(value: Self.fulfillmentDestination(activeClaim: activeClaim)) {
                Text(Self.goToActiveReservationTitle)
            }
            .accessibilityIdentifier("go-to-active-reservation")
        }

        if Self.showsPauseRecoveryAction(for: inlineClaimError) {
            Button {
                startClaim()
            } label: {
                if store.isClaiming(requestID: request.id) {
                    HStack {
                        ProgressView()
                        Text("Reserving…")
                    }
                } else {
                    Text(Self.pauseRecoveryActionTitle)
                }
            }
            .disabled(store.isClaiming(requestID: request.id))
            .accessibilityIdentifier("claim-pause-recovery")
        }

        // The ordinary action stays withdrawn for a confirmed pause because its
        // accepted recovery is named separately above. An unconfirmed claim also
        // withdraws it because the POST may already have been applied.
        if Self.showsClaimAction(for: inlineClaimError) {
            // Stated before the tap, because the tap is the commitment: it
            // reserves the request immediately and there is no way to hand it
            // back early. Deliberately vague about the length — the backend caps
            // the reservation at the request's own expiration, so a full fifteen
            // minutes is never guaranteed.
            Text(Self.claimConsequenceNotice)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("claim-consequence-notice")

            // Browsing needed no identity, so the first mention of verification
            // belongs here, beside the action that needs one — before the tap,
            // not after it.
            if !identityStore.isVerified {
                Text(Self.verificationRequiredNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("claim-verification-notice")
            }

            Button {
                startClaim()
            } label: {
                if store.isClaiming(requestID: request.id) {
                    HStack {
                        ProgressView()
                        Text("Reserving…")
                    }
                } else {
                    Text(Self.claimActionTitle)
                }
            }
            // Request-scoped: an in-flight claim on another request must
            // not silently grey out this one. The store's own mutex
            // stays authoritative and refuses the duplicate with
            // `operationInProgress`, which explains itself in copy
            // rather than leaving a dead control on screen.
            .disabled(store.isClaiming(requestID: request.id))
            .accessibilityIdentifier("claim-action")
        }
    }

    /// Locked action title: tapping it claims immediately, with no confirmation
    /// step in between.
    static let claimActionTitle = "Help with this request"

    /// What the tap actually does, said before it happens. One tap is enough —
    /// a confirmation screen would not add understanding, but an unexplained
    /// action would leave a helper reserving a real student's meal, and blocking
    /// every other helper from it, without knowing they had done so.
    static let claimConsequenceNotice =
        "This holds the meal for you for a few minutes so no one else orders it. You place the Grubhub order, then save the order details here."

    /// Re-entry for a request this helper already reserved.
    static let continueHelpingTitle = "Continue helping with this request"

    /// Re-entry for the *other* request whose reservation is blocking this one.
    static let goToActiveReservationTitle = "Go to the request you’re helping with"

    /// A claim already in flight for a different request. The action stays on
    /// screen: unlike a held reservation this clears itself in a moment, so the
    /// helper is asked to wait rather than sent somewhere else.
    static let otherClaimInProgressTitle = "Please wait"
    static let otherClaimInProgressNotice =
        "We’re still reserving another request. Try this one again in a moment."

    /// An unacknowledged placement result gates new claims until it is dismissed
    /// from Active Requests.
    static let pendingPlacementTitle = "Check your last order first"
    static let pendingPlacementNotice =
        "Go back to Active Requests and tap “Got it” on your last order. Then you can help with another request."

    static let pauseRecoveryActionTitle = "Check again"

    /// Shown beside the claim action while this installation is unverified.
    static let verificationRequiredNotice =
        "You’ll verify your NYU email once before helping. Nothing is reserved until it’s verified."

    static func showsPauseRecoveryAction(for error: ClaimPresentationError?) -> Bool {
        error == .publicActionsPaused
    }

    /// The claim action is withheld only where offering it would be untruthful:
    /// a paused backend uses its explicit recovery action instead, an unconfirmed
    /// claim may already have succeeded, an existing reservation elsewhere makes
    /// this claim impossible until that one ends, and an unacknowledged placement
    /// result blocks every new claim until it is read.
    static func showsClaimAction(for error: ClaimPresentationError?) -> Bool {
        error != .publicActionsPaused
            && error != .ambiguous
            && error != .existingActiveClaim
            && error != .pendingPlacementAcknowledgement
    }

    private func startClaim() {
        // W3-H2 stale-detail action boundary: an already-materialized Reserve
        // button is not itself permission. Re-derives the current key and
        // re-checks it against whatever was actually resolved, at the exact
        // moment of the tap — synchronously, independent of whether SwiftUI
        // has committed a re-render since identity last changed. A button
        // drawn for a principal who has since been replaced (Change Email
        // completing) becomes a no-op the instant that replacement happens,
        // not merely once the next render or `.task` catches up.
        guard Self.canStartClaim(resolved: resolvedStaleParticipation, currentKey: staleParticipationKey) else {
            return
        }

        // The helper gate. Nothing is reserved and no request is sent for an
        // unverified helper: the reservation would be refused by the backend
        // anyway, and taking a real student's meal out of everyone else's reach
        // is not something to attempt on an identity that does not exist yet.
        guard identityStore.isVerified else {
            _ = verificationCoordinator.beginClaim(
                requestID: request.id,
                path: path
            )
            return
        }
        performClaim()
    }

    private func performClaim() {
        Task {
            // The store owns duplicate-submit protection and error state; a
            // rejected duplicate never reaches the network.
            try? await store.claim(requestID: request.id)
        }
    }
}
