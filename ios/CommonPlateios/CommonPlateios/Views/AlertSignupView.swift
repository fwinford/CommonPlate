//
//  AlertSignupView 2.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

struct AlertSignupView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Get Notified")
                .font(.title)
                .fontWeight(.semibold)

            Text("Soon, helpers will be able to sign up for alerts when new food requests are posted.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Text("For now, check Active Requests to see what still needs help.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Got it") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .padding()
        .navigationTitle("Alerts")
    }
}
