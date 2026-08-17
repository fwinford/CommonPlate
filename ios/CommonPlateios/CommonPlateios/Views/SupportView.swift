//
//  SupportView.swift
//  CommonPlateios
//
// W4-H2's About & Help "Support" destination row. Minimal and truthful: no
// fabricated response-time promise, no support channel this app does not
// actually operate. Final trust/support content and copy belong to T1; this
// exists only to give the contract-required Settings row a real destination.
import SwiftUI

struct SupportView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Support")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("CommonPlate is a student-run project. If something isn’t working, or a request or reservation looks wrong, NYU’s food accessibility resources below can help in the meantime.")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("NYU resources")
                        .font(.headline)

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
        .navigationTitle("Support")
    }
}
