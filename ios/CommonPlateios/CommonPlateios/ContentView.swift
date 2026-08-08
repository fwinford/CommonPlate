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
        _requestStore = StateObject(
            wrappedValue: RequestStore(
                service: service,
                installationCredentialProvider: installationStorage.installationCredential
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
            }
        }
        // Reruns whenever a *new* tap intent is captured, including the
        // first one on the initial run — which is what makes a tap captured
        // before this view existed (a cold launch) reach here the first time
        // it can. Keyed on `routingGeneration`, not `pendingRequestID`:
        // `consumePendingRequestID()` clears the pending value as part of
        // reading it, but that clear does not advance the generation, so it
        // cannot rewrite this task's own id and cancel the resolution the
        // task just started. A later unrelated rerun replays nothing because
        // nothing but a fresh tap advances the generation.
        .task(id: notificationRouter.routingGeneration) {
            // `pendingRequestTapSequence` is read *before* consuming, and
            // both come from the same still-unconsumed `pendingHelperIntent`
            // in the router — this tap's own frozen claim on
            // `latestTapSequence`, assigned the instant the router received
            // it. It is deliberately not read from `latestTapSequence`
            // itself here: this closure's *start* can be delayed by
            // SwiftUI's own task scheduling after `routingGeneration`
            // changes, and a further tap can advance that counter in the
            // gap, which would misattribute a later tap's value to this one.
            guard let tapSequence = notificationRouter.pendingRequestTapSequence,
                  let requestID = notificationRouter.consumePendingRequestID() else {
                return
            }
            await routeToNotification(requestID: requestID, tapSequence: tapSequence)
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

    /// Resolves a helper new-request notification's `requestId` against
    /// backend truth and replaces the navigation path with the result.
    /// Cancellation (the view went away mid-resolution) leaves the path
    /// untouched rather than guessing. `requestId` is routing context only;
    /// only backend truth may decide available, unavailable, or that truth
    /// could not currently be established.
    ///
    /// `tapSequence` is this resolution's own claim on
    /// `notificationRouter.latestTapSequence`, frozen in the router at the
    /// moment this tap was captured (see `pendingRequestTapSequence`'s doc
    /// comment) and passed down unchanged. If a later tap of either kind has
    /// claimed a newer value by the time backend truth comes back, this
    /// resolution is stale: tap order is authoritative, so it must not touch
    /// `path` (or queue an unavailability notice) and silently returns
    /// instead.
    private func routeToNotification(requestID: String, tapSequence: Int) async {
        guard let resolution = try? await requestStore.resolveHelperNotificationRequest(id: requestID) else {
            return
        }
        guard TapAuthorityFence.isStillAuthoritative(
            capturedSequence: tapSequence,
            currentSequence: notificationRouter.latestTapSequence
        ) else {
            return
        }
        switch resolution {
        case .available:
            break
        case .unavailable:
            requestStore.reportRequestUnavailableFromNotification(requestID: requestID)
        case .temporarilyUnavailable:
            requestStore.reportRequestTemporarilyUnavailableFromNotification(requestID: requestID)
        }
        path = AppRoute.afterNotificationResolution(resolution)
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
            RequestFoodView(store: requestStore)
        case .activeRequests:
            ActiveRequestsView(store: requestStore)
        case .alerts:
            AlertSignupView(store: alertSubscriptionStore, pushStore: pushSubscriptionStore)
        case .privacySafety:
            PrivacySafetyView()
        case .requestDetail(let request):
            RequestDetailView(request: request, store: requestStore, path: $path)
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
