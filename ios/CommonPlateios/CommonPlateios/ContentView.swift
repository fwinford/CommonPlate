import SwiftUI

struct ContentView: View {
    @State private var requests: [FoodRequest] = []

    private func markRequestAsPlaced(_ updatedRequest: FoodRequest) {
        guard let index = requests.firstIndex(where: { $0.id == updatedRequest.id }) else {
            return
        }

        requests[index] = updatedRequest
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
                    RequestFoodView { newRequest in
                        requests.append(newRequest)
                    }
                }
                .frame(maxWidth: 280)
                .buttonStyle(.borderedProminent)

                NavigationLink("Help with a request") {
                    ActiveRequestsView(
                        requests: requests,
                        onFulfill: markRequestAsPlaced
                    )
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

                    Text("1. A student posts a food request from an NYU dining spot.")
                    Text("2. Another student with extra meal swipes chooses a request to help with.")
                    Text("3. They place the order and enter pickup details.")
                    Text("4. The student uses those details to pick up their food.")
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
