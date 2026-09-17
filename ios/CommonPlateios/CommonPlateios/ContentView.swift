import SwiftUI

struct ContentView: View {
    /// What the connected claim-to-placement flow does. Placement records an
    /// external order the helper has already completed; notification is a
    /// separate email attempt and is never described as delivery or reading.
    /// Retained as a non-UI source of truth for the existing lifecycle tests;
    /// the student-facing explainer is now `OnboardingExperienceView`.
    static let howItWorksSteps = [
        "1. A student posts a food request from an NYU dining spot.",
        "2. A helper with extra meal swipes chooses a request to help with.",
        "3. The helper places the Grubhub order, then records the order number and pickup time.",
        "4. CommonPlate attempts to email the student the pickup details."
    ]

    @StateObject private var requestStore: RequestStore
    /// Alert signup keeps its own state owner. Its lifecycle, responses, and
    /// failures have nothing in common with the request flow's, and holding it
    /// here — rather than inside the screen — lets the accepted state survive
    /// leaving and reopening the screen. Across launches it survives instead
    /// through the store's own presentation storage, which remembers that the
    /// accepted response was seen and nothing about subscription status.
    @StateObject private var alertSubscriptionStore: AlertSubscriptionStore
    /// Push keeps its own state owner, independent of
    /// `alertSubscriptionStore`: per the Week 3 Day 6 cross-slice contract,
    /// email alerts and push notifications are separate controls with no
    /// shared state or error semantics.
    @StateObject private var pushSubscriptionStore: PushSubscriptionStore
    /// The participant-authorized "Turn off email alerts" action keeps its
    /// own state owner (W3-N2). It shares no state with
    /// `alertSubscriptionStore`: signup presentation history establishes no
    /// Subscriber truth, and this store's confirmed Off result is session-only
    /// and establishes no future On.
    @StateObject private var participantEmailUnsubscribeStore: ParticipantEmailUnsubscribeStore
    /// The one state owner for the W4-N0 authoritative Email Request Alert
    /// state read (`GET /api/participant/email-alerts/state`). Entirely
    /// separate from `alertSubscriptionStore` (signup presentation history)
    /// and `participantEmailUnsubscribeStore` (the Off mutation): this is the
    /// only source Settings' Email toggle may read On/Off from.
    @StateObject private var emailAlertStateStore: EmailAlertStateStore
    /// The one W4-S1 state owner for AI screenshot proposals. Entirely
    /// separate from `requestStore`: it never mutates a `Request`, mints an
    /// operation identity, or otherwise touches D1/create lifecycle — only
    /// the in-progress `RequestFoodFormDraft` it is handed.
    @StateObject private var screenshotProposalStore: ScreenshotProposalStore
    /// The bounded in-memory owner for one unfinished Request Food draft.
    /// Unlike D1's operation storage, this has no durable representation and
    /// exists only for this ContentView/app-process lifetime. Holding it above
    /// `.requestFood` lets an ordinary route pop/re-push restore the same task.
    @StateObject private var requestFoodDraftSession: RequestFoodDraftSession
    /// Local presentation preference only. It deliberately has no connection
    /// to participant identity, credentials, or backend authority.
    @StateObject private var onboardingStore: OnboardingPresentationStore
    @StateObject private var onboardingFlowCoordinator: OnboardingFlowCoordinator
    /// Participant identity keeps its own state owner (W3-I1). It is not
    /// subscription state and not installation state: it is the one thing in
    /// the app that represents a person, every participant action reads it, and
    /// holding it here is what lets a verified identity survive leaving and
    /// reopening any screen.
    @StateObject private var participantIdentityStore: ParticipantIdentityStore
    /// The one operation-scoped verification continuation owner (W3-I1).
    /// Request and helper views report their lifecycle signals to this same
    /// production object, so a competing screen cannot manufacture or consume
    /// a continuation by observing global identity publication.
    @StateObject private var participantActionVerificationCoordinator:
        ParticipantActionVerificationCoordinator
    /// Shared with `PushAppDelegate`, which wires it as
    /// `UNUserNotificationCenter`'s delegate before this view exists — see
    /// `CommonPlateiosApp.swift`. Observed here, not owned, so a tap captured
    /// before launch or while another screen was showing is still picked up
    /// once this view is ready to navigate.
    @ObservedObject private var notificationRouter: HelperNotificationRouter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The one navigation stack in the app, owned here so any screen inside it
    /// can leave a finished flow by rewriting the path rather than by asking a
    /// view below it to dismiss.
    @State private var path: [AppRoute] = []
    /// A presentation-only handoff for major actions that start a task. Unlike
    /// `path` and onboarding completion, this never establishes app truth.
    @State private var flowPresentation: FlowPresentation?

