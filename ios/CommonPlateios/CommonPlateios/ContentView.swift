import SwiftUI

struct ContentView: View {
    /// What the connected claim-to-placement flow does. Placement records an
    /// external order the helper has already completed; notification is a
    /// separate email attempt and is never described as delivery or reading.
    static let howItWorksSteps = [
        "1. A student posts a food request from an NYU dining spot.",
        "2. Another student with extra meal swipes chooses a request to help with.",
        "3. The helper places the external order, then records the order number and ETA.",
        "4. CommonPlate attempts to email the requester the pickup details."
    ]

    @StateObject private var requestStore: RequestStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let client = APIClient(configuration: .localSimulator)
        let service = RequestService(client: client)
        _requestStore = StateObject(wrappedValue: RequestStore(service: service))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("CommonPlate")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Need food, or have extra meal swipes you can use to help?")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                NavigationLink("I need food") {
                    RequestFoodView(store: requestStore)
                }
                .frame(maxWidth: 280)
                .buttonStyle(.borderedProminent)

                NavigationLink("Help with a request") {
                    ActiveRequestsView(store: requestStore)
                }
                .frame(maxWidth: 280)
                .buttonStyle(.bordered)

                Text("Want to help later?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                NavigationLink("About alerts") {
                    AlertSignupView()
                }
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

                NavigationLink("Privacy & Safety") {
                    PrivacySafetyView()
                }
                .frame(maxWidth: 280)
                .buttonStyle(.plain)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            .padding(.top, 12)
            .padding()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                requestStore.revalidateActiveClaimExpiration()
            }
        }
    }
}

#Preview {
    ContentView()
}
