//
//  HelperSuccessView.swift
//  CommonPlateios
//
// W4-H1 helper success: the brief ticket → meal presentation shown only after
// authoritative placement, followed by one automatic Home return. It is
// presentation, never lifecycle authority — `RequestStore` already ended the
// helper's active reservation before this presentation can exist, and nothing
// here (its dwell, its motion, its pauses, or its removal) decides what the
// helper may do next.
//
// Progression is active-scene aware. Only time spent while CommonPlate's scene
// is active advances the presentation, so the success haptic, the VoiceOver
// announcement, the readable dwell, and the Home return are never consumed
// while the helper cannot perceive them.
import Combine
import SwiftUI
import UIKit

/// The exact H1 success copy, keyed by the authoritative email outcome.
enum HelperSuccessCopy {
    static let headline = "Thanks for helping."

    /// `nil` when the email outcome is unknown: that state has a headline
    /// only. `requester` is the intentional noun for this surface.
    static func secondaryLine(for kind: FulfillmentConfirmationKind) -> String? {
        switch kind {
        case .notificationSent:
            return "We emailed the requester."
        case .notificationFailed:
            return "We couldn't email the requester."
        case .emailStatusUnknown:
            return nil
        }
    }

    /// One concise, truthful VoiceOver announcement: exactly the visible copy.
    static func accessibilityAnnouncement(for kind: FulfillmentConfirmationKind) -> String {
        [headline, secondaryLine(for: kind)]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

/// Per-process bookkeeping that makes each success presentation's two side
/// effects happen at most once per confirmation, whatever else happens to the
/// presentation. It holds no lifecycle authority and is never persisted, so a
/// relaunch can never replay a haptic or a Home return.
struct HelperSuccessPresentationLedger: Equatable {
    private(set) var successHapticConfirmationIDs: Set<UUID> = []
    private(set) var homeReturnConfirmationIDs: Set<UUID> = []

    /// `true` exactly once per confirmation: the caller fires the one
    /// semantic success haptic and announcement only when this returns `true`.
    mutating func claimSuccessHaptic(for confirmationID: UUID) -> Bool {
        successHapticConfirmationIDs.insert(confirmationID).inserted
    }

    /// `true` exactly once per confirmation: the caller applies the one
    /// automatic Home return only when this returns `true`.
    mutating func claimHomeReturn(for confirmationID: UUID) -> Bool {
        homeReturnConfirmationIDs.insert(confirmationID).inserted
    }

    func hasResolved(_ confirmationID: UUID) -> Bool {
        successHapticConfirmationIDs.contains(confirmationID)
    }
}

/// Engineering-owned motion values. Figma supplies the metaphor and
/// endpoints; these are the SwiftUI timing, travel, and scale choices.
struct HelperSuccessMotionPlan: Equatable {
    /// Active time the meal-swipe ticket is shown before it transforms.
    let ticketHold: Duration
    /// The swipe-to-meal transition, ending at the primary visual resolve.
    let transformDuration: Duration
    /// Continuous active readable time after the resolve before the
    /// automatic Home return.
    let readableDwell: Duration
    /// Where the ticket starts relative to the resolved meal. The two axes
    /// ease differently, so the inward travel follows a gentle curve.
    let ticketStartOffset: CGSize
    let ticketEndScale: CGFloat
    /// Minimal rotation, in degrees.
    let ticketRotation: Double
    let mealStartScale: CGFloat
    let copyRise: CGFloat

    static let standard = HelperSuccessMotionPlan(
        ticketHold: .milliseconds(350),
        transformDuration: .milliseconds(650),
        readableDwell: .milliseconds(2000),
        ticketStartOffset: CGSize(width: -16, height: 64),
        ticketEndScale: 0.55,
        ticketRotation: -5,
        mealStartScale: 0.78,
        copyRise: 6
    )

    /// Reduce Motion: materially lower displacement — no travel, curve, or
    /// rotation — while still crossfading the ticket into the meal, so the
    /// swipe → meal meaning is preserved.
    static let reducedMotion = HelperSuccessMotionPlan(
        ticketHold: .milliseconds(350),
        transformDuration: .milliseconds(400),
        readableDwell: .milliseconds(2000),
        ticketStartOffset: .zero,
        ticketEndScale: 1,
        ticketRotation: 0,
        mealStartScale: 1,
        copyRise: 0
    )

    static func plan(reduceMotion: Bool) -> HelperSuccessMotionPlan {
        reduceMotion ? .reducedMotion : .standard
    }

    var totalDuration: Duration {
        ticketHold + transformDuration + readableDwell
    }

    var transformSeconds: Double {
        let components = transformDuration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// The success presentation's active-time state machine for one confirmation.
/// Pure and deterministic: it only moves when told how much *active* time has
/// passed, and it never moves backwards past the resolve.
struct HelperSuccessProgression: Equatable {
    enum Phase: Equatable {
        /// The meal-swipe ticket, before the transform.
        case ticket
        /// The swipe-to-meal transition is running.
        case transforming
        /// Resolved meal and copy; the readable dwell is running.
        case dwelling
        /// The readable dwell completed while active.
        case finished
    }

    /// Effects that become due as active time crosses each boundary.
    enum Milestone: Equatable {
        case beginTransform
        /// The primary visual resolve: the one haptic and announcement.
        case resolve
        /// The one automatic Home return.
        case returnHome
    }

    let confirmationID: UUID
    let plan: HelperSuccessMotionPlan
    private(set) var phase: Phase = .ticket
    /// Active time accumulated in the current phase.
    private(set) var phaseElapsed: Duration = .zero

    init(confirmationID: UUID, plan: HelperSuccessMotionPlan) {
        self.confirmationID = confirmationID
        self.plan = plan
    }

    var hasResolved: Bool {
        phase == .dwelling || phase == .finished
    }

    /// Active time remaining until the next milestone, or `nil` once finished.
    var timeUntilNextMilestone: Duration? {
        switch phase {
        case .ticket:
            return max(.zero, plan.ticketHold - phaseElapsed)
        case .transforming:
            return max(.zero, plan.transformDuration - phaseElapsed)
        case .dwelling:
            return max(.zero, plan.readableDwell - phaseElapsed)
        case .finished:
            return nil
        }
    }

    /// Credits `activeElapsed` of foreground time and returns every milestone
    /// crossed, in order. Callers only pass time that was actually active.
    mutating func advance(by activeElapsed: Duration) -> [Milestone] {
        guard phase != .finished, activeElapsed >= .zero else { return [] }
        phaseElapsed += activeElapsed
        var milestones: [Milestone] = []
        while true {
            switch phase {
            case .ticket where phaseElapsed >= plan.ticketHold:
                phaseElapsed -= plan.ticketHold
                phase = .transforming
                milestones.append(.beginTransform)
            case .transforming where phaseElapsed >= plan.transformDuration:
                phaseElapsed -= plan.transformDuration
                phase = .dwelling
                milestones.append(.resolve)
            case .dwelling where phaseElapsed >= plan.readableDwell:
                phaseElapsed = .zero
                phase = .finished
                milestones.append(.returnHome)
                return milestones
            default:
                return milestones
            }
        }
    }

    /// The scene stopped being active. Nothing already perceived is undone,
    /// but nothing unperceived is kept: before the resolve the ticket and
    /// transition start over, and during the dwell the readable time starts
    /// over, so the helper always gets a complete foreground presentation.
    mutating func interrupt() {
        switch phase {
        case .ticket, .transforming:
            phase = .ticket
            phaseElapsed = .zero
        case .dwelling:
            phaseElapsed = .zero
        case .finished:
            break
        }
    }
}

/// Owns the one success progression for the current confirmation, outside any
/// view, so SwiftUI view recreation and repeated store publications can
/// neither restart it nor duplicate its effects. Presentation only: it never
/// reads or writes claim, reservation, or fulfillment truth.
@MainActor
final class HelperSuccessPresentationCoordinator: ObservableObject {
    @Published private(set) var progression: HelperSuccessProgression?
    private(set) var isSceneActive = false

    /// The one automatic Home return. Installed by the view that owns
    /// navigation; retired with the presentation it performs.
    var returnHome: ((FulfillmentConfirmation) -> Void)?

    private var confirmation: FulfillmentConfirmation?
    private var ledger = HelperSuccessPresentationLedger()
    private let performResolve: (FulfillmentConfirmation) -> Void
    private let planProvider: (Bool) -> HelperSuccessMotionPlan
    private let drivesAutomatically: Bool
    private let clock = ContinuousClock()
    private var lastTick: ContinuousClock.Instant?
    private var driver: Task<Void, Never>?

    /// `drivesAutomatically: false` lets tests step active time explicitly
    /// through `advance(by:)`.
    init(
        performResolve: @escaping (FulfillmentConfirmation) -> Void = HelperSuccessPresentationCoordinator.productionResolve,
        planProvider: @escaping (Bool) -> HelperSuccessMotionPlan = HelperSuccessMotionPlan.plan(reduceMotion:),
        drivesAutomatically: Bool = true
    ) {
        self.performResolve = performResolve
        self.planProvider = planProvider
        self.drivesAutomatically = drivesAutomatically
    }

    /// The exactly-once resolve effects: one semantic success haptic and one
    /// concise VoiceOver announcement.
    static func productionResolve(_ confirmation: FulfillmentConfirmation) {
        CommonPlateHaptics.success()
        UIAccessibility.post(
            notification: .announcement,
            argument: HelperSuccessCopy.accessibilityAnnouncement(for: confirmation.kind)
        )
    }

    /// Mirrors the store's current confirmation. Idempotent for the same
    /// confirmation, so repeated publications never restart the sequence; a
    /// different confirmation starts its own; `nil` retires the presentation.
    func update(confirmation newConfirmation: FulfillmentConfirmation?, reduceMotion: Bool) {
        guard let newConfirmation else {
            confirmation = nil
            progression = nil
            stopDriver()
            return
        }
        guard newConfirmation.id != confirmation?.id else { return }
        confirmation = newConfirmation
        progression = HelperSuccessProgression(
            confirmationID: newConfirmation.id,
            plan: planProvider(reduceMotion)
        )
        restartDriver()
    }

    /// Scene activity is the only thing that lets active time count. Becoming
    /// inactive interrupts the progression before any time can be credited;
    /// becoming active starts counting from that moment, never from before.
    func updateSceneActivity(isActive: Bool) {
        guard isActive != isSceneActive else { return }
        isSceneActive = isActive
        if isActive {
            restartDriver()
        } else {
            stopDriver()
            progression?.interrupt()
        }
    }

    /// Credits active time and applies any due effects exactly once. Ignored
    /// while inactive.
    func advance(by activeElapsed: Duration) {
        guard isSceneActive,
              var current = progression,
              let confirmation,
              current.confirmationID == confirmation.id else {
            return
        }
        let milestones = current.advance(by: activeElapsed)
        progression = current
        for milestone in milestones {
            switch milestone {
            case .beginTransform:
                break
            case .resolve:
                if ledger.claimSuccessHaptic(for: confirmation.id) {
                    performResolve(confirmation)
                }
            case .returnHome:
                if let returnHome, ledger.claimHomeReturn(for: confirmation.id) {
                    returnHome(confirmation)
                }
            }
        }
        if progression?.phase == .finished {
            stopDriver()
        }
    }

    private func restartDriver() {
        stopDriver()
        guard drivesAutomatically,
              isSceneActive,
              let progression,
              progression.phase != .finished else {
            return
        }
        lastTick = clock.now
        driver = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = self?.progression?.timeUntilNextMilestone else { return }
                do {
                    try await Task.sleep(for: wait)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        let now = clock.now
        let elapsed = now - (lastTick ?? now)
        lastTick = now
        advance(by: elapsed)
    }

    private func stopDriver() {
        driver?.cancel()
        driver = nil
        lastTick = nil
    }
}

/// Renders a success progression. Holds no progression state of its own, so
/// recreating it can neither restart the sequence nor replay its effects.
struct HelperSuccessView: View {
    let confirmation: FulfillmentConfirmation
    let phase: HelperSuccessProgression.Phase
    let reduceMotion: Bool

    @State private var isVisible = false

    private var plan: HelperSuccessMotionPlan {
        HelperSuccessMotionPlan.plan(reduceMotion: reduceMotion)
    }

    private var isTransformed: Bool {
        phase != .ticket
    }

    private var hasResolved: Bool {
        phase == .dwelling || phase == .finished
    }

    private var transformAnimation: Animation {
        .timingCurve(0.3, 0, 0.2, 1, duration: plan.transformSeconds)
    }

    var body: some View {
        ZStack {
            CommonPlateStyle.Color.baseCanvas
                .ignoresSafeArea()

            VStack(spacing: 22) {
                motif
                    .frame(width: 96, height: 96)

                VStack(spacing: 10) {
                    Text(HelperSuccessCopy.headline)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .accessibilityIdentifier("helper-success-headline")

                    if let secondary = HelperSuccessCopy.secondaryLine(for: confirmation.kind) {
                        Text(secondary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("helper-success-secondary")
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: CommonPlateStyle.Metrics.stateContentWidth)
                .opacity(isTransformed ? 1 : 0)
                .offset(y: isTransformed ? 0 : plan.copyRise)
                .animation(transformAnimation, value: isTransformed)
                .accessibilityElement(children: .combine)
                .accessibilityHidden(!hasResolved)
            }
            .padding(.horizontal, CommonPlateStyle.Metrics.settingsPageInset)
            // The approved composition sits a little above the geometric center.
            .padding(.bottom, 60)
        }
        .opacity(isVisible ? 1 : 0)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("helper-success")
        .onAppear {
            // A focused Helping-page field must not leave its keyboard over
            // the presentation.
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
            withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.22)) {
                isVisible = true
            }
        }
    }

    @ViewBuilder
    private var motif: some View {
        ZStack {
            // Horizontal travel eases in and vertical travel eases out, which
            // bends the inward path into a gentle arc toward the meal.
            ticket
                .scaleEffect(isTransformed ? plan.ticketEndScale : 1)
                .rotationEffect(.degrees(isTransformed ? plan.ticketRotation : 0))
                .animation(transformAnimation, value: isTransformed)
                .offset(x: isTransformed ? 0 : plan.ticketStartOffset.width)
                .animation(.easeIn(duration: plan.transformSeconds), value: isTransformed)
                .offset(y: isTransformed ? 0 : plan.ticketStartOffset.height)
                .animation(.easeOut(duration: plan.transformSeconds), value: isTransformed)
                .opacity(isTransformed ? 0 : 1)
                .animation(.easeIn(duration: plan.transformSeconds * 0.8), value: isTransformed)

            meal
                .scaleEffect(isTransformed ? 1 : plan.mealStartScale)
                .opacity(isTransformed ? 1 : 0)
                .animation(transformAnimation, value: isTransformed)
        }
    }

    /// Template-rendered so the adaptive `AccentColor` supplies the correct
    /// purple in light and dark appearance, exactly like the existing
    /// `TicketToMealMotif`. The Figma geometry is unchanged.
    private var ticket: some View {
        Image("HelperSuccessTicket")
            .renderingMode(.template)
            .foregroundStyle(Color.accentColor)
            .accessibilityHidden(true)
    }

    private var meal: some View {
        Image("HelperSuccessMeal")
            .renderingMode(.template)
            .foregroundStyle(Color.accentColor)
            .accessibilityHidden(true)
    }
}
