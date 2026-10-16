//
//  OnboardingExperienceView.swift
//  CommonPlateios
//
// W4-O1 first-use Welcome: one shared, role-free story that ends at the
// canonical Home. Presentation only; it creates no role or identity state.

import SwiftUI

/// Surface of O1's Welcome story cards and How CommonPlate Works hub cards,
/// in one place. Light is unchanged (white fill, the accepted warm border).
/// There is no dark design reference yet, so dark uses a soft raised grey and
/// a quiet translucent line instead of the light border's bright tan; replace
/// these two values when a dark design exists.
enum OnboardingCardSurface {
    static let fill = Color(uiColor: .tertiarySystemBackground)
    static let border = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.12)
            : UIColor(red: 231.0 / 255, green: 221.0 / 255, blue: 212.0 / 255, alpha: 1)
    })
}

/// Exact accepted O1 copy, kept in one place so it can be asserted verbatim.
enum OnboardingCopy {
    static let brand = "CommonPlate"
    static let brandQualifier = "at NYU"
    static let heroTitle = "Meals move through community."
    static let heroSubtitle = "Sometimes you need a meal. Sometimes you have an extra swipe to share."
    static let scrollInvitation = "See how it works"
    static let sectionLabel = "HOW COMMONPLATE WORKS"
    static let continueTitle = "Continue to Home"
    static let grubhubBadge = "Grubhub"

    struct Step: Equatable {
        let title: String
        let detail: String
        var showsGrubhubBadge = false
    }

    static let story: [Step] = [
        Step(title: "Someone posts a meal request",
             detail: "They share what they need in CommonPlate."),
        Step(title: "Other students can find it",
             detail: "It appears on Home, and students can get notified when a new request is posted."),
        Step(title: "Someone chooses to help",
             detail: "A student with extra swipes steps in."),
        Step(title: "They place the order",
             detail: "The student helping uses their extra swipes.",
             showsGrubhubBadge: true),
        Step(title: "Pickup details come back",
             detail: "CommonPlate notifies the requester."),
        Step(title: "Then you pick it up",
             detail: "The helper lets you know about when to pick it up.")
    ]
}

struct OnboardingWelcomeView: View {
    let onContinue: () -> Void

    /// Measured height of the anchored brand header, so the final story stop
    /// fills exactly the viewport visible beneath it.
    @State private var headerHeight: CGFloat = 96

    /// Icon tiles appear on the first, third, and last story cards only, and
    /// the even cards sit indented, as drawn in the approved Welcome.
    private static let cardIcons: [Int: String] = [
        0: "fork.knife", 2: "hand.raised", 5: "figure.walk"
    ]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    heroPage(minHeight: geometry.size.height - headerHeight)
                    storySection(minHeight: geometry.size.height - headerHeight)
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            // The brand header stays anchored while the story scrolls beneath.
            .safeAreaInset(edge: .top, spacing: 0) {
                brandHeader
                    .padding(.horizontal, CommonPlateStyle.Spacing.l)
                    .padding(.vertical, CommonPlateStyle.Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CommonPlateStyle.Color.baseCanvas)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { headerHeight = proxy.size.height }
                                .onChange(of: proxy.size.height) { _, height in
                                    headerHeight = height
                                }
                        }
                    )
            }
        }
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
        .accessibilityIdentifier("onboarding-welcome")
    }

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
            Text(OnboardingCopy.brand)
                .font(.commonPlateBrandDisplay(.title))
            Text(OnboardingCopy.brandQualifier)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func heroPage(minHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: CommonPlateStyle.Spacing.xl)

            VStack(spacing: CommonPlateStyle.Spacing.m) {
                Text(OnboardingCopy.heroTitle)
                    .font(.commonPlateBrandDisplay(.largeTitle))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(OnboardingCopy.heroSubtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: CommonPlateStyle.Spacing.xl)

            // Non-interactive invitation to scroll; deliberately not a Button.
            VStack(spacing: CommonPlateStyle.Spacing.xs) {
                Text(OnboardingCopy.scrollInvitation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, CommonPlateStyle.Spacing.l)
        .padding(.bottom, CommonPlateStyle.Spacing.l)
        .frame(minHeight: minHeight)
    }

    private func storySection(minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(OnboardingCopy.sectionLabel)
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(Color.accentColor)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, CommonPlateStyle.Spacing.l)
                .padding(.bottom, CommonPlateStyle.Spacing.m)

            VStack(spacing: 0) {
                ForEach(Array(OnboardingCopy.story.enumerated()), id: \.offset) { index, step in
                    if index > 0 { StoryConnector() }
                    OnboardingStoryCard(
                        step: step,
                        iconName: Self.cardIcons[index],
                        isIndented: index % 2 == 1
                    )
                }
            }
            .padding(.horizontal, CommonPlateStyle.Spacing.l)

            Spacer(minLength: CommonPlateStyle.Spacing.xl)

            Button(OnboardingCopy.continueTitle) {
                onContinue()
            }
            .commonPlateMajorPrimaryAction()
            .padding(.horizontal, CommonPlateStyle.Metrics.homeContentColumnInset)
            .accessibilityIdentifier("onboarding-continue-to-home")
        }
        // Keeps the section label below the opening fold so the first stop is
        // only the hero and its scroll invitation.
        .padding(.top, CommonPlateStyle.Spacing.xl + CommonPlateStyle.Spacing.l)
        .padding(.bottom, CommonPlateStyle.Spacing.s)
        .frame(minHeight: minHeight, alignment: .top)
    }
}

