//
//  RequestDetailView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

struct RequestDetailView: View {
    let request: FoodRequest

    var body: some View {
        Form {
            Section("Food request") {
                Text(request.diningSpot.name)
                    .font(.headline)
                if let address = request.diningSpot.address {
                    Text(address)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(request.foodDescription)
                Text(request.timingDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Helping with this meal is temporarily unavailable.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Request")
    }
}
