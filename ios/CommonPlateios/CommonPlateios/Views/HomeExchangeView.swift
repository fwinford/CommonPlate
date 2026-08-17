//
//  HomeExchangeView.swift
//  CommonPlateios
//
// W4-H2: Home's live CommonPlate exchange — the board-first root content that
// supersedes R1's recurring static launcher. Renders the same authoritative
// `RequestStore` state `ActiveRequestsView` already renders (membership,
// order, active reservation, and now caller-relative ownership), composed
// into the approved H2 states: populated/low-activity board, Continue
// Helping, Your Request, Empty Exchange (E1), and Exchange Unavailable (U4).
//
// This view owns Home composition and navigation only. It creates no new
// request/reservation/ownership truth of its own — every value it renders
// comes from `RequestStore`, which already drives `ActiveRequestsView`.
import SwiftUI

struct HomeExchangeView: View {
    @ObservedObject var store: RequestStore
    @ObservedObject var identityStore: ParticipantIdentityStore
    @ObservedObject var alertSubscriptionStore: AlertSubscriptionStore
    @ObservedObject var pushSubscriptionStore: PushSubscriptionStore
    @ObservedObject var unsubscribeStore: ParticipantEmailUnsubscribeStore
    let onRequestMeal: () -> Void

    /// H2's Request Alerts quick entry (Section 12): a focused centered
    /// overlay presented directly over Home, never a navigation push and
    /// never routed through Settings first.
    @State private var isPresentingRequestAlerts = false

    /// HQ decision 3 (authored Home refresh presentation): presentation-only
    /// state derived *from inside* `.refreshable`'s own closure — never from
    /// an independent drag gesture or threshold. SwiftUI has already decided
    /// the user completed a pull-to-refresh before this closure runs, so
    /// setting these flags around the existing `store.fetchRequests()` call
    /// only observes native refresh lifecycle; it never decides whether a
    /// refresh happens.
    @State private var isRefreshInFlight = false
    /// True only after `performAuthoredRefresh()` observes an authoritative
    /// refresh that recovered Home from Exchange Unavailable into a genuinely
    /// healthy board state — never set on a timer, never on a generic
    /// successful fetch. Cleared shortly after by `body`'s `onChange`, which
    /// is cosmetic dismissal timing only, not a fabricated outcome. While
    /// true, `displayedBoardState` deliberately holds the Unavailable-shaped
    /// presentation so the brief recovery checkmark (HQ decision 6) renders
    /// in the same persistent cue before content flips to the now-truthful
    /// board.
    @State private var isShowingRecoverySuccess = false
    /// Passive observation only (Section 9 "H2 refresh implementation-
    /// authority clarification"): how far the exchange `ScrollView`'s own
    /// content has been pulled below its rest position, read from the native
    /// scroll geometry via `HomeExchangeScrollOffsetKey`. This never decides
    /// whether refresh fires — only `.refreshable`'s own closure does that —
    /// it only drives the authored arrow's continuous, presentation-only
    /// travel while the pull is in progress. Per Faith's resolution (final
    /// H2 visual alignment FIX, item 2), the cue makes no semantic claim
    /// about when releasing will trigger refresh — SwiftUI never exposes
    /// `.refreshable`'s own internal activation distance, so no approximated
    /// threshold or "Release to refresh" label is derived from `pullOffset`.
    /// It only ever produces continuous motion that becomes more pronounced
    /// with distance, then the cue jumps straight to the Loading phase once
    /// `isRefreshInFlight` — set only from inside `.refreshable`'s own
    /// closure — actually becomes true.
    @State private var pullOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// HQ decision 5: a presentation-only maximum for the initial Loading
    /// state. This never touches `RequestStore` truth or its
    /// fetch/generation boundary — it only tells `boardState` to stop
    /// presenting Loading and present Exchange Unavailable once 5 seconds
    /// have elapsed with no authoritative result yet. If the same
    /// still-current fetch later resolves (success or failure), `boardState`
    /// reads that authoritative result directly and this flag no longer
    /// matters — a fast response is never held back, and a slow-but-eventual
    /// success still recovers Home normally.
    @State private var hasInitialLoadDeadlineElapsed = false
    static let initialLoadDeadline: Duration = .seconds(5)

