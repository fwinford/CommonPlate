import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("CommonPlate")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Need food, or have extra meal swipes to share?")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                NavigationLink("I need food") {
                    RequestFoodView()
                }
                .frame(maxWidth: 280)
                .buttonStyle(.borderedProminent)

                NavigationLink("I have extra swipes") {
                    ActiveRequestsView()
                }
                .frame(maxWidth: 280)
                .buttonStyle(.bordered)
                
                Text("Want to help later?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                
                NavigationLink("Notify me") {
                    AlertSignupView()
                }
                .frame(maxWidth: 280)
                .buttonStyle(.bordered)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("How it works")
                        .font(.headline)

                    Text("1. A student requests food from an NYU dining spot.")
                    Text("2. Another student with extra swipes fulfills it.")
                    Text("3. They place the order and share pickup details.")
                    Text("4. The requester gets notified.")
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

struct RequestFoodView: View {
    @State private var foodLocation = ""
    @State private var foodRequest = ""
    @State private var pickupName = ""
    @State private var email = ""
    @State private var phoneNumber = ""
    @State private var timing = "Now"
    @State private var pickupWindow = ""
    @State private var showSuccessMessage = false

    var body: some View {
        Form {
            Section("Food request") {
                TextField("NYU dining spot", text: $foodLocation)

                TextField("What do you want?", text: $foodRequest, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
            }

            Section("Pickup") {
                TextField("Pickup name for the order", text: $pickupName)

                Picker("Timing", selection: $timing) {
                    Text("Now").tag("Now")
                    Text("Later").tag("Later")
                }
                .pickerStyle(.segmented)

                TextField("Pickup window, e.g. 7:00–7:30 PM", text: $pickupWindow)
            }

            Section("Contact") {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("Phone number, optional", text: $phoneNumber)
                    .keyboardType(.phonePad)
            }

            Section {
                Button("Submit Placeholder Request") {
                    showSuccessMessage = true
                }

                if showSuccessMessage {
                    Text("Request submitted. Local app data comes on Day 4.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
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
