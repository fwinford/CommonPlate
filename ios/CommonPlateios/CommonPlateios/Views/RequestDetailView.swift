//
//  RequestDetailView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

struct RequestDetailView: View {
    let request: LocalSimulatedRequest
    let onFulfill: (LocalSimulatedRequest) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Food request") {
                Text(request.canonicalRequest.diningSpot.name)
                    .font(.headline)
                if let address = request.canonicalRequest.diningSpot.address {
                    Text(address)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(request.canonicalRequest.foodDescription)
                Text(request.canonicalRequest.timingDescription)
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
        .navigationTitle("Request")
    }
}