    var body: some View {
        ZStack {
            exchangeContent

            if isPresentingRequestAlerts {
                RequestAlertsOverlayView(
                    identityStore: identityStore,
                    alertSubscriptionStore: alertSubscriptionStore,
                    pushSubscriptionStore: pushSubscriptionStore,
                    unsubscribeStore: unsubscribeStore,
                    onDismiss: { isPresentingRequestAlerts = false }
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isPresentingRequestAlerts)
        // Same fetch-on-appearance contract `ActiveRequestsView` already
        // uses: an initial load on first appearance, a refresh classified by
        // `hasSuccessfullyFetchedRequests` on any later one, guarded so a
        // redraw or a concurrent Try Again never starts a second fetch.
        .task {
            guard !store.isFetching else { return }
            await store.fetchRequests()
        }
        // HQ decision 5: a bounded maximum wait for the initial Loading
        // presentation, layered over the existing authoritative fetch — not
        // a second reload source and not a fake minimum delay. Runs
        // concurrently with the fetch task above; if the fetch has already
        // resolved (success or failure) by the time this wakes, it is a
        // no-op, since `boardState` no longer reads this flag once
        // `hasSuccessfullyFetchedRequests` or `hasFailedInitialFetchAtLeastOnce`
        // is true.
        .task {
            try? await Task.sleep(for: Self.initialLoadDeadline)
            guard !store.hasSuccessfullyFetchedRequests,
                  !store.hasFailedInitialFetchAtLeastOnce else { return }
            hasInitialLoadDeadlineElapsed = true
        }
        .onChange(of: isShowingRecoverySuccess) { _, isShowing in
            guard isShowing else { return }
            Task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                isShowingRecoverySuccess = false
            }
        }
        // Participant-scoped ownership review (Section 9): `store.requests`
        // carries caller-relative `isOwnRequest` truth resolved for whoever
        // was authoritative at the moment of the last fetch. Verification
        // completing, Change Email completing, or Remove Email all change
        // who "own" means without this board otherwise ever refreshing on
        // their own — the same `.onChange(of: identityStore.identity)`
        // re-key `RequestDetailView` already uses for its own per-request
        // stale-participation truth. This invokes no reload path but the
        // existing authoritative one, and reuses its existing
        // fetchGeneration fence for correctness, not a new truth owner.
        .onChange(of: identityStore.identity) { _, _ in
            // Invalidates the previous participant's caller-relative
            // ownership *before* reloading, so the window between an identity
            // change and replacement truth fails closed rather than showing
            // the old participant's own/not-own conclusions as this one's.
            Task { await store.reconcileOwnershipForCurrentAuthority() }
        }
    }

    /// The one place H2 observes the native `.refreshable` interaction
    /// actually firing, and the only reload path it ever invokes —
    /// `store.fetchRequests()`, identical to initial load and every other
    /// Home refresh. No independent gesture, threshold, or second refresh
    /// state machine decides whether this runs; SwiftUI already decided the
    /// user completed a pull-to-refresh before calling this closure.
    private func performAuthoredRefresh() async {
        let wasUnavailable = currentBoardState == .unavailable
        isRefreshInFlight = true

        // HQ decision 8: a user-initiated refresh may remain in the
        // authored Refreshing presentation for at most
        // `manualRefreshDeadline`. `awaitWithDeadline` cancels whichever of
        // the fetch/timeout loses the race, so a fetch that times out here
        // cannot keep running to mutate state later — it relies entirely on
        // `RequestStore.fetchRequests()`'s own existing `CancellationError`
        // handling and `fetchGeneration`/`collectionRevision` fence, not any
        // new store mechanism, and that same fence is what guarantees a
        // late/cancelled result from this attempt can never overwrite a
        // subsequent refresh's result even if cancellation isn't observed
        // instantly.
        let didResolveInTime = await Self.awaitWithDeadline(Self.manualRefreshDeadline) {
            await store.fetchRequests()
        }

        isRefreshInFlight = false
        pullOffset = 0

        // A refresh still unresolved at the deadline ends the refresh
        // interaction without a success checkmark. `currentBoardState` is
        // already whatever RequestStore's own authoritative state is — the
        // guard above prevents a cancelled/stale fetch from having mutated
        // it — so Unavailable stays Unavailable and a healthy board stays
        // exactly as it was.
        guard didResolveInTime else { return }

        // HQ decision 6: the checkmark is gated on genuine recovery — Home
        // was Exchange Unavailable immediately before this refresh, and the
        // authoritative result now resolves to a healthy board state. A
        // healthy-to-healthy refresh, or a refresh that remains Unavailable,
        // never sets this.
        if wasUnavailable && currentBoardState != .unavailable {
            isShowingRecoverySuccess = true
        }
    }

    /// Races `operation` against `deadline`, cancelling whichever loses.
    /// Returns whether `operation` itself finished first. This is the only
    /// place H2 imposes the manual-refresh deadline; it invokes no reload
    /// path of its own.
    private static func awaitWithDeadline(
        _ deadline: Duration,
        operation: @escaping () async -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await operation()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return false
            }
            let didOperationFinishFirst = await group.next() ?? false
            group.cancelAll()
            return didOperationFinishFirst
        }
    }

    /// HQ decision 8.
    static let manualRefreshDeadline: Duration = .seconds(5)

    /// The named coordinate space `pullOffset` is measured against — see the
    /// `.background(GeometryReader { ... })` reader inside `exchangeContent`.
    private static let scrollCoordinateSpace = "homeExchangeScroll"

    /// Purely cosmetic saturation distance for how far the authored arrow's
    /// continuous travel/emphasis can grow — not a claim about when refresh
    /// will actually fire. `pulling(progress:)` reaches `1` at and beyond
    /// this distance and simply stops growing further; it is never compared
    /// against, and never approximates, native `.refreshable`'s own
    /// undocumented activation distance.
    private static let pullVisualSaturationDistance: CGFloat = 70

    /// Derives the authored cue's presentation phase from passively-observed
    /// native scroll geometry and the existing authoritative refresh
    /// lifecycle flags — never from an independent gesture or threshold.
    /// Phase priority is `recoverySuccess > refreshing > pulling > idle`,
    /// matching the actual native behavior where content stays displaced
    /// under the system refresh control during and briefly after a fetch.
    /// There is deliberately no intermediate "about to release" phase: per
    /// Faith's resolution, the cue only ever shows continuous pull motion
    /// until native `.refreshable` itself actually activates, at which point
    /// `isRefreshInFlight` flips this straight to `.refreshing`.
    private var pullRefreshPhase: PullRefreshPhase {
        if isShowingRecoverySuccess { return .recoverySuccess }
        if isRefreshInFlight { return .refreshing }
        guard pullOffset > 0 else { return .idle }
        let progress = min(pullOffset / Self.pullVisualSaturationDistance, 1)
        return .pulling(progress: progress)
    }

    /// The board content actually rendered this frame. Identical to
    /// `currentBoardState` except during the brief post-recovery checkmark
    /// hold (HQ decision 6): while `isShowingRecoverySuccess` is true, this
    /// deliberately keeps presenting the Unavailable-shaped state — whose own
    /// persistent cue is already showing the checkmark — so the truthful
    /// healthy content only appears once that brief acknowledgement finishes,
    /// rather than swapping board content out from under the checkmark.
    private var displayedBoardState: BoardState {
        isShowingRecoverySuccess ? .unavailable : currentBoardState
    }

    // MARK: - Exchange content

    /// HQ decision 3: CommonPlate/at NYU branding, the Settings gear, the
    /// board heading ("Needs help" / "Needs help right now"), and Continue
    /// Helping's attention-priority state stay outside the inner refreshable
    /// `ScrollView` so they remain visually anchored during a pull gesture.
    /// Only the exchange/board content below participates in the authored
    /// pull/refreshing/success presentation — the whole Home composition no
    /// longer rubber-bands as one sheet.
    private var exchangeContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.l) {
                header
                continueHelpingSection
                boardHeadingRow
            }
            .padding(.horizontal, CommonPlateStyle.Spacing.l)
            .padding(.top, CommonPlateStyle.Spacing.l)
            .padding(.bottom, CommonPlateStyle.Spacing.m)

            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
                        // This is load-bearing (Section 6): Exchange
                        // Unavailable's own persistent cue inside
                        // `unavailableState` already covers every phase, so
                        // this transient banner must not also be mounted
                        // there — doing so would render two refresh cues at
                        // once during the same pull/refresh.
                        if displayedBoardState != .unavailable {
                            refreshFeedbackBanner
                        }
                        boardSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CommonPlateStyle.Spacing.l)
                    .padding(.bottom, CommonPlateStyle.Spacing.l)
                    .frame(minHeight: geometry.size.height, alignment: .top)
                    .background(
                        GeometryReader { contentGeometry in
                            Color.clear.preference(
                                key: HomeExchangeScrollOffsetKey.self,
                                value: contentGeometry.frame(in: .named(Self.scrollCoordinateSpace)).minY
                            )
                        }
                    )
                }
                .coordinateSpace(name: Self.scrollCoordinateSpace)
                .onPreferenceChange(HomeExchangeScrollOffsetKey.self) { minY in
                    pullOffset = max(0, minY)
                }
                // Functional fix, not a motion-polish change: `.frame(
                // minHeight: geometry.size.height)` above makes the exchange
                // ScrollView's content exactly fill the viewport on every
                // short-content state (Unavailable, Empty, and in practice
                // most Populated/Low Activity boards too, since a handful of
                // request cards rarely exceeds one screen). Without this
                // modifier, UIKit only allows vertical rubber-banding — the
                // drag `.refreshable` itself depends on — when a scroll
                // view's content is taller than its bounds, so a physical
                // pull could not initiate a refresh at all whenever content
                // did not overflow the viewport. `.always` keeps bounce (and
                // therefore the ability to pull) available regardless of
                // content length; it changes no refresh authority or reload
                // path.
                .scrollBounceBehavior(.always, axes: .vertical)
                .refreshable {
                    await performAuthoredRefresh()
                }
            }
        }
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            requestMealButton
        }
    }

    // MARK: - Authored refresh feedback (HQ decision 3)

    /// Transient, exchange/board-scoped presentation for Populated, Low
    /// Activity, and Empty Exchange — never a second source of refresh
    /// truth, and never mounted simultaneously with Exchange Unavailable's
    /// own persistent cue in `unavailableState` (this view is only reachable
    /// while `displayedBoardState != .unavailable`; see `exchangeContent`).
    /// This is the SAME `PullRefreshCue` component Unavailable uses, always
    /// mounted rather than conditionally inserted/removed, so its symbol
    /// identity persists across every phase — collapsing to zero height at
    /// `.idle` instead of being torn down avoids the layout flash a
    /// conditional `if`/`.transition` produced.
    private var refreshFeedbackBanner: some View {
        PullRefreshCue(phase: pullRefreshPhase, showsIdleInstruction: false)
            .frame(maxWidth: .infinity)
            .padding(.vertical, CommonPlateStyle.Spacing.s)
            .background(
                Color.accentColor.opacity(pullRefreshPhase == .idle ? 0 : 0.12),
                in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
            )
            .frame(height: pullRefreshPhase == .idle ? 0 : nil)
            .opacity(pullRefreshPhase == .idle ? 0 : 1)
            .accessibilityHidden(pullRefreshPhase == .idle)
            .accessibilityIdentifier(refreshFeedbackAccessibilityIdentifier)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: pullRefreshPhase)
    }

    private var refreshFeedbackAccessibilityIdentifier: String {
        pullRefreshPhase == .refreshing ? "home-refresh-refreshing" : "home-refresh-pulling"
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CommonPlate")
                    .font(.commonPlateBrandDisplay(.title))
                Text("at NYU")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }

            Spacer()

            NavigationLink(value: AppRoute.settings) {
                Image(systemName: "gearshape")
                    .font(.body.weight(.semibold))
                    .frame(width: 38, height: 38)
                    .background(Circle().strokeBorder(.secondary.opacity(0.3)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("home-settings")
        }
    }

    // MARK: - Continue Helping

    /// The active-reservation priority state (Section 7 "Attention /
    /// continuation state"). Reads only confirmed `RequestStore` state and
    /// routes into the existing fulfillment continuation flow — no new
    /// reservation state is created here.
    @ViewBuilder
    private var continueHelpingSection: some View {
        if let claim = store.activeClaim {
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
                Text(Self.continueHelpingHeading)
                    .font(.title3.weight(.bold))
                    .accessibilityIdentifier("home-continue-helping-heading")

                NavigationLink(value: AppRoute.fulfillment(claim.request)) {
                    RequestCardView(
                        request: claim.request,
                        kind: .helping(claimExpiresAt: claim.claimExpiresAt)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home-continue-helping-card")
            }
        }
    }

    // MARK: - Board

    /// The one shared board-heading row, rendered once outside the inner
    /// refreshable `ScrollView` (see `exchangeContent`) rather than repeated
    /// inside each state branch — so `Needs help` is structurally guaranteed
    /// present across every board state, including the very first load,
    /// instead of relying on each branch to repeat it.
    private var boardHeadingRow: some View {
        Text(boardHeading)
            .font(.title3.weight(.bold))
            .accessibilityIdentifier("home-board-heading")
    }

    private var boardHeading: String {
        switch displayedBoardState {
        case .loading:
            return Self.loadingHeading
        case .unavailable:
            return Self.unavailableHeading
        case .empty:
            return Self.emptyHeading
        case .populated:
            return Self.needsHelpRightNowHeading
        }
    }

    /// The presentation-layer board state, folding in the HQ decision 5
    /// initial-load deadline over the store's own authoritative derivation.
    /// Reuses `ActiveRequestsView.availableRequests` — the same existing
    /// pattern that surface already uses to exclude a request this helper is
    /// actively holding via Continue Helping, so the same request is never
    /// both pinned above and duplicated below on the shared board.
    private var currentBoardState: BoardState {
        Self.boardState(
            hasSuccessfullyFetchedRequests: store.hasSuccessfullyFetchedRequests,
            hasAttemptedRequestFetch: store.hasAttemptedRequestFetch,
            hasFailedInitialFetchAtLeastOnce: store.hasFailedInitialFetchAtLeastOnce,
            isFetching: store.isFetching,
            requests: ActiveRequestsView.availableRequests(
                store.requests,
                activeClaimRequestID: store.activeClaim?.requestID
            ),
            hasInitialLoadDeadlineElapsed: hasInitialLoadDeadlineElapsed
        )
    }

    @ViewBuilder
    private var boardSection: some View {
        switch displayedBoardState {
        case .loading:
            loadingState
        case .unavailable:
            unavailableState
        case .empty:
            emptyState
        case .populated(let requests):
            populatedBoard(requests)
        }
    }

    private func populatedBoard(_ requests: [FoodRequest]) -> some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
            if store.refreshError != nil {
                refreshFailureNotice
            }

            VStack(spacing: CommonPlateStyle.Spacing.m) {
                ForEach(requests) { request in
                    NavigationLink(value: AppRoute.requestDetail(request)) {
                        RequestCardView(
                            request: request,
                            kind: request.isOwnRequest ? .own : .open
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home-request-card-\(request.id)")
                }
            }
        }
    }

    /// Only the genuinely first-ever fetch (this store has never once
    /// resolved to success or failure) reaches this case — see
    /// `boardState(...)`. `boardHeadingRow` above already keeps `Needs help`
    /// present on screen through this state, so this content itself is only
    /// the loading indicator.
    private var loadingState: some View {
        HStack {
            Spacer()
            ProgressView("Loading…")
                .padding(.top, CommonPlateStyle.Spacing.xl)
            Spacer()
        }
    }

    /// E1. Contract-exact heading ("Needs help") and body copy — see
    /// `docs/week-4-ios-testflight-spec.md` W4-H2 Section 8.
    ///
    /// The supporting explanation and `Request Alerts` action are shown only
    /// when CommonPlate Push request-alert delivery is not effectively/
    /// stably enabled for this installation — the existing accepted
    /// `PushSubscriptionStore.state` authority (never Apple/iOS permission
    /// alone, never Email alert state). Stable Push On hides both; H2 reads
    /// this state directly and creates no second local boolean.
    private var emptyState: some View {
        VStack(spacing: CommonPlateStyle.Spacing.m) {
            Text(Self.emptyTitle)
                .font(.headline.weight(.bold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)
                .accessibilityIdentifier("home-empty-title")

            if Self.showsRequestAlertsPromotion(pushState: pushSubscriptionStore.state) {
                Text(Self.emptyBody)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)

                Button {
                    isPresentingRequestAlerts = true
                } label: {
                    Text(Self.requestAlertsActionTitle)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(minHeight: 44)
                        .padding(.horizontal, CommonPlateStyle.Spacing.l)
                }
                .buttonStyle(.plain)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                )
                .accessibilityIdentifier("home-empty-request-alerts")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CommonPlateStyle.Spacing.xl)
        .padding(.horizontal, CommonPlateStyle.Spacing.l)
    }

    /// U4. No blue slab, status icon, or request-card-like container. Per
    /// the HQ Exchange Unavailable recovery decision, this state shows no
    /// visible Try Again action and no other explanatory body copy; native
    /// pull-to-refresh on the enclosing `.refreshable` scroll view (see
    /// `exchangeContent`) is the sole recovery interaction, driving the same
    /// `store.fetchRequests()` reload/state path used by every other Home
    /// refresh. The visible `PullToRefreshCue` beneath the title is
    /// presentation/discoverability only — it never implements, replaces, or
    /// simulates refresh.
    private var unavailableState: some View {
        VStack(spacing: CommonPlateStyle.Spacing.m) {
            Text(Self.unavailableTitle)
                .font(.headline.weight(.bold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)
                .accessibilityIdentifier("home-unavailable-title")

            PullRefreshCue(phase: pullRefreshPhase, showsIdleInstruction: true)
                .accessibilityIdentifier("home-unavailable-refresh-cue")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CommonPlateStyle.Spacing.xl)
        .padding(.horizontal, CommonPlateStyle.Spacing.l)
    }

    /// Stale-content notice only — not a second recovery mechanism. Native
    /// pull-to-refresh, already available on this same scroll view, is the
    /// sole recovery interaction; this carries no retry button per HQ
    /// decision 3's "no visible refresh button" boundary.
    private var refreshFailureNotice: some View {
        Text("Couldn’t refresh. Some meals shown may no longer be available.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    // MARK: - Request a Meal

    private var requestMealButton: some View {
        Button(action: onRequestMeal) {
            Text("＋  Request a Meal")
        }
        // `.commonPlateMajorPrimaryAction()` already sets the approved
        // `.title3.weight(.semibold)` (~20pt) major-action label font on
        // `configuration.label`; a `.font()` set directly on this Text, as
        // an inner modifier, would win over that outer style and silently
        // shrink the CTA to `.body` (~17pt) instead.
        .commonPlateMajorPrimaryAction()
        .commonPlateMajorActionFrame()
        .padding(.horizontal, CommonPlateStyle.Spacing.l)
        .padding(.bottom, CommonPlateStyle.Spacing.s)
        .background(CommonPlateStyle.Color.baseCanvas)
        .accessibilityIdentifier("home-request-a-meal")
    }

    // MARK: - Copy

    static let continueHelpingHeading = "Continue helping"
    static let needsHelpRightNowHeading = "Needs help right now"
    static let emptyHeading = "Needs help"
    static let unavailableHeading = "Needs help"
    static let loadingHeading = "Needs help"

    static let emptyTitle = "No open requests right now."
    static let emptyBody = "When someone needs a meal, their request will appear here."
    static let requestAlertsActionTitle = "Request Alerts"

    static let unavailableTitle = "Helping is\ntemporarily unavailable"
    static let refreshCueText = "Pull down to refresh"

    static let refreshingText = "Refreshing…"
    static let refreshSuccessText = "Updated"

    // MARK: - Board state derivation

    enum BoardState: Equatable {
        case loading
        case unavailable
        case empty
        case populated([FoodRequest])
    }

    /// Pure derivation from `RequestStore`'s existing published fetch state —
    /// the same signals `ActiveRequestsView` already reads
    /// (`hasSuccessfullyFetchedRequests`, `hasAttemptedRequestFetch`,
    /// `isFetching`, `requests`), plus `hasFailedInitialFetchAtLeastOnce` — so
    /// Home never invents a fetch/error model of its own. Unavailable (U4) is
    /// reached once a fetch has been attempted, has finished, and has never
    /// yet succeeded, and it is held there through any later retry: without
    /// `hasFailedInitialFetchAtLeastOnce`, a pull-to-refresh retry from
    /// Unavailable is indistinguishable from the very first attempt (both
    /// publish `hasAttemptedRequestFetch: true, isFetching: true,
    /// hasSuccessfullyFetchedRequests: false`), which regressed Home to the
    /// bare `.loading` presentation — dropping `Needs help` and everything
    /// else — on every retry. A request the helper is actively reserving is
    /// excluded from `requests` already, by the backend's own availability
    /// rule, so it never doubles as a board row here.
    static func boardState(store: RequestStore) -> BoardState {
        boardState(
            hasSuccessfullyFetchedRequests: store.hasSuccessfullyFetchedRequests,
            hasAttemptedRequestFetch: store.hasAttemptedRequestFetch,
            hasFailedInitialFetchAtLeastOnce: store.hasFailedInitialFetchAtLeastOnce,
            isFetching: store.isFetching,
            requests: ActiveRequestsView.availableRequests(
                store.requests,
                activeClaimRequestID: store.activeClaim?.requestID
            )
        )
    }

    /// `hasInitialLoadDeadlineElapsed` (HQ decision 5) is presentation-only:
    /// it never changes what a resolved fetch means, only whether an
    /// *unresolved* one keeps presenting Loading past 5 seconds. Once
    /// `hasSuccessfullyFetchedRequests` or `hasFailedInitialFetchAtLeastOnce`
    /// is true, this parameter is irrelevant — the authoritative result
    /// already determines the state, so a same-still-current fetch that
    /// resolves after the deadline still recovers Home normally.
    static func boardState(
        hasSuccessfullyFetchedRequests: Bool,
        hasAttemptedRequestFetch: Bool,
        hasFailedInitialFetchAtLeastOnce: Bool,
        isFetching: Bool,
        requests: [FoodRequest],
        hasInitialLoadDeadlineElapsed: Bool = false
    ) -> BoardState {
        if !hasSuccessfullyFetchedRequests {
            if hasFailedInitialFetchAtLeastOnce {
                return .unavailable
            }
            if hasAttemptedRequestFetch && !isFetching {
                return .unavailable
            }
            if hasInitialLoadDeadlineElapsed {
                return .unavailable
            }
            return .loading
        }
        return requests.isEmpty ? .empty : .populated(requests)
    }

    // MARK: - Empty Exchange conditional Request Alerts promotion

    /// Pure predicate over the existing accepted `PushSubscriptionStore.state`
    /// authority (HQ decision 2): the supporting explanation and `Request
    /// Alerts` action show whenever Push request-alert delivery is not
    /// effectively/stably enabled for this installation. Stable Push On
    /// (`.on`) is the only state that hides them; every other case —
    /// including the transitional `.settingUp` and `.ambiguous` — keeps them
    /// visible. This reads existing Push truth only; it is not a second
    /// source of truth.
    static func showsRequestAlertsPromotion(pushState: PushPreferenceState) -> Bool {
        pushState != .on
    }
}

/// Passively observed, presentation-only pull distance for the exchange
/// `ScrollView` — see `HomeExchangeView.pullOffset`'s doc comment. Read from
/// native scroll geometry; never written to by any custom gesture, and never
/// consulted to decide whether refresh fires.
private struct HomeExchangeScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// The authored pull/refreshing/recovery sequence (HQ decision 3; approved
/// Figma "MOTION HANDOFF · Unavailable Pull to Refresh", narrowed by Faith's
/// final H2 visual alignment FIX resolution to drop the motion handoff's
/// "Release threshold" phase — see below). Derived entirely from
/// passively-observed native scroll geometry (`HomeExchangeView.pullOffset`)
/// and the existing authoritative refresh lifecycle
/// (`isRefreshInFlight`/`isShowingRecoverySuccess`) — see
/// `HomeExchangeView.pullRefreshPhase`. Never itself decides whether refresh
/// fires.
///
/// There is deliberately no "release to refresh" phase: SwiftUI never
/// exposes `.refreshable`'s own internal activation distance, so no
/// presentation state here may claim releasing will trigger refresh — only
/// `.refreshing`, entered once `isRefreshInFlight` actually becomes true,
/// ever makes that claim. `.recoverySuccess` is not a generic "fetch
/// succeeded" phase (HQ decision 6): it is reached only when Home was
/// Exchange Unavailable immediately before the refresh and the authoritative
/// result now resolves to a genuinely healthy board state.
enum PullRefreshPhase: Equatable {
    case idle
    case pulling(progress: CGFloat)
    case refreshing
    case recoverySuccess
}

/// The single persistently-mounted refresh cue (Section 7/8/9/10), used both
/// as Exchange Unavailable's persistent discoverability cue (HQ decision 1,
/// `showsIdleInstruction: true`) and as the transient pull/refreshing/
/// recovery feedback shown across Populated, Low Activity, and Empty
/// Exchange (`showsIdleInstruction: false`, collapsed at `.idle`). One
/// `Image(systemName:)` slot carries every phase via `.contentTransition(
/// .symbolEffect(.replace))` rather than a `@ViewBuilder switch` producing a
/// different icon identity per phase — the production flash this replaces
/// came from exactly that identity churn plus conditional mounting. Reduce
/// Motion suppresses every glyph movement (spin, pull-progress offset/
/// opacity, and the recovery `.bounce`) while the glyph/text state change
/// still communicates every phase without it.
private struct PullRefreshCue: View {
    let phase: PullRefreshPhase
    let showsIdleInstruction: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSpinning = false
    /// Fences the delayed spin-start `Task` below against a later phase
    /// change invalidating it — the same generation-counter shape
    /// `RequestStore.fetchGeneration` already uses elsewhere in this
    /// codebase, sized down to this view's own local concern.
    @State private var spinGeneration = 0

    var body: some View {
        HStack(spacing: CommonPlateStyle.Spacing.xs) {
            icon
            if let text {
                Text(text)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .foregroundStyle(Color.accentColor)
        .opacity(isHidden ? 0 : 1)
        .accessibilityHidden(isHidden)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// `.idle` with no persistent instruction (Populated/Low Activity/Empty
    /// Exchange) collapses invisibly rather than being torn down — see
    /// `HomeExchangeView.refreshFeedbackBanner`'s own height/opacity
    /// collapse, which reserves this view's identity across phase changes.
    private var isHidden: Bool {
        phase == .idle && !showsIdleInstruction
    }

    @ViewBuilder
    private var icon: some View {
        Image(systemName: symbolName)
            .font(.body.weight(.semibold))
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .rotationEffect(.degrees(isSpinning && !reduceMotion ? 360 : 0))
            .symbolEffect(.bounce, options: .nonRepeating, value: !reduceMotion && phase == .recoverySuccess)
            .offset(y: reduceMotion ? 0 : pullOffsetY)
            .opacity(reduceMotion ? 1 : pullOpacity)
            .accessibilityHidden(true)
            .onAppear { updateSpinning() }
            .onChange(of: phase) { _, _ in updateSpinning() }
            .onChange(of: reduceMotion) { _, _ in updateSpinning() }
    }

    /// The pull arrow must not visibly rotate into the refreshing symbol —
    /// only the refreshing symbol itself spins. Starting the continuous
    /// rotation in the same instant `symbolName` switches to
    /// `arrow.triangle.2.circlepath` would apply that rotation to the
    /// `.contentTransition(.symbolEffect(.replace))` morph itself, reading
    /// as the old arrow rotating into place. Waiting for the morph's own
    /// duration to finish before starting the spin keeps the two motions
    /// separate: a clean symbol swap, then rotation only on the settled
    /// refresh glyph.
    private static let symbolMorphDuration: Duration = .milliseconds(350)

    private func updateSpinning() {
        spinGeneration += 1
        let generation = spinGeneration
        isSpinning = false
        guard phase == .refreshing, !reduceMotion else { return }
        Task {
            try? await Task.sleep(for: Self.symbolMorphDuration)
            guard generation == spinGeneration else { return }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                isSpinning = true
            }
        }
    }

    private var symbolName: String {
        switch phase {
        case .idle, .pulling:
            return "arrow.down"
        case .refreshing:
            return "arrow.triangle.2.circlepath"
        case .recoverySuccess:
            return "checkmark.circle.fill"
        }
    }

    private var pullOffsetY: CGFloat {
        guard case .pulling(let progress) = phase else { return 0 }
        return progress * 10
    }

    private var pullOpacity: Double {
        guard case .pulling(let progress) = phase else { return 1 }
        return 0.55 + Double(progress) * 0.45
    }

    private var text: String? {
        switch phase {
        case .idle, .pulling: return HomeExchangeView.refreshCueText
        case .refreshing: return HomeExchangeView.refreshingText
        case .recoverySuccess: return nil
        }
    }

    private var accessibilityLabel: String {
        switch phase {
        case .recoverySuccess: return HomeExchangeView.refreshSuccessText
        default: return text ?? ""
        }
    }
}
