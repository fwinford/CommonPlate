//
//  RequestFoodView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

/// Requester-facing request form. Submission is paused: the Week 1 prototype
/// submitted into local-only state that no longer has a reader, which reported
/// success for a request that was never persisted anywhere. The form stays
/// visible so the flow can be reviewed, but the submit action is disabled until
/// Day 3 connects it to `POST /api/request` through `RequestStore`.
struct RequestFoodView: View {
    /// Locked product copy. Shared by the notice above the fields and the
    /// disabled control's accessibility hint so the two cannot drift apart.
    static let pauseNotice = "Posting a meal request is temporarily unavailable."

    @State private var selectedDiningSpot: DiningSpot?
    @State private var foodRequest = ""
    @State private var pickupName = ""
    @State private var email = ""
    @State private var phoneNumber = ""
    @State private var timing: RequestTiming = .asap
    @State private var preferredPickupTime = Date()

    private var endOfToday: Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 60 * 60)
    }

    private var isEmailValid: Bool {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedEmail.contains("@") && trimmedEmail.contains(".")
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
            // First section on purpose: the student learns that posting is
            // paused before spending effort on the fields, not after reaching
            // a dimmed Submit at the bottom.
            Section {
                Text(Self.pauseNotice)
                    .font(.subheadline)
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
                    Text("Enter a valid email address.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                TextField("Phone number, optional", text: $phoneNumber)
                    .keyboardType(.phonePad)
            }

            Section {
                // Intentionally inert until Day 3 wires this to the backend
                // create flow. Nothing is persisted locally or remotely, so the
                // action must not report success or dismiss the form.
                Button("Submit Request") {}
                    .disabled(true)
                    .accessibilityHint(Self.pauseNotice)

                // Kept alongside the disabled control as well as at the top:
                // on a small device the two are more than a screen apart, so
                // the dimmed button still needs its reason in place.
                Text(Self.pauseNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Request Food")
    }
}
