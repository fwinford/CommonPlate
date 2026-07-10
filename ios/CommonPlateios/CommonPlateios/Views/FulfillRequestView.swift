//
//  FulfillRequestView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

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
            Section("Before you submit") {
                Text("Place the order on Grubhub using the pickup name below, then come back and enter the confirmation and pickup time.")

                Text("Someone else may be working on this request too.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Order info") {
                Text(request.foodDescription)

                Text("\(request.diningSpot.name) · \(request.timingDescription)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Pickup name")
                    Spacer()
                    Text(request.pickupName)
                        .fontWeight(.semibold)
                }
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
        .navigationTitle("Help with Request")
    }
}
