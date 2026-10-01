//
//  ScreenshotExternalAIFallbackView.swift
//  CommonPlateios
//
// W4-S3: the external-AI fallback popup. Shown only when an otherwise eligible
// on-device Screenshot Assistance attempt could not run, failed, or produced
// zero usable fields (see `ScreenshotProposalStore.analyzeScreenshot`). It
// replaces the pre-S3 disclosure that used to appear before the photo picker:
// choosing and locally analyzing screenshots sends nothing off-device, so
// nothing is disclosed until an external transfer is actually being offered.
//
// Tapping `Use external AI` is the requester's explicit permission to send the
// currently selected screenshots to OpenAI for that one attempt — there is no
// second confirmation, and the permission is never persisted or reusable.
// Every other dismissal (`Continue manually`, a new selection, Settings Off,
// leaving the screen) sends nothing.
//
// `RequestFoodView` presents this inside the same centered-modal shell
// Screenshot Help uses (not a `.sheet`, no navigation screen).
import SwiftUI

struct ScreenshotExternalAIFallbackView: View {
    let onUseExternalAI: () -> Void
    let onContinueManually: () -> Void
    /// Same reason `ScreenshotHelpView.overview` reads this: a plain,
    /// synchronous `@Environment` value resolved during `body`, with none of
    /// the runtime-measurement failure modes documented on that property.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The same modal-height budget the shared call-site shell caps this
    /// view to (`RequestFoodView`'s `.frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 480 : nil)`),
    /// named here so this view's own accessibility-size fallback caps itself
    /// to the same value rather than duplicating a different number.
    static let maxHeight: CGFloat = 480

    // Exact accepted copy (weekly spec, W4-S3 "Fallback presentation"). No
    // subtitle, no retention wording. User-facing copy distinguishes analysis
    // on `your device` from `OpenAI, an external AI provider`.
    static let title = "Couldn’t analyze these on your device"
    static let body =
        "CommonPlate can send these screenshots to OpenAI, an external AI provider, to suggest request details."
    static let useExternalAIActionTitle = "Use external AI"
    static let continueManuallyActionTitle = "Continue manually"

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
                .accessibilityIdentifier("screenshot-external-ai-title")

            Text(Self.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("screenshot-external-ai-body")

            VStack(spacing: CommonPlateStyle.Spacing.s) {
                Button(Self.useExternalAIActionTitle) {
                    onUseExternalAI()
                }
                .commonPlatePrimaryAction()
                .accessibilityIdentifier("screenshot-external-ai-use")

                Button(Self.continueManuallyActionTitle) {
                    onContinueManually()
                }
                .commonPlateSecondaryAction()
                .accessibilityIdentifier("screenshot-external-ai-continue-manually")
            }
        }
        .padding(CommonPlateStyle.Spacing.xl)
    }
}
