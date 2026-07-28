//
//  RequestFoodView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

enum RequestFoodFormError: Error, Equatable {
    case missingDiningSpot
    case missingFood
    case missingPickupName
    case invalidEmail
    case invalidScheduledTime

    var message: String {
        switch self {
        case .missingDiningSpot:
            return "Choose an NYU dining spot."
        case .missingFood:
            return "Tell us what food you need."
        case .missingPickupName:
            return "Enter the name to use for the order."
        case .invalidEmail:
            return "Enter a valid email address."
        case .invalidScheduledTime:
            return "Choose a pickup time that leaves a full 30-minute window today."
        }
    }
}

enum RequestCreatePresentationError: Equatable {
    case invalidRequest
    case requestLimitReached
    case publicActionsPaused
    case creationFailed
    case ambiguous
    case operationInProgress

    var message: String {
        switch self {
        case .invalidRequest:
            return "Check the information you entered and try again."
        case .requestLimitReached:
            return "The daily request limit has been reached. Please try again tomorrow."
        case .publicActionsPaused:
            // Locked copy, shared verbatim with the web request form
            // (`REQUEST_POSTING_PAUSED_MESSAGE`) and asserted on both sides.
            return "Posting a meal request is temporarily unavailable."
        case .creationFailed:
            return "We couldn’t post your request. Please try again in a moment."
        case .ambiguous:
            return "We couldn’t confirm whether your request was posted. Check Active Requests before submitting again."
        case .operationInProgress:
            return "Your request is already being posted."
        }
    }

    static func map(_ error: Error) -> RequestCreatePresentationError {
        guard let serviceError = error as? RequestServiceError else {
            return .creationFailed
        }

        switch serviceError {
        case .serverError(let code, _):
            switch code {
            case "INVALID_REQUEST":
                return .invalidRequest
            case "REQUEST_LIMIT_REACHED":
                return .requestLimitReached
            case "PUBLIC_ACTIONS_PAUSED":
                return .publicActionsPaused
            case "REQUEST_CREATION_FAILED":
                return .creationFailed
            default:
                return .creationFailed
            }
        case .ambiguousCreateOutcome:
            return .ambiguous
        case .operationInProgress:
            return .operationInProgress
        default:
            return .creationFailed
        }
    }
}

