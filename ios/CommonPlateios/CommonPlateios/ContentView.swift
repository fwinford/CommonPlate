import SwiftUI

struct ContentView: View {
    /// What the app can actually do today. Step 3 previously told helpers they
    /// place the order and enter pickup details — the one instruction the
    /// claimant screen exists to contradict ("Please don't place the order").
    /// A student who reads onboarding and trusts it over mid-flow copy would
    /// place a real order CommonPlate cannot record or notify anyone about, so
    /// this describes ordering as pending until Day 5 fulfillment ships.
    static let howItWorksSteps = [
        "1. A student posts a food request from an NYU dining spot.",
        "2. Another student with extra meal swipes chooses a request to help with.",
        "3. Ordering is coming soon. For now, you can reserve a request while we finish this step.",
        "4. When ordering is ready, the helper will share pickup details and the student uses them to collect their food."
    ]

    @StateObject private var requestStore: RequestStore

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
    }
}

#Preview {
    ContentView()
}
