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
    @Environment(\.scenePhase) private var scenePhase

    /// The one navigation stack in the app, owned here so any screen inside it
    /// can leave a finished flow by rewriting the path rather than by asking a
    /// view below it to dismiss.
    @State private var path: [AppRoute] = []

    init() {
        let client = APIClient(configuration: .localSimulator)
        let service = RequestService(client: client)
        _requestStore = StateObject(wrappedValue: RequestStore(service: service))
        _alertSubscriptionStore = StateObject(
            wrappedValue: AlertSubscriptionStore(
                service: AlertSubscriptionService(client: client),
                // The app's real preferences. Tests inject an isolated suite or
                // an in-memory double instead, which is why this argument has
                // no default.
                presentationStorage: UserDefaultsAlertSignupPresentationStorage(defaults: .standard)
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
            }
        }
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
            AlertSignupView(store: alertSubscriptionStore)
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
    ContentView()
}
