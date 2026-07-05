import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("CommonPlate")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Request food, view active requests, or sign up to help.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                NavigationLink("Request Food") {
                    RequestFoodView()
                }
                .buttonStyle(.borderedProminent)

                NavigationLink("View Active Requests") {
                    ActiveRequestsView()
                }
                .buttonStyle(.bordered)

                NavigationLink("Sign Up for Alerts") {
                    AlertSignupView()
                }
                .buttonStyle(.bordered)

                NavigationLink("Privacy & Safety") {
                    PrivacySafetyView()
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
    }
}

struct RequestFoodView: View {
    @State private var showSuccessMessage = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Request Food")
                .font(.title)
                .fontWeight(.semibold)

            Text("Form fields will go here on Day 3.")

            Button("Submit Placeholder Fulfillment") {
                showSuccessMessage = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            if showSuccessMessage {
                Text("Request submitted")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
        .padding()
        .navigationTitle("Request Food")
        }
    }

struct ActiveRequestsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Active Requests")
                .font(.title)
                .fontWeight(.semibold)

            Text("Local requests will show here on Day 5.")

            NavigationLink("Open Sample Request") {
                RequestDetailView()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .navigationTitle("Active Requests")
    }
}

struct RequestDetailView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Request Detail")
                .font(.title)
                .fontWeight(.semibold)

            Text("Details for one food request will appear here.")

            NavigationLink("Fulfill Request") {
                FulfillRequestView()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .navigationTitle("Request Detail")
    }
}

struct FulfillRequestView: View {
    @State private var showSuccessMessage = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Fulfill Request")
                .font(.title)
                .fontWeight(.semibold)

            Text("Helper/order info form will go here on Day 6.")

            Button("Submit Placeholder Fulfillment") {
                showSuccessMessage = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            
            if showSuccessMessage {
                Text("Fulfillment submitted")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
        .padding()
        .navigationTitle("Fulfill")
    }
}

struct AlertSignupView: View {
    @State private var showSuccessMessage = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Sign Up for Alerts")
                .font(.title)
                .fontWeight(.semibold)

            Text("Helpers will enter their email or phone here.")

            Button("Submit Placeholder Signup"){
                showSuccessMessage = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            
            if showSuccessMessage {
                Text("Alert signup submitted")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
        .padding()
        .navigationTitle("Alerts")
    }
}

struct PrivacySafetyView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Privacy & Safety")
                .font(.title)
                .fontWeight(.semibold)

            Text("CommonPlate is for coordinating food help. Do not share sensitive personal information. Requests should be respectful and accurate.")

            Text("More detailed safety and community guidelines will go here later.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle("Privacy")
    }
}

#Preview {
    ContentView()
}
