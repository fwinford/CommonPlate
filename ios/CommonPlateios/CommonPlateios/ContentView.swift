import SwiftUI

struct ContentView: View {
    /// What the connected claim-to-placement flow does. Placement records an
    /// external order the helper has already completed; notification is a
    /// separate email attempt and is never described as delivery or reading.
    static let howItWorksSteps = [
        "1. A student posts a food request from an NYU dining spot.",
        "2. Another student with extra meal swipes chooses a request to help with.",
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

    /// The one navigation stack in the app, owned here so any screen inside it
    /// can leave a finished flow by rewriting the path rather than by asking a
    /// view below it to dismiss.
    @State private var path: [AppRoute] = []

    /// The one-time Home notice a requester-fulfillment push tap presents
    /// (Week 3 Day 6 Slice 6E). Distinct from every helper-flow notice: it
    /// carries no request identity and is shown only once per tap, exactly
    /// like the router's own exactly-once consumption guarantees.
    @State private var isShowingOrderPlacedNotice = false

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
                participantAuthorityRejected: { identityStore.discardRejectedIdentity() }
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
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 20) {
                Text("CommonPlate")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Need food, or have extra meal swipes you can use to help?")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                NavigationLink("I need food", value: AppRoute.requestFood)
                    .frame(maxWidth: 280)
                    .buttonStyle(.borderedProminent)

                NavigationLink("Help with a request", value: AppRoute.activeRequests)
                    .frame(maxWidth: 280)
                    .buttonStyle(.bordered)

                Text("Want to help later?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                // Stays deliberately broad. Today it opens the email screen;
                // naming it for email would have to be undone the moment there
                // is more than one way to be notified.
                NavigationLink("Notify me", value: AppRoute.alerts)
                    .frame(maxWidth: 280)
                    .buttonStyle(.bordered)

                VStack(alignment: .leading, spacing: 8) {
                    Text("How it works")
                        .font(.headline)

                    ForEach(Self.howItWorksSteps, id: \.self) { step in
                        Text(step)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)

                Divider()
                    .padding(.top, 12)

                participantIdentitySection

                NavigationLink("Privacy & Safety", value: AppRoute.privacySafety)
                    .frame(maxWidth: 280)
                    .buttonStyle(.plain)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            .padding(.top, 12)
            .padding()
            .navigationDestination(for: AppRoute.self) { route in
                destination(for: route)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                requestStore.revalidateActiveClaimExpiration()
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
            VStack(spacing: 4) {
                Text("Verified as \(identity.masked)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("home-verified-identity")

                Button(Self.changeEmailTitle) {
                    participantIdentityStore.beginEmailReplacement()
                }
                .buttonStyle(.plain)
                .font(.footnote)
                .accessibilityIdentifier("home-change-email")
            }
            .padding(.top, 4)
        } else {
            Text(Self.verificationRequirementNotice)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .accessibilityIdentifier("home-verification-requirement")
        }
    }

    static let changeEmailTitle = "Change email"

    /// The standing statement of the requirement. Deliberately not a call to
    /// verify: there is nothing to verify *for* yet, and asking someone to
    /// prove an address before they have decided to use the app would be the
    /// account signup this product does not have.
    static let verificationRequirementNotice =
        "You’ll verify an NYU email once before posting or helping with a request."

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
            RequestFoodEntryView(
                store: requestStore,
                identityStore: participantIdentityStore,
                verificationCoordinator: participantActionVerificationCoordinator,
                path: $path
            )
        case .activeRequests:
            ActiveRequestsView(store: requestStore)
        case .alerts:
            AlertSignupView(store: alertSubscriptionStore, pushStore: pushSubscriptionStore)
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
}

#Preview {
    ContentView(
        remoteNotificationRegistrar: UIKitRemoteNotificationRegistrar(),
        notificationRouter: HelperNotificationRouter()
    )
}
