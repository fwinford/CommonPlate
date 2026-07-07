import SwiftUI

struct DiningSpot: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let address: String
}

enum RequestTiming: String, CaseIterable, Identifiable {
    case asap = "ASAP"
    case later = "Later"

    var id: String { rawValue }
}

enum FoodRequestStatus: String {
    case open = "Open"
    case fulfilled = "Fulfilled"
}

struct FoodRequest: Identifiable {
    let id = UUID()
    let diningSpot: DiningSpot
    let foodDescription: String
    let pickupName: String
    let email: String
    let phoneNumber: String
    let timing: RequestTiming
    let preferredPickupTime: Date?
    let createdAt = Date()
    var status: FoodRequestStatus = .open
}


struct ContentView: View {
    @State private var requests: [FoodRequest] = []
    
    
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
                    RequestFoodView { newRequest in
                        requests.append(newRequest)
                    }
                }
                .frame(maxWidth: 280)
                .buttonStyle(.borderedProminent)

                NavigationLink("Help with a request") {
                    ActiveRequestsView(requests: requests)
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
                    Text("2. Another student with extra swipes chooses a request to fulfill.")
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
    let onSubmit: (FoodRequest) -> Void

    @State private var selectedDiningSpot: DiningSpot?
    @State private var foodRequest = ""
    @State private var pickupName = ""
    @State private var email = ""
    @State private var phoneNumber = ""
    @State private var timing: RequestTiming = .asap
    @State private var preferredPickupTime = Date()
    @State private var showSuccessMessage = false
    @Environment(\.dismiss) private var dismiss
    
    private var endOfToday: Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 60 * 60)
    }
    
    private var isEmailValid: Bool {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedEmail.contains("@") && trimmedEmail.contains(".")
    }
    
    private var canSubmit: Bool {
        selectedDiningSpot != nil &&
        !foodRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !pickupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        isEmailValid
    }
    
    let diningSpots = [
        DiningSpot(name: "Crave NYU", address: "John A. Paulson Center, 6th Floor"),
        DiningSpot(name: "Dunkin' at U-Hall", address: "U-Hall, 108 E 14th St"),
        DiningSpot(name: "Jasper Kane Cafe", address: "BROOKLYN, Rogers Hall"),
        DiningSpot(name: "Peet's Coffee at Kimmel", address: "Kimmel Center, 60 Washington Sq S, 2nd Floor"),
        DiningSpot(name: "Cafe 370", address: "BROOKLYN - 370 Jay St"),
        DiningSpot(name: "Flavor Lab by NYU Eats", address: "Jasper Kane Cafe"),
        DiningSpot(name: "Cafe 181", address: "John A. Paulson Center, 6th Floor"),
        DiningSpot(name: "Upstein - Vedge Craft & Smoothie Lab", address: "Weinstein Hall, 5 University Pl #11"),
        DiningSpot(name: "Upstein - Shareables, Cluckstein, Slidestein & Taqueria", address: "Weinstein Hall, 5 University Pl #11"),
        DiningSpot(name: "True Burger at UHall", address: "U-Hall, 110 E. 14th"),
        DiningSpot(name: "Palladium", address: "Palladium Hall, 140 E 14th St")
    ]

    
    var body: some View {
        Form {
            Section("Food request") {
                Picker("NYU dining spot", selection: $selectedDiningSpot) {
                    Text("Select a spot").tag(nil as DiningSpot?)

                    ForEach(diningSpots) { spot in
                        Text(spot.name).tag(Optional(spot))
                    }
                }

                if let selectedDiningSpot {
                    Text(selectedDiningSpot.address)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                TextField("What do you want?", text: $foodRequest, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
            }

            Section("Pickup") {
                TextField("Name to use for the order", text: $pickupName)

                Picker("When do you need it?", selection: $timing) {
                    ForEach(RequestTiming.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                if timing == .later {
                    DatePicker(
                        "Around what time?",
                        selection: $preferredPickupTime,
                        in: Date()...endOfToday,
                        displayedComponents: [.hourAndMinute]
                    )                }

                Text("The student placing the order will use this name and approximate time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Contact") {
                
                TextField("Email, required", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                
                if !email.isEmpty && !isEmailValid {
                    Text("Enter a valid email address.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                TextField("Phone number, optional", text: $phoneNumber)
                    .keyboardType(.phonePad)
                
            }

            Section {
                Button("Submit Placeholder Request") {
                    guard let selectedDiningSpot else { return }

                    let newRequest = FoodRequest(
                        diningSpot: selectedDiningSpot,
                        foodDescription: foodRequest.trimmingCharacters(in: .whitespacesAndNewlines),
                        pickupName: pickupName.trimmingCharacters(in: .whitespacesAndNewlines),
                        email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                        phoneNumber: phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines),
                        timing: timing,
                        preferredPickupTime: timing == .later ? preferredPickupTime : nil
                    )

                    onSubmit(newRequest)
                    showSuccessMessage = true

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        dismiss()
                    }
                }
                .disabled(!canSubmit)

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
    let requests: [FoodRequest]
    var body: some View {
        VStack(spacing: 16) {
            Text("Active Requests")
                .font(.title)
                .fontWeight(.semibold)

            if requests.isEmpty {
                Text("Local requests will show here on Day 5.")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(requests.count) local request saved.")
                    .foregroundStyle(.secondary)

                Text("The full request list comes on Day 5.")
                    .foregroundStyle(.secondary)
            }

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