    /// The one-time Home notice a requester-fulfillment push tap presents
    /// (Week 3 Day 6 Slice 6E). Distinct from every helper-flow notice: it
    /// carries no request identity and is shown only once per tap, exactly
    /// like the router's own exactly-once consumption guarantees.
    @State private var isShowingOrderPlacedNotice = false

    /// W4-H1: owns the helper success presentation's active-scene-aware
    /// progression and its exactly-once haptic, announcement, and Home
    /// return. Presentation only — never persisted and never consulted by any
    /// lifecycle decision.
    @StateObject private var helperSuccessCoordinator = HelperSuccessPresentationCoordinator()

    /// `remoteNotificationRegistrar` must be the same instance
    /// `PushAppDelegate` forwards APNs callbacks into — see
    /// `CommonPlateiosApp.swift` — so, matching every other injected
    /// dependency here, it has no default: no caller can reach a
    /// disconnected registrar by omission. `notificationRouter` has no
    /// default for the same reason: a fresh, disconnected router would never
    /// see the tap `PushAppDelegate`'s instance actually captured.
    init(
        remoteNotificationRegistrar: RemoteNotificationRegistering,
        notificationRouter: HelperNotificationRouter
    ) {
        self.notificationRouter = notificationRouter
        let client = APIClient(configuration: .localSimulator)
        let service = RequestService(client: client)
        // The app's real installation-identity storage, shared by
        // `RequestStore` (which only ever reads the stable credential) and
        // `PushSubscriptionStore` (which owns the rest of the push-preference
        // lifecycle). One instance so both read the same credential a fresh
        // one per store could not guarantee.
        let installationStorage = UserDefaultsPushInstallationStorage(defaults: .standard)
        // Built before `RequestStore`, which reads its credential on every
        // participant action. `identityStore` is captured by the two closures
        // below rather than by the store itself, so `RequestStore` still knows
        // nothing about verification beyond "here is a credential, and here is
        // what to do when the backend refuses it".
        let identityStore = ParticipantIdentityStore(
            service: ParticipantVerificationService(client: client),
            // The app's real preferences. Tests inject an isolated suite or an
            // in-memory double instead, which is why this argument has no
            // default.
            storage: UserDefaultsParticipantIdentityStorage(defaults: .standard)
        )
        _participantIdentityStore = StateObject(wrappedValue: identityStore)
        _participantActionVerificationCoordinator = StateObject(
            wrappedValue: ParticipantActionVerificationCoordinator(
                identityStore: identityStore
            )
        )
        _requestStore = StateObject(
            wrappedValue: RequestStore(
                service: service,
                installationCredentialProvider: installationStorage.installationCredential,
                participantAuthorityProvider: { identityStore.currentAuthority() },
                participantAuthorityRejected: { identityStore.discardRejectedIdentity() },
                reservationWarningScheduler: UNUserNotificationCenterReservationWarningScheduler(),
                // The app's real durable storage (W3-D1), so an unresolved
                // request-create operation survives app/process termination.
                // Tests inject an isolated suite or an in-memory double
                // instead, matching every other real-storage argument here.
                operationStorage: UserDefaultsPendingRequestOperationStorage(defaults: .standard)
            )
        )
        _alertSubscriptionStore = StateObject(
            wrappedValue: AlertSubscriptionStore(
                service: AlertSubscriptionService(client: client),
                // The app's real preferences. Tests inject an isolated suite or
                // an in-memory double instead, which is why this argument has
                // no default.
                presentationStorage: UserDefaultsAlertSignupPresentationStorage(defaults: .standard)
            )
        )
        _pushSubscriptionStore = StateObject(
            wrappedValue: PushSubscriptionStore(
                service: InstallationPushService(client: client),
                installationStorage: installationStorage,
                authorizationCoordinator: UNUserNotificationCenterAuthorizationCoordinator(),
                remoteNotificationRegistrar: remoteNotificationRegistrar,
                settingsOpener: UIApplicationPushSettingsOpener()
            )
        )
        _participantEmailUnsubscribeStore = StateObject(
            wrappedValue: ParticipantEmailUnsubscribeStore(
                service: ParticipantEmailUnsubscribeService(client: client)
            )
        )
        _emailAlertStateStore = StateObject(
            wrappedValue: EmailAlertStateStore(
                service: EmailAlertStateService(client: client),
                participantAuthorityProvider: { identityStore.currentAuthority() },
                participantAuthorityRejected: { identityStore.discardRejectedIdentity() }
            )
        )
        _screenshotProposalStore = StateObject(
            wrappedValue: ScreenshotProposalStore(
                service: ScreenshotProposalService(client: client),
                // The app's real preferences. Tests inject an isolated suite
                // or an in-memory double instead, matching every other
                // real-storage argument here.
                preferences: UserDefaultsScreenshotProposalPreferencesStorage(defaults: .standard)
            )
        )
        _requestFoodDraftSession = StateObject(wrappedValue: RequestFoodDraftSession())
        let onboardingStore = OnboardingPresentationStore(
            storage: UserDefaultsOnboardingPresentationStorage(defaults: .standard)
        )
        _onboardingStore = StateObject(wrappedValue: onboardingStore)
        _onboardingFlowCoordinator = StateObject(
            wrappedValue: OnboardingFlowCoordinator(presentationStore: onboardingStore)
        )
    }

