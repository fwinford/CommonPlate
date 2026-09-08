//
//  ScreenshotProposalDisclosureView.swift
//  CommonPlateios
//
// Required remote-AI transfer disclosure, presented before the first
// screenshot this installation has ever sent off-device (and again from the
// Screenshot Assistance Off-state contextual re-entry point — W4-R2
// 2026-09-01 round-2 sync item 2 — which is a second entry point into this
// same gate, not a second disclosure design).
// `ScreenshotProposalStore.recordThirdPartyConsent()` remembers acceptance
// so normal repeat use is never re-disclosed. `Not now` leaves the picked
// screenshot un-sent and the form fully manual-usable.
//
// W4-R2 2026-09-01 round-2 sync items 4-6: this is presented by
// `RequestFoodView` inside the same centered-modal shell Screenshot Help
// uses (not a `.sheet`), and its copy is the accepted compact,
// vendor-neutral wording — no named provider, no retention/storage
// explanation, no field-by-field enumeration.
import SwiftUI

struct ScreenshotProposalDisclosureView: View {
    let onContinue: () -> Void
    let onCancel: () -> Void
    /// Same reason `ScreenshotHelpView.overview` reads this: a plain,
    /// synchronous `@Environment` value resolved during `body`, with none of
    /// the runtime-measurement failure modes documented on that property.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The same modal-height budget the shared call-site shell caps this
    /// view to (`RequestFoodView`'s `.frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 480 : nil)`),
    /// named here so this view's own accessibility-size fallback caps itself
    /// to the same value rather than duplicating a different number.
    static let maxHeight: CGFloat = 480

    static let title = "Use Screenshot Assistance?"
    static let body =
        "The screenshot you choose is sent for AI analysis to suggest request details. You review everything before posting."

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView {
                    content
                }
                .frame(maxHeight: Self.maxHeight)
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.l) {
            Text(Self.title)
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("screenshot-proposal-disclosure-title")

            Text(Self.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("screenshot-proposal-disclosure-body")

            // W4-R2 2026-09-05 sync item 4: `Not now` is a full-width
            // secondary action stacked beneath `Continue`, with a footprint
            // comparable to it — not a plain tertiary text link.
            VStack(spacing: CommonPlateStyle.Spacing.s) {
                Button("Continue") {
                    onContinue()
                }
                .commonPlatePrimaryAction()
                .accessibilityIdentifier("screenshot-proposal-disclosure-continue")

                Button("Not now") {
                    onCancel()
                }
                .commonPlateSecondaryAction()
                .accessibilityIdentifier("screenshot-proposal-disclosure-cancel")
            }
        }
        .padding(CommonPlateStyle.Spacing.xl)
    }
}
