//
//  AlertSignupView 2.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

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