    var body: some View {
        ZStack {
            NavigationStack(path: $path) {
                Group {
                    if onboardingStore.hasCompletedOnboarding {
                        recurringHome(brandHasSettled: true)
                    } else {
                        OnboardingExperienceView(onStartFlow: startWalkthroughFlow)
                    }
                }
                .navigationDestination(item: $onboardingFlowCoordinator.selectedIntent) { intent in
                    SoftFlowEnterDestination(
                        reduceMotion: reduceMotion,
                        shouldAnimate: flowPresentation == .walkthrough(intent)
                    ) {
                        OnboardingWalkthroughView(intent: intent) {
                            completeOnboardingFromWalkthrough()
                        } onBack: {
                            onboardingFlowCoordinator.selectedIntent = nil
                        }
                    } onFinished: {
                        finishSoftFlowEntrance(.walkthrough(intent))
                    }
                }
                .navigationDestination(for: AppRoute.self) { route in
                    SoftFlowEnterDestination(
                        reduceMotion: reduceMotion,
                        shouldAnimate: flowPresentation == .route(route),
                        // W4-R2 2026-09-05 sync item 8: Request Food owns its
                        // own local Bottom Continuity settle
                        // (`RequestFoodEntryView`'s `hasSettled`), which never
                        // gates hit testing. This shared wrapper's own
                        // opacity/offset settle and hit-testing gate would
                        // otherwise duplicate that cue and reintroduce a
                        // decorative delay to interactivity for this route
                        // specifically. Every other route keeps this
                        // wrapper's existing entrance exactly as it is today.
                        playsOwnSettle: route != .requestFood
                    ) {
                        destination(for: route)
                    } onFinished: {
                        finishSoftFlowEntrance(.route(route))
                    }
                }
            }

            if let intent = onboardingFlowCoordinator.completionPresentationIntent {
                SoftBrandSettlePresentation(
                    intent: intent,
                    reduceMotion: reduceMotion,
                    home: { brandHasSettled in
                        recurringHome(brandHasSettled: brandHasSettled)
                    },
                    onFinished: onboardingFlowCoordinator.finishCompletionPresentation
                )
                .zIndex(1)
            }

            // W4-H1: shown only while an in-process, authoritatively confirmed
            // placement exists. Relaunch never restores a confirmation, so it
            // never reconstructs this presentation, its haptic, or its Home
            // return.
            if let confirmation = requestStore.fulfillmentConfirmation {
                HelperSuccessView(
                    confirmation: confirmation,
                    phase: helperSuccessPhase(for: confirmation),
                    reduceMotion: reduceMotion
                )
                .id(confirmation.id)
                .transition(.opacity)
                .zIndex(2)
            }
        }
        // Cold-launch and relaunch-after-termination continuation (W3-H1):
        // reconstructs "do I have an active reservation" from backend truth,
        // since a terminated process discarded whatever `RequestStore` held
        // in memory. Runs once at this view's first appearance; a no-op on
        // every call after the first successfully resolves one, and a no-op
        // immediately if `RequestStore` already holds a claim from `claim()`
        // in the same process.
        .task {
            let isActive = scenePhase == .active
            installHelperSuccessHomeReturn()
            helperSuccessCoordinator.updateSceneActivity(isActive: isActive)
            notificationRouter.updateApplicationSceneActivity(isActive: isActive)
            requestStore.updateApplicationVisibility(isVisible: isActive)
            _ = try? await requestStore.continueActiveReservationIfNeeded()
            // W3-D1 cold-launch/relaunch reconciliation: resumes and
            // reconciles an unresolved request-create operation left over
            // from a previous process, using the exact same operation
            // identity and submitted fields as the original attempt. A no-op
            // whenever nothing durable remains.
            _ = await requestStore.reconcilePendingCreateOperationIfNeeded()
        }
        // W4-D2: whose unresolved create operation blocks creation and
        // Remove Email depends on the participant current now, so the block
        // is re-derived whenever that identity changes. Local only: an
        // identity arriving never triggers a reconciliation by itself.
        .onChange(of: participantIdentityStore.identity) { _, _ in
            requestStore.refreshPendingCreateState()
        }
        .onChange(of: scenePhase) { _, phase in
            let isActive = phase == .active
            // W4-H1: success progression counts only active time.
            helperSuccessCoordinator.updateSceneActivity(isActive: isActive)
            notificationRouter.updateApplicationSceneActivity(isActive: isActive)
            requestStore.updateApplicationVisibility(isVisible: isActive)
            if phase == .active {
                // Detects a notification permission changed in Settings, and
                // silently re-registers an installation that was previously
                // confirmed on. Never shows Apple's permission prompt.
                Task { await pushSubscriptionStore.refreshAuthorizationStatus() }
                // The second chance a launch-time tap needs. The `.task`
                // below is the normal trigger, but on a cold launch the tap
                // is captured before this view exists and its first routing
                // attempt can be cancelled while SwiftUI is still building
                // the scene — the attempt then, correctly, leaves the tap
                // pending rather than dropping it. The scene actually
                // becoming active is a real readiness signal (not a guessed
                // delay) and the point at which retrying is guaranteed to
                // find a live view, so a tap that survived an unfinished
                // attempt is routed here. With nothing pending this is an
                // immediate no-op, and running alongside the `.task` is safe
                // — see `HelperNotificationRouteDriver.routeIfNeeded`.
                Task { await routePendingHelperNotification() }
                // Same second-chance reasoning for a reservation-warning tap
                // (W3-H1).
                Task { await routePendingReservationWarning() }
            }
        }
        // Reruns whenever a *new* tap intent is captured, including the
        // first one on the initial run — which is what makes a tap captured
        // before this view existed (a cold launch) reach here the first time
        // it can — and again whenever this view is rebuilt, which is what
        // lets a cold launch's cancelled first attempt be retried. Keyed on
        // `routingGeneration`, not `pendingRequestID`: retiring a routed
        // intent clears the pending value, but that clear does not advance
        // the generation, so it cannot rewrite this task's own id and cancel
        // the resolution the task just started. A later unrelated rerun
        // replays nothing, because an already-applied tap is no longer
        // pending and nothing but a fresh tap advances the generation.
        .task(id: notificationRouter.routingGeneration) {
            await routePendingHelperNotification()
        }
        // The reservation-warning tap's own trigger (W3-H1), independent of
        // `routingGeneration` above for the identical self-cancellation
        // reason `HelperNotificationRouter.reservationWarningRoutingGeneration`
        // documents.
        .task(id: notificationRouter.reservationWarningRoutingGeneration) {
            await routePendingReservationWarning()
        }
        // The foreground half of the same warning (W3-H1): no notification
        // tap is involved when CommonPlate is already visible when the
        // five-minute mark arrives, so this is the one place that path
        // still has to land on the reservation screen. A no-op if already
        // there — `AppRoute.appending` only pushes when it is not already on
        // top — so this cannot duplicate the destination if the helper had
        // already navigated there themselves.
        .onChange(of: requestStore.isShowingReservationWarning) { _, isWarning in
            guard isWarning, let activeClaim = requestStore.activeClaim else { return }
            path = AppRoute.appending(.fulfillment(activeClaim.request), to: [.activeRequests])
        }
        // A requester-fulfillment tap always opens Home (`path = []`) and
        // presents this one-time notice, per its own independently-numbered
        // intent — distinct from `routingGeneration` above, so a helper tap
        // and a requester-fulfillment tap can never consume or replay each
        // other's route. Presentation happens through
        // `presentNextRequesterFulfillmentNoticeIfPossible()`, which also
        // runs from `isShowingOrderPlacedNotice` actually going back to
        // `false` below, so a notice still queued behind an already-visible
        // alert gets presented next rather than stranded; the router itself
        // decides, from each queued intent's own frozen capture-time
        // snapshot, whether a dequeued notice is still presentable.
        .task(id: notificationRouter.requesterFulfillmentRoutingGeneration) {
            presentNextRequesterFulfillmentNoticeIfPossible()
        }
        .sheet(isPresented: isPresentingIdentityFlow) {
            ParticipantVerificationView(store: participantIdentityStore)
        }
        .alert("Your order was placed.", isPresented: $isShowingOrderPlacedNotice) {
            Button("OK", role: .cancel) {}
        }
        // The drain trigger belongs here, not in the button's action above.
        // `.alert(isPresented:)`'s button action runs *before* SwiftUI has
        // actually flipped `isShowingOrderPlacedNotice` back to `false` —
        // calling the drain from there always found the guard still true and
        // silently no-opped, which is exactly how a second queued notice
        // stayed stranded. The binding itself going to `false` is the one
        // signal that is actually true when it fires, regardless of how the
        // alert was dismissed (this button, a swipe, or anything else), so
        // draining from here is what makes it reliable. Re-entrant safety:
        // when this finds another notice and sets the binding back to
        // `true`, that change re-runs this same `onChange`, but its own
        // `newValue == true` short-circuits it immediately, so presenting
        // the next notice can never itself trigger another drain attempt.
        .onChange(of: isShowingOrderPlacedNotice) { _, isVisible in
            guard !isVisible else { return }
            presentNextRequesterFulfillmentNoticeIfPossible()
        }
        // W4-H1: an authoritative confirmation — including one recorded while
        // inactive — begins its presentation; retiring it ends it.
        .onChange(of: requestStore.fulfillmentConfirmation?.id) { _, _ in
            helperSuccessCoordinator.update(
                confirmation: requestStore.fulfillmentConfirmation,
                reduceMotion: reduceMotion
            )
        }
        .onChange(of: path) { _, newPath in
            if case .route(let route)? = flowPresentation, newPath.last != route {
                flowPresentation = nil
            }
            onboardingFlowCoordinator.replayNavigationChanged(
                isChooserInPath: newPath.contains(.onboardingChooser)
            )
        }
        .onChange(of: onboardingFlowCoordinator.selectedIntent) { _, intent in
            if case .walkthrough? = flowPresentation, intent == nil {
                flowPresentation = nil
            }
        }
    }

