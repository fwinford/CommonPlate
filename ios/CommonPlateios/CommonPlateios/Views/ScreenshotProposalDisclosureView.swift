//
//  ScreenshotProposalDisclosureView.swift
//  CommonPlateios
//
// W4-S1 first-use third-party (OpenAI) transfer disclosure. Presented once,
// before the first screenshot this installation has ever sent off-device;
// `ScreenshotProposalStore.recordThirdPartyConsent()` remembers acceptance
// so normal repeat use is never re-disclosed. Declining leaves the picked
// screenshot un-sent and the form fully manual-usable.
import SwiftUI

struct ScreenshotProposalDisclosureView: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    static let title = "Analyze this screenshot with AI?"
    static let body =
        "CommonPlate will send this screenshot to OpenAI to read it and suggest a location, food description, and meal swipes for this request. Nothing is submitted automatically — you review and edit everything before posting. CommonPlate does not store the screenshot or what OpenAI returns."

    var body: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.l) {
            Text(Self.title)
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("screenshot-proposal-disclosure-title")

            Text(Self.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("screenshot-proposal-disclosure-body")

            VStack(spacing: CommonPlateStyle.Spacing.s) {
                Button("Continue") {
                    onContinue()
                }
                .commonPlatePrimaryAction()
                .accessibilityIdentifier("screenshot-proposal-disclosure-continue")

                Button("Cancel") {
                    onCancel()
                }
                .commonPlateTertiaryAction()
                .accessibilityIdentifier("screenshot-proposal-disclosure-cancel")
            }
        }
        .padding(CommonPlateStyle.Spacing.xl)
    }
}