/// Requester-facing request form. Temporary input and presentation state stay
/// here; confirmed canonical collection state is owned by `RequestStore`.
struct RequestFoodView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: RequestStore

    @State private var selectedDiningSpot: DiningSpot?
    @State private var foodRequest = ""
    @State private var pickupName = ""
    @State private var email = ""
    @State private var timing: RequestTiming = .asap
    @State private var preferredPickupTime = Date()
    @State private var formError: RequestFoodFormError?
    @State private var submissionError: RequestCreatePresentationError?
    @State private var didCreateRequest = false

    private var calendar: Calendar {
        Calendar.current
    }

    private var endOfToday: Date {
        Self.endOfDay(containing: Date(), calendar: calendar) ?? Date()
    }

    private var latestScheduledStart: Date {
        Self.latestScheduledStart(on: Date(), calendar: calendar) ?? endOfToday
    }

    private var scheduledStartRange: ClosedRange<Date> {
        let now = Date()
        return min(now, latestScheduledStart)...latestScheduledStart
    }

    private var isEmailValid: Bool {
        Self.isValidEmail(email)
    }

    private var isScheduledWindowValid: Bool {
        guard timing == .later else {
            return true
        }
        return Self.isValidScheduledWindow(
            startingAt: preferredPickupTime,
            now: Date(),
            calendar: calendar
        )
    }

    private var canAttemptSubmission: Bool {
        submissionError != .ambiguous
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
        Group {
            if didCreateRequest {
                successView
            } else {
                requestForm
            }
        }
        .navigationTitle("Request Food")
    }

    private var successView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            Text("Request posted")
                .font(.title)
                .fontWeight(.bold)

            Text("Your request is now visible to helpers. It will expire automatically if it is not fulfilled.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Back to Home") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var requestForm: some View {
        Form {
            if let formError {
                Section {
                    Text(formError.message)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("request-form-error")
                }
            } else if let submissionError {
                Section {
                    Text(submissionError.message)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("request-submission-error")
                }
            }

            Section("Food request") {
                Picker("NYU dining spot", selection: $selectedDiningSpot) {
                    Text("Select a spot").tag(nil as DiningSpot?)

                    ForEach(diningSpots) { spot in
                        Text(spot.name).tag(Optional(spot))
                    }
                }

                if let address = selectedDiningSpot?.address {
                    Text(address)
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
                .onChange(of: timing) { _, newTiming in
                    guard newTiming == .later else {
                        return
                    }
                    preferredPickupTime = min(
                        max(preferredPickupTime, Date()),
                        latestScheduledStart
                    )
                }

                if timing == .later {
                    DatePicker(
                        "Around what time?",
                        selection: $preferredPickupTime,
                        in: scheduledStartRange,
                        displayedComponents: [.hourAndMinute]
                    )

                    if !isScheduledWindowValid {
                        Text(RequestFoodFormError.invalidScheduledTime.message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Text("The student placing the order will use this name and approximate time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("Requests expire after a few hours so the list stays current.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Contact") {
                TextField("Email, required", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if !email.isEmpty && !isEmailValid {
                    Text(RequestFoodFormError.invalidEmail.message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task {
                        await submit()
                    }
                } label: {
                    if store.isCreating {
                        HStack {
                            ProgressView()
                            Text("Posting…")
                        }
                    } else {
                        Text("Submit Request")
                    }
                }
                .disabled(!canAttemptSubmission || store.isCreating)
            }
        }
    }

    @MainActor
    private func submit() async {
        formError = nil
        submissionError = nil

        let payload: CreateRequestPayload
        do {
            payload = try Self.makePayload(
                selectedDiningSpot: selectedDiningSpot,
                foodRequest: foodRequest,
                pickupName: pickupName,
                email: email,
                timing: timing,
                preferredPickupTime: preferredPickupTime,
                now: Date(),
                calendar: calendar
            )
        } catch let validationError as RequestFoodFormError {
            formError = validationError
            return
        } catch {
            submissionError = .creationFailed
            return
        }

        do {
            try await store.createRequest(payload)
            didCreateRequest = true
        } catch {
            submissionError = RequestCreatePresentationError.map(error)
        }
    }

    static func makePayload(
        selectedDiningSpot: DiningSpot?,
        foodRequest: String,
        pickupName: String,
        email: String,
        timing: RequestTiming,
        preferredPickupTime: Date,
        now: Date,
        calendar: Calendar
    ) throws -> CreateRequestPayload {
        guard let selectedDiningSpot else {
            throw RequestFoodFormError.missingDiningSpot
        }

        let trimmedVendor = selectedDiningSpot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVendor.isEmpty else {
            throw RequestFoodFormError.missingDiningSpot
        }

        let trimmedFood = foodRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFood.isEmpty else {
            throw RequestFoodFormError.missingFood
        }

        let trimmedPickupName = pickupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPickupName.isEmpty else {
            throw RequestFoodFormError.missingPickupName
        }

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidEmail(trimmedEmail) else {
            throw RequestFoodFormError.invalidEmail
        }

        switch timing {
        case .asap:
            return CreateRequestPayload(
                vendor: trimmedVendor,
                food: trimmedFood,
                pickupName: trimmedPickupName,
                email: trimmedEmail,
                timing: .asap,
                windowStart: nil,
                windowEnd: nil
            )
        case .later:
            guard isValidScheduledWindow(
                startingAt: preferredPickupTime,
                now: now,
                calendar: calendar
            ),
            let windowEnd = calendar.date(
                byAdding: .minute,
                value: 30,
                to: preferredPickupTime
            ) else {
                throw RequestFoodFormError.invalidScheduledTime
            }

            return CreateRequestPayload(
                vendor: trimmedVendor,
                food: trimmedFood,
                pickupName: trimmedPickupName,
                email: trimmedEmail,
                timing: .scheduled,
                windowStart: preferredPickupTime,
                windowEnd: windowEnd
            )
        }
    }

    static func endOfDay(containing date: Date, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
    }

    static func latestScheduledStart(on date: Date, calendar: Calendar) -> Date? {
        guard let endOfDay = endOfDay(containing: date, calendar: calendar) else {
            return nil
        }
        return calendar.date(byAdding: .minute, value: -30, to: endOfDay)
    }

    static func isValidScheduledWindow(
        startingAt start: Date,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        guard start >= now,
              let end = calendar.date(byAdding: .minute, value: 30, to: start),
              end > start,
              let dayEnd = endOfDay(containing: now, calendar: calendar) else {
            return false
        }
        return end <= dayEnd
    }

    static func isValidEmail(_ value: String) -> Bool {
        let trimmedEmail = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let atIndex = trimmedEmail.firstIndex(of: "@"),
              atIndex != trimmedEmail.startIndex,
              atIndex != trimmedEmail.index(before: trimmedEmail.endIndex) else {
            return false
        }
        return trimmedEmail[trimmedEmail.index(after: atIndex)...].contains(".")
    }
}