    /// W4-H2: the live CommonPlate exchange supersedes R1's recurring static
    /// launcher as Home's recurring content. The completion presentation is
    /// deliberately independent of the coordinator's synchronous completion
    /// state — the wrapper begins Home's arrival as the outgoing walkthrough
    /// fades, so the user sees one soft settle rather than a navigation pop
    /// followed by a second transition; that fade-in behavior is preserved
    /// here unchanged, now applied to the exchange view instead of a single
    /// brand header.
    private func recurringHome(brandHasSettled: Bool) -> some View {
        HomeExchangeView(
            store: requestStore,
            identityStore: participantIdentityStore,
            alertSubscriptionStore: alertSubscriptionStore,
            pushSubscriptionStore: pushSubscriptionStore,
            unsubscribeStore: participantEmailUnsubscribeStore,
            onRequestMeal: { startRouteFlow(.requestFood) }
        )
        .opacity(brandHasSettled ? 1 : 0)
        .offset(y: brandHasSettled || reduceMotion ? 0 : 2)
        .animation(brandLandingAnimation, value: brandHasSettled)
    }

    private var brandLandingAnimation: Animation {
        if reduceMotion {
            return .easeInOut(duration: 0.17)
        }
        return .timingCurve(0.22, 0.78, 0.24, 1, duration: 0.47)
    }

