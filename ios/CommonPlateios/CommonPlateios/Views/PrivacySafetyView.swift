//
//  PrivacySafetyView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

struct PrivacySafetyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Privacy & Safety")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("CommonPlate is for voluntary student-to-student food help. It is not a place to sell meal swipes, exchange money, or share account access.")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Use CommonPlate safely")
                        .font(.headline)

                    Text("• Do not share your NYU login, ID card, or account access.")
                    Text("• Do not exchange money for meal swipes or orders.")
                    Text("• Only place orders you are comfortable placing.")
                    Text("• Keep requests respectful, accurate, and food-related.")
                    Text("• Do not include sensitive personal information in requests or notes.")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Privacy")
                        .font(.headline)

                    Text("Pickup names and order details are only used to coordinate food pickup. Contact information should only be used for coordinating the request.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Need more support?")
                        .font(.headline)

                    Text("CommonPlate is not a replacement for official food support. NYU offers food accessibility resources for students who need short-term or ongoing help.")
                        .foregroundStyle(.secondary)

                    Link(
                        "NYU Food Accessibility Assistance",
                        destination: URL(string: "https://www.nyu.edu/students/student-information-and-resources/courtesy-meals.html")!
                    )

                    Link(
                        "NYU Nutritional Support Initiatives",
                        destination: URL(string: "https://www.nyu.edu/students/student-information-and-resources/housing-and-dining/dining/nutritional-support-initiatives.html")!
                    )
                }
            }
            .padding()
        }
        .navigationTitle("Privacy")
    }
}