/// One story step as a quiet bordered card, alternately indented, as drawn in
/// the approved Welcome. Combines into a single VoiceOver element.
struct OnboardingStoryCard: View {
    let step: OnboardingCopy.Step
    let iconName: String?
    let isIndented: Bool

    private static let indent: CGFloat = 32

    var body: some View {
        HStack(alignment: .top, spacing: CommonPlateStyle.Spacing.m) {
            if let iconName {
                Image(systemName: iconName)
                    .font(.footnote.weight(.semibold))
                    // Fixed 28 pt tile: cap the decorative glyph so it stays inside.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(
                        Color.accentColor.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: CommonPlateStyle.Spacing.s) {
                    Text(step.title)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if step.showsGrubhubBadge {
                        Spacer(minLength: CommonPlateStyle.Spacing.s)
                        GrubhubTextBadge()
                    }
                }
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, CommonPlateStyle.Spacing.m)
        .padding(.vertical, CommonPlateStyle.Spacing.m)
        .background(
            OnboardingCardSurface.fill,
            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                .strokeBorder(OnboardingCardSurface.border, lineWidth: 1)
        )
        .padding(.leading, isIndented ? Self.indent : 0)
        .padding(.trailing, isIndented ? 0 : Self.indent)
        .accessibilityElement(children: .combine)
    }
}

/// The short purple-dotted link between story cards that keeps the vertical
/// story reading as one continuous flow rather than six unrelated cards.
private struct StoryConnector: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.accentColor.opacity(0.22))
                .frame(width: 1.5)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 5, height: 5)
        }
        .frame(height: 20)
        .accessibilityHidden(true)
    }
}

/// The approved text-only `Grubhub` badge with a restrained orange tint. No
/// logo, mark, or third-party asset; this exception is not extended elsewhere.
private struct GrubhubTextBadge: View {
    private static let orange = Color(red: 0.96, green: 0.45, blue: 0.10)
    /// Mirrors the approved H1 Grubhub text values (light 156/71/0, dark
    /// 255/170/90) so the badge text stays legible in dark appearance.
    private static let text = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 170 / 255, blue: 90 / 255, alpha: 1)
            : UIColor(red: 156 / 255, green: 71 / 255, blue: 0, alpha: 1)
    })

    var body: some View {
        Text(OnboardingCopy.grubhubBadge)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Self.text)
            .padding(.horizontal, CommonPlateStyle.Spacing.s)
            .padding(.vertical, 2)
            .background(Self.orange.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(Self.orange.opacity(0.35), lineWidth: 0.5))
    }
}

/// One shared top anchor prevents first launch and recurring Home from drifting
/// as their surrounding layouts evolve independently.
struct CommonPlateBrandHeader: View {
    var body: some View {
        VStack(spacing: CommonPlateStyle.Spacing.xs) {
            Text("CommonPlate")
                .font(.commonPlateBrandDisplay(.largeTitle))
            Text("at NYU")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.accentColor)
        }
        .frame(maxWidth: .infinity)
    }
}

struct CommonPlateWarmGhostBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                // This control's fixed circle owns the symbol geometry. A
                // fixed symbol font keeps accessibility text sizes from
                // making the chevron protrude while nearby text still scales.
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(CommonPlateStyle.Color.warmSurface, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(CommonPlateWarmGhostBackButtonStyle())
        .accessibilityLabel("Back")
    }
}

private struct CommonPlateWarmGhostBackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