    /// A completion-only overlay that keeps the outgoing walkthrough and the
    /// already-correct Home alive in the same render pass. Navigation and
    /// persistence finish before this appears; it owns only the visible handoff.
    private struct SoftBrandSettlePresentation<Home: View>: View {
        let intent: OnboardingIntent
        let reduceMotion: Bool
        @ViewBuilder let home: (Bool) -> Home
        let onFinished: () -> Void

        @State private var hasArrived = false

        var body: some View {
            ZStack {
                home(hasArrived)
                    .opacity(hasArrived ? 1 : 0)
                    .offset(y: hasArrived || reduceMotion ? 0 : 9)
                    .animation(homeArrivalAnimation, value: hasArrived)

                OnboardingWalkthroughView(intent: intent, onContinue: {})
                    .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
                    .opacity(hasArrived ? 0 : 1)
                    .offset(y: hasArrived || reduceMotion ? 0 : -7)
                    .animation(walkthroughExitAnimation, value: hasArrived)
            }
            .allowsHitTesting(false)
            .onAppear {
                guard !hasArrived else { return }
                withAnimation(completionAnimation, completionCriteria: .logicallyComplete) {
                    hasArrived = true
                } completion: {
                    onFinished()
                }
            }
        }

        private var homeArrivalAnimation: Animation {
            if reduceMotion {
                return .easeInOut(duration: 0.17)
            }
            return .timingCurve(0.22, 0.78, 0.24, 1, duration: 0.43)
        }

