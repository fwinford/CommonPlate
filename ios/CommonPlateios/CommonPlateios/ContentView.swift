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
    /// Request Food is one native presentation owned by Home, rather than a
    /// navigation destination that presents a second sheet on top of itself.
    /// Its local route remains available to the existing requester
    /// continuation machinery without creating a visible root-stack screen.
    @State private var isRequestFoodPresented = false
    @State private var requestFoodPresentationPath: [AppRoute] = []

    /// The one-time Home notice a requester-fulfillment push tap presents
    /// (Week 3 Day 6 Slice 6E). Distinct from every helper-flow notice: it
    /// carries no request identity and is shown only once per tap, exactly
    /// like the router's own exactly-once consumption guarantees.
    @State private var isShowingOrderPlacedNotice = false

    /// W3-I4: open only between tapping Remove Email and the mutation
    /// actually running. Cancel (or dismissing any other way) leaves
    /// `participantIdentityStore` untouched — the confirmation dialog itself
    /// has no side effect, only its destructive button does.
    @State private var isPresentingRemoveEmailConfirmation = false

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
                        shouldAnimate: flowPresentation == .route(route)
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

        }
        .sheet(isPresented: $isRequestFoodPresented, onDismiss: finishRequestFoodPresentation) {
            RequestFoodEntryView(
                store: requestStore,
                identityStore: participantIdentityStore,
                verificationCoordinator: participantActionVerificationCoordinator,
                path: $requestFoodPresentationPath,
                onExit: dismissRequestFoodPresentation
            )
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
        .onChange(of: scenePhase) { _, phase in
            let isActive = phase == .active
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
        // W3-I4: Cancel is the dialog's implicit dismissal path too — only
        // the destructive button below has any effect on
        // `participantIdentityStore`.
        .confirmationDialog(
            Self.removeEmailConfirmationTitle,
            isPresented: $isPresentingRemoveEmailConfirmation,
            titleVisibility: .visible
        ) {
            Button(Self.removeEmailTitle, role: .destructive) {
                participantIdentityStore.removeIdentity()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.removeEmailConfirmationMessage)
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

    /// The completion presentation is deliberately independent of the
    /// coordinator's synchronous completion state. The wrapper begins Home's
    /// arrival as the outgoing walkthrough fades, so the user sees one soft
    /// settle rather than a navigation pop followed by a second transition.
    private func recurringHome(brandHasSettled: Bool) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: CommonPlateStyle.Spacing.l) {
                    CommonPlateBrandHeader()
                        // This is intentionally only a slight extension of
                        // the screen-wide completion arrival.
                        .opacity(brandHasSettled ? 1 : 0)
                        .offset(y: brandHasSettled || reduceMotion ? 0 : 2)
                        .animation(brandLandingAnimation, value: brandHasSettled)

                    Spacer(minLength: CommonPlateStyle.Spacing.l)

                    VStack(spacing: CommonPlateStyle.Spacing.xs) {
                        VStack(spacing: CommonPlateStyle.Spacing.m) {
                            Button {
                                startRouteFlow(.requestFood)
                            } label: {
                                Text("Request a meal")
                            }
                            .commonPlateMajorPrimaryAction()
                            .commonPlateMajorActionFrame()
                            Button {
                                startRouteFlow(.activeRequests)
                            } label: {
                                Text("Find a request")
                            }
                            .commonPlateMajorSecondaryAction()
                            .commonPlateMajorActionFrame()
                        }

                        NavigationLink(value: AppRoute.alerts) {
                            Text("Request alerts")
                                .font(.body.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: 44,
                                    alignment: .center
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(CommonPlateFlatActionButtonStyle())
                    }
                    .frame(maxWidth: 520)

                    Spacer(minLength: CommonPlateStyle.Spacing.l)

                    utilityAndIdentityGroup
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, CommonPlateStyle.Spacing.l)
                .padding(.top, CommonPlateStyle.Spacing.l)
                .padding(.bottom, CommonPlateStyle.Spacing.xs)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
    }

    private var brandLandingAnimation: Animation {
        if reduceMotion {
            return .easeInOut(duration: 0.17)
        }
        return .timingCurve(0.22, 0.78, 0.24, 1, duration: 0.47)
    }

    private var utilityAndIdentityGroup: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
            NavigationLink(value: AppRoute.onboardingChooser) {
                UtilityActionRow(title: "How CommonPlate works")
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("home-how-commonplate-works")

            NavigationLink(value: AppRoute.privacySafety) {
                UtilityActionRow(title: "Privacy & Safety")
            }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)

            if participantIdentityStore.identity != nil {
                Divider()
                    .padding(.top, -CommonPlateStyle.Spacing.s)
                    .padding(.bottom, CommonPlateStyle.Spacing.xs)

                participantIdentitySection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CommonPlateStyle.Spacing.l)
        .padding(.vertical, CommonPlateStyle.Spacing.m)
        .background(
            CommonPlateStyle.Color.warmSurface,
            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
        )
    }

    private struct UtilityActionRow: View {
        let title: String

        var body: some View {
            HStack(spacing: CommonPlateStyle.Spacing.s) {
                Text(title)
                    .font(.body.weight(.semibold))
                Spacer(minLength: CommonPlateStyle.Spacing.s)
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: CommonPlateStyle.Control.minimumHeight)
            .contentShape(Rectangle())
        }
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
        guard route != .requestFood else {
            startRequestFoodPresentation()
            return
        }
        guard flowPresentation == nil else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            flowPresentation = .route(route)
            path = AppRoute.appending(route, to: path)
        }
    }

    private func startRequestFoodPresentation() {
        guard !isRequestFoodPresented else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            requestFoodPresentationPath = [.requestFood]
        }
        // This state change is intentionally outside that transaction: the
        // sheet is Request Food's single native visible entrance.
        isRequestFoodPresented = true
    }

    private func dismissRequestFoodPresentation() {
        isRequestFoodPresented = false
    }

    private func finishRequestFoodPresentation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            requestFoodPresentationPath = []
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
        @ViewBuilder let destination: () -> Destination
        let onFinished: () -> Void

        @State private var hasEntered: Bool

        init(
            reduceMotion: Bool,
            shouldAnimate: Bool,
            @ViewBuilder destination: @escaping () -> Destination,
            onFinished: @escaping () -> Void
        ) {
            self.reduceMotion = reduceMotion
            self.shouldAnimate = shouldAnimate
            self.destination = destination
            self.onFinished = onFinished
            _hasEntered = State(initialValue: !shouldAnimate)
        }

        var body: some View {
            ZStack {
                CommonPlateStyle.Color.baseCanvas.ignoresSafeArea()
                destination()
                    .opacity(hasEntered ? 1 : 0)
                    .offset(y: hasEntered || reduceMotion ? 0 : 6)
                    .animation(animation, value: hasEntered)
                    .allowsHitTesting(hasEntered)
                    .onAppear {
                        guard shouldAnimate, !hasEntered else { return }
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

    /// The remembered verified identity, and the way to replace it (W3-I1).
    ///
    /// Shown masked: enough for the student to confirm which of their addresses
    /// this device is acting as, without printing a full address onto a screen
    /// someone may be reading over their shoulder. When there is no identity
    /// this states the requirement instead, so the first gate on a request or a
    /// reservation is not the first time anyone hears about it.
    @ViewBuilder
    private var participantIdentitySection: some View {
        if let identity = participantIdentityStore.identity {
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
                Label(identity.masked, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("home-verified-identity")

                ViewThatFits(in: .horizontal) {
                    identityActions(axis: .horizontal)
                    identityActions(axis: .vertical)
                }

                if isRemoveEmailBlocked {
                    CommonPlateInlineStatus(
                        kind: removeEmailBlockedStatusKind,
                        message: removeEmailBlockedNotice
                    )
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("home-remove-email-blocked-notice")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func identityActions(axis: Axis) -> some View {
        if axis == .horizontal {
            HStack(spacing: CommonPlateStyle.Spacing.s) {
                changeEmailButton
                Text("·").foregroundStyle(.secondary)
                removeEmailButton
            }
        } else {
            VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
                changeEmailButton
                removeEmailButton
            }
        }
    }

    private var changeEmailButton: some View {
        Button(Self.changeEmailTitle) {
            participantIdentityStore.beginEmailReplacement()
        }
        .commonPlateTertiaryAction()
        // Keep the quiet inline text treatment while making the whole local
        // layout rect a minimum 44-point target.
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityIdentifier("home-change-email")
    }

    private var removeEmailButton: some View {
        Button(Self.removeEmailTitle, role: .destructive) {
            isPresentingRemoveEmailConfirmation = true
        }
        .commonPlateDestructiveAction()
        .disabled(isRemoveEmailBlocked)
        .accessibilityIdentifier("home-remove-email")
    }

    static let changeEmailTitle = "Change email"
    static let removeEmailTitle = "Remove email"

    /// Provisional (Faith reviews exact wording at acceptance, W3-I4).
    static let removeEmailConfirmationTitle = "Remove this email?"
    static let removeEmailConfirmationMessage =
        "You’ll need to verify an NYU email again before posting or helping with a request. Your request and help history is not affected."
    /// Provisional (Faith reviews exact wording at acceptance, W3-I4). Used
    /// while this process has not yet established backend-confirmed
    /// removal-safety truth (cold/relaunch reconciliation still pending) —
    /// deliberately silent about *which* blocker applies, since none is
    /// confirmed yet.
    static let removeEmailNotYetAvailableNotice =
        "Checking whether your email can be removed. Try again in a moment."
    /// Provisional (Faith reviews exact wording at acceptance, W3-I4). The
    /// student has an existing action (H1's own release/finish) that
    /// resolves this.
    static let removeEmailBlockedByReservationNotice =
        "You can’t remove your email while you have an active reservation or an in-progress request. Finish or release that first."
    /// Provisional (Faith reviews exact wording at acceptance, W3-I4). An
    /// unresolved W3-D1 create has no release/retry/discard action available
    /// to the student — it only resolves by CommonPlate's own reconciliation
    /// or expiry — so this must not instruct one.
    static let removeEmailBlockedByPendingCreateNotice =
        "CommonPlate is still confirming a request you submitted. You can remove your email once that finishes."

    /// W3-I4: exactly the A-classified blockers in the accepted removal-safety
    /// matrix — an active/continuing H1 reservation, in-flight fulfillment,
    /// and unresolved ambiguous-fulfillment recovery are all reflected by
    /// `activeClaim` staying non-nil until `clearActiveClaim()` runs (release,
    /// confirmed terminal outcome, or expiry); an unresolved W3-D1 create is
    /// `hasUnresolvedCreateAmbiguity`. Both are already-published
    /// `RequestStore` state. `!hasEstablishedRemovalSafety` additionally
    /// fails closed for the cold/relaunch window before either signal is
    /// backend-confirmed: at launch `activeClaim` starts `nil` and
    /// `hasUnresolvedCreateAmbiguity` starts `false` even when a prior
    /// process left an H1 reservation or an unresolved D1 create behind,
    /// because discovering either requires the still-in-flight
    /// `continueActiveReservationIfNeeded()`/
    /// `reconcilePendingCreateOperationIfNeeded()` calls `ContentView`'s own
    /// launch `.task` starts — without this, Remove Email would be
    /// available during exactly the window those calls exist to close.
    private var isRemoveEmailBlocked: Bool {
        !requestStore.hasEstablishedRemovalSafety
            || requestStore.activeClaim != nil
            || requestStore.hasUnresolvedCreateAmbiguity
    }

    /// The truthful blocked-state explanation for whichever reason
    /// `isRemoveEmailBlocked` is currently `true`, checked in the same
    /// precedence order. A pending readiness check is reported as such
    /// rather than guessing at a blocker that may not exist; when both an
    /// H1 and a D1 blocker are simultaneously present, the H1 copy is shown
    /// since it is the one the student has an existing action for.
    private var removeEmailBlockedNotice: String {
        if !requestStore.hasEstablishedRemovalSafety {
            return Self.removeEmailNotYetAvailableNotice
        }
        if requestStore.activeClaim != nil {
            return Self.removeEmailBlockedByReservationNotice
        }
        return Self.removeEmailBlockedByPendingCreateNotice
    }

    /// The shared semantic-state (W4-F1) treatment for whichever reason
    /// `removeEmailBlockedNotice` currently reports. Presentation only — it
    /// decides no blocking behavior itself, only how an already-decided
    /// reason looks.
    private var removeEmailBlockedStatusKind: CommonPlateStatusKind {
        Self.removeEmailBlockedStatusKind(
            hasEstablishedRemovalSafety: requestStore.hasEstablishedRemovalSafety,
            hasActiveClaim: requestStore.activeClaim != nil
        )
    }

    /// The pure mapping behind `removeEmailBlockedStatusKind`, extracted as a
    /// `static func` (matching the existing `ParticipantVerificationView`
    /// pure-predicate pattern) so it is directly testable without
    /// instantiating `ContentView`'s full store dependency graph. Mirrors
    /// `removeEmailBlockedNotice`'s exact precedence: the cold/relaunch
    /// readiness check reads as in-progress work (`.loading`); an active
    /// reservation/request reads as this action being temporarily
    /// unavailable, not gone (`.unavailable`); otherwise (the remaining
    /// blocked case is always an unresolved W3-D1 create, since this is only
    /// consulted while `isRemoveEmailBlocked` is true) an unresolved create
    /// is exactly a mutation-outcome-uncertain state (`.uncertain`).
    static func removeEmailBlockedStatusKind(
        hasEstablishedRemovalSafety: Bool,
        hasActiveClaim: Bool
    ) -> CommonPlateStatusKind {
        if !hasEstablishedRemovalSafety {
            return .loading
        }
        if hasActiveClaim {
            return .unavailable
        }
        return .uncertain
    }

    /// Open while a flow is running and Home is the surface presenting it. The
    /// request and reservation screens present their own gates, so this is
    /// scoped to the replacement flow Home actually started — otherwise a gate
    /// opened deeper in the stack would also raise a sheet here.
    private var isPresentingIdentityFlow: Binding<Bool> {
        Binding(
            get: {
                participantIdentityStore.flow?.purpose == .emailReplacement
                    && path.isEmpty
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
            EmptyView()
        case .activeRequests:
            ActiveRequestsView(store: requestStore)
        case .alerts:
            AlertSignupView(
                store: alertSubscriptionStore,
                pushStore: pushSubscriptionStore,
                unsubscribeStore: participantEmailUnsubscribeStore,
                identityStore: participantIdentityStore
            )
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
