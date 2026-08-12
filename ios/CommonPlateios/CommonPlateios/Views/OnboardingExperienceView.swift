//
//  OnboardingExperienceView.swift
//  CommonPlateios
//
// Educational onboarding only. Its path is intentionally ephemeral: both
// choices lead to the same recurring Home and create no participant role.

import SwiftUI

enum OnboardingIntent: Hashable, Identifiable {
    case gettingAMeal
    case usingExtraSwipes

    var id: Self { self }
}

struct OnboardingExperienceView: View {
    let onStartFlow: (OnboardingIntent) -> Void
    var onBack: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: CommonPlateStyle.Spacing.l) {
                    CommonPlateBrandHeader()

                    // Keep the story cluster fixed while giving the action
                    // stack a deliberately small additional downward bias.
                    Spacer(minLength: CommonPlateStyle.Spacing.l)

                    VStack(spacing: CommonPlateStyle.Spacing.m) {
                        Text("Extra swipes. More meals.")
                            .font(.commonPlateBrandDisplay(.title))
                            .multilineTextAlignment(.center)

                        Image("TicketToMealMotif")
                            // The source SVG stays Faith's exact motif. The
                            // existing adaptive AccentColor asset supplies
                            // the appropriate purple in both appearances.
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 118, height: 46)
                            .accessibilityLabel("A meal swipe ticket leading to a meal")

                        Text("CommonPlate helps students turn extra\nmeal swipes into meals for other students.")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: CommonPlateStyle.Spacing.s)

                    VStack(spacing: CommonPlateStyle.Spacing.m) {
                        intentButton(
                            title: "I need a meal",
                            intent: .gettingAMeal,
                            primary: true
                        )
                        intentButton(
                            title: "I have extra meal swipes",
                            intent: .usingExtraSwipes,
                            primary: false
                        )
                    }
                    .padding(.top, CommonPlateStyle.Spacing.s)
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                // Keep the bottom-biased actions inside the measured safe
                // presentation area. Padding is deliberately applied before
                // the minimum-height frame: at ordinary text sizes the
                // spacer uses the remaining space, while small screens and
                // larger Dynamic Type naturally scroll instead of clipping
                // either action below the safe area.
                .padding(.horizontal, CommonPlateStyle.Spacing.l)
                .padding(.top, CommonPlateStyle.Spacing.l)
                .padding(.bottom, CommonPlateStyle.Spacing.m)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
        .accessibilityIdentifier("onboarding-chooser")
        .overlay(alignment: .topLeading) {
            if let onBack {
                CommonPlateWarmGhostBackButton(action: onBack)
                    .padding(.leading, CommonPlateStyle.Spacing.l)
                    .padding(.top, CommonPlateStyle.Spacing.l)
            }
        }
    }

    private func intentButton(title: String, intent: OnboardingIntent, primary: Bool) -> some View {
        Button(title) {
            onStartFlow(intent)
        }
        .modifier(OnboardingActionStyle(primary: primary))
        .commonPlateMajorActionFrame()
    }
}

struct OnboardingWalkthroughView: View {
    let intent: OnboardingIntent
    let onContinue: () -> Void
    var onBack: (() -> Void)?

    var body: some View {
        let content = Self.content(for: intent)
        return GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(content.title)
                        .font(.title.weight(.bold))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, onBack == nil ? 0 : 48)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(content.steps.enumerated()), id: \.offset) { index, step in
                            WalkthroughStepRow(
                                number: index + 1,
                                instruction: step,
                                showsDivider: index < content.steps.count - 1
                            )
                        }
                    }
                    .padding(.top, CommonPlateStyle.Spacing.xl)

                    if intent == .usingExtraSwipes {
                        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
                            Text("No requests available?")
                                .font(.headline)
                            Text("Turn on request alerts from Home.")
                        }
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(CommonPlateStyle.Spacing.m)
                        .background(
                            CommonPlateStyle.Color.warmSurface,
                            in: RoundedRectangle(
                                cornerRadius: CommonPlateStyle.Radius.standard,
                                style: .continuous
                            )
                        )
                        .padding(.top, CommonPlateStyle.Spacing.xl)
                    }

                    // On ordinary phones this expands to give Continue a
                    // deliberate concluding position. It never exceeds the
                    // local cap, and collapses before journey/alert spacing
                    // when scrolling accessibility or short-screen content.
                    Spacer(minLength: 0)
                        .frame(maxHeight: OnboardingWalkthroughLayout.continueSeparationMaximum)

                    Button("Continue") {
                        onContinue()
                    }
                    .commonPlateMajorPrimaryAction()
                    .commonPlateMajorActionFrame()
                    .padding(.top, CommonPlateStyle.Spacing.l)
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, CommonPlateStyle.Spacing.l)
                .padding(.vertical, CommonPlateStyle.Spacing.l)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
        .accessibilityIdentifier(intent == .gettingAMeal ? "onboarding-getting-meal" : "onboarding-extra-swipes")
        .navigationBarBackButtonHidden(onBack != nil)
        .toolbar(onBack == nil ? .automatic : .hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) {
            if let onBack {
                CommonPlateWarmGhostBackButton(action: onBack)
                    .padding(.leading, CommonPlateStyle.Spacing.l)
                    .padding(.top, CommonPlateStyle.Spacing.l)
            }
        }
    }

    static func content(for intent: OnboardingIntent) -> (title: String, steps: [String]) {
        switch intent {
        case .gettingAMeal:
            return (
                "Getting a meal",
                [
                    "Build your order in Grubhub",
                    "Add your order details to CommonPlate",
                    "A student reserves and places your order",
                    "CommonPlate emails you the pickup details"
                ]
            )
        case .usingExtraSwipes:
            return (
                "Using your extra swipes",
                [
                    "Browse available requests",
                    "Choose a request",
                    "Place the order in Grubhub",
                    "Add the pickup details to CommonPlate"
                ]
            )
        }
    }
}

/// Walkthrough-owned pacing only. This cap keeps the flexible conclusion from
/// becoming a blank region on tall phones while allowing it to collapse in
/// scroll-constrained layouts.
private enum OnboardingWalkthroughLayout {
    static let continueSeparationMaximum: CGFloat = 128
}

private struct WalkthroughStepRow: View {
    let number: Int
    let instruction: String
    let showsDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: CommonPlateStyle.Spacing.l) {
                Text("\(number)")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 46, height: 46)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(
                            cornerRadius: CommonPlateStyle.Radius.standard,
                            style: .continuous
                        )
                    )

                Text(instruction)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            }
            .padding(.vertical, CommonPlateStyle.Spacing.m)

            if showsDivider {
                Divider()
                    .padding(.horizontal, CommonPlateStyle.Spacing.s)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingActionStyle: ViewModifier {
    let primary: Bool

    func body(content: Content) -> some View {
        if primary {
            content.commonPlateMajorPrimaryAction()
        } else {
            content.commonPlateMajorSecondaryAction()
        }
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