        private var walkthroughExitAnimation: Animation {
            reduceMotion
                ? .easeInOut(duration: 0.17)
                : .easeInOut(duration: 0.31)
        }

        private var completionAnimation: Animation {
            reduceMotion
                ? .easeInOut(duration: 0.17)
                : .timingCurve(0.22, 0.78, 0.24, 1, duration: 0.47)
        }
    }

    private enum FlowPresentation: Hashable {
        case walkthrough(OnboardingIntent)
        case route(AppRoute)
    }

    private func startWalkthroughFlow(_ intent: OnboardingIntent) {
        guard flowPresentation == nil else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            flowPresentation = .walkthrough(intent)
            onboardingFlowCoordinator.selectedIntent = intent
        }
    }

    private func startRouteFlow(_ route: AppRoute) {
        guard flowPresentation == nil else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            flowPresentation = .route(route)
            path = AppRoute.appending(route, to: path)
        }
    }

    private func finishSoftFlowEntrance(_ presentation: FlowPresentation) {
        guard flowPresentation == presentation else { return }
        flowPresentation = nil
    }

    /// A lighter sibling to Soft Brand Settle for actions that begin work.
    /// The real in-stack destination is inserted before this runs. It is never
    /// rendered as a temporary overlay and exchanged for a second copy.
    private struct SoftFlowEnterDestination<Destination: View>: View {
        let reduceMotion: Bool
        let shouldAnimate: Bool
        /// W4-R2 2026-09-05 sync item 8: defaults to `true`, preserving this
        /// shared wrapper's existing opacity/offset settle and hit-testing
        /// gate for every route unrelated to that sync's Request Food fix —
        /// only `.requestFood`'s own call site passes `false`.
        var playsOwnSettle: Bool = true
        @ViewBuilder let destination: () -> Destination
        let onFinished: () -> Void

        @State private var hasEntered: Bool

        init(
            reduceMotion: Bool,
            shouldAnimate: Bool,
            playsOwnSettle: Bool = true,
            @ViewBuilder destination: @escaping () -> Destination,
            onFinished: @escaping () -> Void
        ) {
            self.reduceMotion = reduceMotion
            self.shouldAnimate = shouldAnimate
            self.playsOwnSettle = playsOwnSettle
            self.destination = destination
            self.onFinished = onFinished
            _hasEntered = State(initialValue: !shouldAnimate)
        }

        var body: some View {
            ZStack {
                CommonPlateStyle.Color.baseCanvas.ignoresSafeArea()
                destination()
                    .opacity(playsOwnSettle ? (hasEntered ? 1 : 0) : 1)
                    .offset(y: playsOwnSettle && !hasEntered && !reduceMotion ? 6 : 0)
                    .animation(playsOwnSettle ? animation : nil, value: hasEntered)
                    .allowsHitTesting(playsOwnSettle ? hasEntered : true)
                    .onAppear {
                        guard shouldAnimate, !hasEntered else { return }
                        guard playsOwnSettle else {
                            // This route owns its own local settle cue
                            // instead (never gated on hit testing); this
                            // wrapper only still needs to retire
                            // `flowPresentation` via `onFinished()` exactly
                            // once, with no animation or gating of its own.
                            hasEntered = true
                            onFinished()
                            return
                        }
                        withAnimation(animation, completionCriteria: .logicallyComplete) {
                            hasEntered = true
                        } completion: {
                            onFinished()
                        }
                    }
            }
        }

        private var animation: Animation {
            reduceMotion
                ? .easeInOut(duration: 0.17)
                : .timingCurve(0.22, 0.78, 0.24, 1, duration: 0.28)
        }
    }

    /// The pure predicate behind Settings' Remove Email blocked-status
    /// presentation (`SettingsView`, W4-H2), kept here as a `static func` so
    /// it is directly testable without instantiating a full store dependency
    /// graph — matching the existing `ParticipantVerificationView`
    /// pure-predicate pattern. Precedence: while the cold/relaunch readiness
    /// check is actively in flight, it reads as in-progress work (`.loading`);
    /// once that check has ended without establishing removal safety (W4-R2
    /// 2026-09-06 sync), it reads as this action being temporarily
    /// unavailable, not still loading (`.unavailable`) — the same kind an
    /// active reservation/request already uses; otherwise (an unresolved
    /// W3-D1 create) is exactly a mutation-outcome-uncertain state
    /// (`.uncertain`).
    static func removeEmailBlockedStatusKind(
        hasEstablishedRemovalSafety: Bool,
        isResolvingReservationStateForRemoval: Bool,
        hasActiveClaim: Bool
    ) -> CommonPlateStatusKind {
        if !hasEstablishedRemovalSafety {
            return isResolvingReservationStateForRemoval ? .loading : .unavailable
        }
        if hasActiveClaim {
            return .unavailable
        }
        return .uncertain
    }

    /// Open while a flow is running and Home or Settings — W4-H2's own
    /// entry point for Change Email — is the surface presenting it. The
    /// request and reservation screens present their own gates, so this
    /// stays scoped to exactly the two surfaces that actually start this
    /// flow: nothing pushed (Home) or Settings alone with nothing pushed
    /// past it, so a gate opened deeper in the stack still does not also
    /// raise a sheet here.
    private var isPresentingIdentityFlow: Binding<Bool> {
        Binding(
            get: {
                participantIdentityStore.flow?.purpose == .emailReplacement
                    && (path.isEmpty || path == [.settings])
            },
            set: { isPresented in
                if !isPresented { participantIdentityStore.cancelVerification() }
            }
        )
    }

    /// Applies whatever helper new-request tap is currently pending, if any.
    /// All of the decision-making — resolving `requestId` against backend
    /// truth, tap-order fencing, the recovery notices, and when the tap may
    /// finally be retired — lives in `HelperNotificationRouteDriver`, which
    /// is testable without SwiftUI; this only owns the one thing that cannot
    /// leave the view, writing `path`.
    ///
    /// A `nil` result never means Home. It means this attempt produced no
    /// navigation outcome — nothing pending, cancelled, or superseded by a
    /// later tap — and in every one of those cases leaving `path` exactly as
    /// it is, is the correct answer. A tap that was cancelled mid-attempt is
    /// still pending afterwards and gets applied by the next attempt.
    private func routePendingHelperNotification() async {
        guard let resolvedPath = await HelperNotificationRouteDriver.routeIfNeeded(
            router: notificationRouter,
            resolver: requestStore
        ) else {
            return
        }
        path = resolvedPath
    }

    /// The reservation-warning equivalent (W3-H1): applies whatever
    /// reservation-warning notification tap is currently pending, if any. See
    /// `ReservationWarningRouteDriver` for the decision-making this only
    /// applies the result of.
    private func routePendingReservationWarning() async {
        guard let resolvedPath = await ReservationWarningRouteDriver.routeIfNeeded(
            router: notificationRouter,
            resolver: requestStore
        ) else {
            return
        }
        path = resolvedPath
    }

    /// Presents the next presentable queued requester-fulfillment notice, if
    /// nothing is currently on screen. `consumeNextPresentableRequesterFulfillmentNotice()`
    /// does the actual staleness fencing (see `HelperNotificationRouter`):
    /// this only decides whether now is a valid moment to show anything at
    /// all. A call that finds the alert already visible returns without
    /// touching the router's queue, so whatever is queued stays queued
    /// rather than being drained while invisible. Called from a fresh tap's
    /// own `.task` above, and from `isShowingOrderPlacedNotice` actually
    /// becoming `false` below — never from the alert button's own action,
    /// which fires too early to see that transition yet; see the `onChange`
    /// site for why.
    private func presentNextRequesterFulfillmentNoticeIfPossible() {
        guard !isShowingOrderPlacedNotice else { return }
        guard notificationRouter.consumeNextPresentableRequesterFulfillmentNotice() else { return }
        path = []
        isShowingOrderPlacedNotice = true
    }

    /// The single place a route becomes a screen. The two helper-flow screens
    /// receive the path itself: both of them have to be able to end the flow,
    /// and neither can do that by dismissing only itself.
    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .requestFood:
            // W4-R2: pushed on this same root stack (superseding the former
            // Home-owned sheet), analogous to `.settings`. `onExit` truncates
            // exactly this route via `finishPrimaryRoute`, so ordinary Back,
            // D1 "Go to Home", and the Success dwell's native dismissal all
            // return to Home the same way.
            RequestFoodEntryView(
                store: requestStore,
                screenshotProposalStore: screenshotProposalStore,
                draftSession: requestFoodDraftSession,
                identityStore: participantIdentityStore,
                verificationCoordinator: participantActionVerificationCoordinator,
                path: $path,
                onExit: { finishPrimaryRoute(.requestFood) }
            )
        case .activeRequests:
            ActiveRequestsView(store: requestStore)
        case .alerts:
            AlertSignupView(
                store: alertSubscriptionStore,
                pushStore: pushSubscriptionStore,
                unsubscribeStore: participantEmailUnsubscribeStore,
                identityStore: participantIdentityStore
            )
            .navigationTitle(AlertSignupView.title)
            .navigationBarTitleDisplayMode(.inline)
        case .onboardingChooser:
            OnboardingExperienceView(
                onStartFlow: startWalkthroughFlow,
                onBack: { path.removeLast() }
            )
                .navigationBarBackButtonHidden(true)
                .toolbar(.hidden, for: .navigationBar)
                .onAppear {
                    onboardingFlowCoordinator.beginReplay()
                }
        case .privacySafety:
            PrivacySafetyView()
        case .settings:
            SettingsView(
                requestStore: requestStore,
                participantIdentityStore: participantIdentityStore,
                alertSubscriptionStore: alertSubscriptionStore,
                pushSubscriptionStore: pushSubscriptionStore,
                unsubscribeStore: participantEmailUnsubscribeStore,
                emailAlertStateStore: emailAlertStateStore,
                screenshotProposalStore: screenshotProposalStore
            )
        case .support:
            SupportView()
        case .requestDetail(let request):
            RequestDetailView(
                request: request,
                store: requestStore,
                identityStore: participantIdentityStore,
                verificationCoordinator: participantActionVerificationCoordinator,
                path: $path
            )
        case .fulfillment(let request):
            FulfillRequestView(request: request, store: requestStore, path: $path)
        case .ownRequests(let requests):
            OwnRequestsListView(requests: requests)
        }
    }

    private func completeOnboardingFromWalkthrough() {
        // Product truth changes now, independently of the presentation-only
        // Soft Brand Settle. Disabling native stack animation prevents a pop
        // from taking ownership while the overlay performs the visible exit.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            onboardingFlowCoordinator.continueFromWalkthrough()
            path = []
        }
    }

    private func helperSuccessPhase(
        for confirmation: FulfillmentConfirmation
    ) -> HelperSuccessProgression.Phase {
        guard let progression = helperSuccessCoordinator.progression,
              progression.confirmationID == confirmation.id else {
            return .ticket
        }
        return progression.phase
    }

    /// The one automatic Home return after a complete foreground success
    /// presentation, whatever the helper's entry point, then retirement of the
    /// presentation. The path is replaced without a native pop so Home is
    /// simply revealed as the presentation fades.
    private func installHelperSuccessHomeReturn() {
        let pathBinding = $path
        let store = requestStore
        helperSuccessCoordinator.returnHome = { confirmation in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                pathBinding.wrappedValue = AppRoute.afterHelperSuccess(from: pathBinding.wrappedValue)
            }
            withAnimation(.easeOut(duration: 0.2)) {
                store.dismissFulfillmentConfirmation(id: confirmation.id)
            }
        }
    }

    /// Request Food owns a vertical Soft Flow transition. Removing its typed
    /// route without a native pop keeps Home stable beneath that one motion.
    private func finishPrimaryRoute(_ route: AppRoute) {
        guard path.last == route else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            _ = path.removeLast()
        }
    }
}

#Preview {
    ContentView(
        remoteNotificationRegistrar: UIKitRemoteNotificationRegistrar(),
        notificationRouter: HelperNotificationRouter()
    )
}
