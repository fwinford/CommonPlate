//
//  CommonPlateStyle.swift
//  CommonPlateios
//
// Shared Subtle Warmth design tokens (W4-F1): the disciplined brand tint, a
// warm-neutral accent surface, and a small spacing/radius scale, so touched
// screens draw from one shared vocabulary instead of inventing one-off
// values. This is presentation only — it carries no product or lifecycle
// behavior and must not be read as one.
import SwiftUI
import UIKit
import CoreText

enum CommonPlateStyle {
    /// Colors beyond what `Color.accentColor` (the `AccentColor` asset) and
    /// the standard system semantic colors already provide. Primary actions,
    /// links, and brand accents should prefer `.tint(.accentColor)` /
    /// `.buttonStyle(.borderedProminent)`, which already read the same brand
    /// asset — these are the few cases that need the value directly.
    enum Color {
        /// The shared native base canvas for full-page F1 screens. Keeping
        /// this semantic rather than tinting it lets Home and verification
        /// retain one quiet, warm-neutral system foundation; brand character
        /// comes from hierarchy and the restrained accent, not a page wash.
        static let baseCanvas = SwiftUI.Color(uiColor: .systemBackground)

        /// A restrained warm-neutral surface for a bounded, grouped block of
        /// related content. Not a global background wash or a per-fact card
        /// fill. Native identity/settings sections intentionally do not use
        /// this treatment.
        static let warmSurface = SwiftUI.Color("CommonPlateWarmSurface")
    }

    /// A small spacing scale. Prefer these over ad hoc padding numbers on
    /// touched surfaces so spacing reads as one system rather than a
    /// per-screen guess.
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 20
        static let xl: CGFloat = 32
    }

    /// Modest corner radii, deliberately short of pill-shaped. Subtle Warmth
    /// prefers native control shapes; this exists for the few grouped
    /// surfaces (see `Color.warmSurface`) that need one.
    enum Radius {
        static let standard: CGFloat = 12
    }

    /// Shared action geometry deliberately reads as a rounded rectangle, not
    /// a capsule. The fixed minimum preserves a comfortable native tap target
    /// while the label's system type stays proportionate to display moments.
    enum Control {
        static let minimumHeight: CGFloat = 48
        static let majorActionMinimumHeight: CGFloat = 52
        /// On ordinary phones this is intentionally about four-fifths of the
        /// usable content width, so R1's major actions feel substantial but
        /// not like full-width form controls. Smaller/Dynamic Type layouts
        /// naturally use their available width instead of clipping.
        static let majorActionMaximumWidth: CGFloat = 292
    }
}

extension Font {
    /// Restrained Quiet Fraunces brand/display typography (W4-F1). The
    /// embedded Fraunces variable font and its SIL OFL notice live in
    /// `Resources/Fonts` and `Resources/Licenses`, respectively. This helper
    /// is reserved for rare, clearly display-oriented brand moments (e.g. the
    /// `CommonPlate` wordmark), never functional UI. Buttons, form controls,
    /// settings rows, instructions, metadata, body copy, and status/error
    /// text stay in system SF typography.
    ///
    /// `UIFontMetrics` scales the selected variable-font instance for the
    /// requested text style rather than freezing the wordmark at a fixed
    /// point size. If registration ever fails, the matching system Dynamic
    /// Type font is the safe fallback.
    static func commonPlateBrandDisplay(_ style: Font.TextStyle) -> Font {
        Font(CommonPlateStyle.BrandDisplay.uiFont(for: style))
    }
}

extension CommonPlateStyle {
    /// Quiet Fraunces is CommonPlate's restrained application of Fraunces,
    /// not a separate proprietary typeface. Keeping its registered name and
    /// display scale here makes the only supported use explicit and testable.
    enum BrandDisplay {
        static let fontName = "Fraunces-Regular"

        /// Quiet Fraunces is a tuned Fraunces instance: softness gives the
        /// wordmark its gentle character, while WONK is explicitly off and a
        /// medium display weight keeps it calm rather than playful or heavy.
        /// These are implementation settings, not pixel-level product values.
        static let quietVariationAxes: [String: CGFloat] = [
            "SOFT": 55,
            "WONK": 0,
            "wght": 520
        ]

        static func pointSize(for style: Font.TextStyle) -> CGFloat {
            switch style {
            case .largeTitle: return 34
            case .title: return 28
            case .title2: return 22
            case .title3: return 20
            default: return 17
            }
        }

        static func uiFont(for style: Font.TextStyle) -> UIFont {
            let textStyle = uiTextStyle(for: style)
            let pointSize = pointSize(for: style)
            guard let baseFont = UIFont(name: fontName, size: pointSize) else {
                return UIFont.preferredFont(forTextStyle: textStyle)
            }

            let descriptor = baseFont.fontDescriptor.addingAttributes([
                UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variationDictionary
            ])
            let quietFraunces = UIFont(descriptor: descriptor, size: pointSize)
            return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: quietFraunces)
        }

        private static var variationDictionary: [NSNumber: NSNumber] {
            Dictionary(uniqueKeysWithValues: quietVariationAxes.map { tag, value in
                (NSNumber(value: fourCharacterCode(tag)), NSNumber(value: Double(value)))
            })
        }

        private static func fourCharacterCode(_ tag: String) -> UInt32 {
            tag.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
        }

        private static func uiTextStyle(for style: Font.TextStyle) -> UIFont.TextStyle {
            switch style {
            case .largeTitle: return .largeTitle
            case .title: return .title1
            case .title2: return .title2
            case .title3: return .title3
            case .headline: return .headline
            case .subheadline: return .subheadline
            case .body: return .body
            case .callout: return .callout
            case .footnote: return .footnote
            case .caption: return .caption1
            case .caption2: return .caption2
            @unknown default: return .body
            }
        }
    }
}
