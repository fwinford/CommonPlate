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
    case placed = "Placed"
}

struct FulfillmentDetails {
    let helperEmail: String
    let helperPhoneNumber: String
    let orderConfirmation: String
    let pickupTimeOrETA: String
    let noteToRequester: String
    let submittedAt = Date()
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
    var fulfillmentDetails: FulfillmentDetails?

    var expiresAt: Date {
        switch timing {
        case .asap:
            return createdAt.addingTimeInterval(5 * 60 * 60)

        case .later:
            if let preferredPickupTime {
                return preferredPickupTime.addingTimeInterval(5 * 60 * 60)
            } else {
                return createdAt.addingTimeInterval(5 * 60 * 60)
            }
        }
    }

    var isExpired: Bool {
        Date() >= expiresAt
    }

    var isActive: Bool {
        status == .open && !isExpired
    }

    var shouldShowInASAPSection: Bool {
        switch timing {
        case .asap:
            return true

        case .later:
            guard let preferredPickupTime else {
                return false
            }

            let oneHourFromNow = Date().addingTimeInterval(60 * 60)
            return preferredPickupTime <= oneHourFromNow
        }
    }

    var timingDescription: String {
        switch timing {
        case .asap:
            return "ASAP"

        case .later:
            if let preferredPickupTime {
                return "Around \(preferredPickupTime.formatted(date: .omitted, time: .shortened))"
            } else {
                return "Later today"
            }
        }
    }
    
    var listTimingDescription: String {
        if shouldShowInASAPSection && timing == .later, let preferredPickupTime {
            return "Due around \(preferredPickupTime.formatted(date: .omitted, time: .shortened))"
        }

        return timingDescription
    }
}

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
                    Text("4. Pickup details are shared with the student.")
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
    @State private var hasTriedToSubmit = false
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
    
    private var hasStartedRequestForm: Bool {
        selectedDiningSpot != nil ||
        !foodRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !pickupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                    )
                }

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
                
                if hasTriedToSubmit && !canSubmit && !showSuccessMessage {
                    Text("Complete the dining spot, food request, pickup name, and email to submit.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                
                Button("Submit Request") {
                    hasTriedToSubmit = true

                    guard canSubmit, let selectedDiningSpot else {
                        return
                    }

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
                .disabled(showSuccessMessage)
                
                if showSuccessMessage {
                    Text("Request posted!")
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
    let onFulfill: (FoodRequest) -> Void

    private var asapRequests: [FoodRequest] {
        activeRequests
            .filter { $0.shouldShowInASAPSection }
            .sorted { $0.expiresAt < $1.expiresAt }
    }

    private var laterTodayRequests: [FoodRequest] {
        activeRequests
            .filter { !$0.shouldShowInASAPSection }
            .sorted {
                ($0.preferredPickupTime ?? $0.createdAt) < ($1.preferredPickupTime ?? $1.createdAt)
            }
    }
    
    private var activeRequests: [FoodRequest] {
        requests.filter { $0.isActive }
    }


    var body: some View {
        Group {
            if activeRequests.isEmpty {
                VStack(spacing: 12) {
                    Text("No active requests right now.")
                        .font(.headline)

                    Text("When someone requests food, it will appear here.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                List {
                    if !asapRequests.isEmpty {
                        Section("ASAP") {
                            ForEach(asapRequests) { request in
                                NavigationLink {
                                    RequestDetailView(request: request, onFulfill: onFulfill)
                                } label: {
                                    RequestRowView(request: request)
                                }
                            }
                        }
                    }

                    if !laterTodayRequests.isEmpty {
                        Section("Later today") {
                            ForEach(laterTodayRequests) { request in
                                NavigationLink {
                                    RequestDetailView(request: request, onFulfill: onFulfill)
                                } label: {
                                    RequestRowView(request: request)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Active Requests")
    }
    
}

struct RequestRowView: View {
    let request: FoodRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(request.diningSpot.name)
                .font(.headline)

            Text(request.foodDescription)
                .lineLimit(2)

            Text(request.listTimingDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct RequestDetailView: View {
    let request: FoodRequest
    let onFulfill: (FoodRequest) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Food request") {
                Text(request.diningSpot.name)
                    .font(.headline)
                Text(request.diningSpot.address)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(request.foodDescription)
                Text(request.timingDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink("I'll help with this") {
                    FulfillRequestView(request: request) { updatedRequest in
                        onFulfill(updatedRequest)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("Request Detail")
    }
}
struct FulfillRequestView: View {
    let request: FoodRequest
    let onFulfill: (FoodRequest) -> Void

    @State private var helperEmail = ""
    @State private var helperPhoneNumber = ""
    @State private var orderConfirmation = ""
    @State private var pickupTimeOrETA = ""
    @State private var noteToRequester = ""
    @State private var showSuccessMessage = false
    @State private var hasTriedToSubmit = false
    @Environment(\.dismiss) private var dismiss

    private var isHelperEmailValid: Bool {
        let trimmedEmail = helperEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedEmail.contains("@") && trimmedEmail.contains(".")
    }

    private var canSubmit: Bool {
        isHelperEmailValid &&
        !orderConfirmation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !pickupTimeOrETA.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Text("Place the order on Grubhub with the pickup name below, then come back and enter the confirmation and pickup time. Heads up: someone else may be working on this too.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Section("Request") {
                Text(request.foodDescription)

                Text("\(request.diningSpot.name) · \(request.timingDescription)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Pickup name") {
                Text(request.pickupName)
                    .font(.headline)
            }

            Section("Your contact") {
                TextField("Email", text: $helperEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if !helperEmail.isEmpty && !isHelperEmailValid {
                    Text("Enter a valid email address.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                TextField("Phone number, optional", text: $helperPhoneNumber)
                    .keyboardType(.phonePad)
            }

            Section("Order details") {
                TextField("Order confirmation or order number", text: $orderConfirmation)

                TextField("Pickup time or ETA", text: $pickupTimeOrETA)

                TextField("Optional note for them", text: $noteToRequester, axis: .vertical)
                    .lineLimit(2, reservesSpace: true)
            }

            Section {
                if hasTriedToSubmit && !canSubmit && !showSuccessMessage {
                    Text("Enter your email, order confirmation, and pickup time to continue.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button("I placed the order") {
                    hasTriedToSubmit = true

                    guard canSubmit else {
                        return
                    }

                    let fulfillmentDetails = FulfillmentDetails(
                        helperEmail: helperEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                        helperPhoneNumber: helperPhoneNumber.trimmingCharacters(in: .whitespacesAndNewlines),
                        orderConfirmation: orderConfirmation.trimmingCharacters(in: .whitespacesAndNewlines),
                        pickupTimeOrETA: pickupTimeOrETA.trimmingCharacters(in: .whitespacesAndNewlines),
                        noteToRequester: noteToRequester.trimmingCharacters(in: .whitespacesAndNewlines)
                    )

                    var updatedRequest = request
                    updatedRequest.status = .placed
                    updatedRequest.fulfillmentDetails = fulfillmentDetails

                    showSuccessMessage = true

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        dismiss()

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            onFulfill(updatedRequest)
                        }
                    }
                }
                .disabled(showSuccessMessage)

                if showSuccessMessage {
                    Text("Order details shared.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Fulfill Request")
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
