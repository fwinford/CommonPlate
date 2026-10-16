//
//  PrivacySafetyView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import SwiftUI

struct PrivacySafetyView: View {
    @ObservedObject var participantIdentityStore: ParticipantIdentityStore

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

                    Text("Order details are only used to coordinate food pickup. Contact information should only be used for coordinating the request.")
                        .foregroundStyle(.secondary)
                }

                // W4-U1.3: the one route to Block management
                // (Settings → Privacy & Safety → Blocked Students). Offered
                // only with a verified participant, since a block belongs to
                // one. The list shows interaction context, never identity.
                if participantIdentityStore.identity != nil {
                    NavigationLink(value: AppRoute.blockedStudents) {
                        HStack(alignment: .center) {
                            Text(ParticipantBlockCopy.managementRowTitle)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            Spacer(minLength: CommonPlateStyle.Spacing.s)
                            CommonPlateDisclosureIndicator()
                        }
                        .frame(minHeight: CommonPlateStyle.Control.minimumHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("privacy-safety-blocked-students")
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
