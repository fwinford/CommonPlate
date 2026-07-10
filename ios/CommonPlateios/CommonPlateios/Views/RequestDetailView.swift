//
//  RequestDetailView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

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
