//
//  RefreshMotionPrototypeView.swift
//  CommonPlateios
//
// W4-H2 — iOS Implementation Prototype (Section 6). This is NOT production
// Home behavior. It is an isolated, DEBUG-only SwiftUI surface that lets
// Faith exercise the candidate refresh-cue motion deterministically, without
// network timing, before any of it is integrated into the real
// `HomeExchangeView`.
//
// This file intentionally does not import or reuse `HomeExchangeView`'s
// `PullRefreshPhase` / `PullRefreshCueRow` — the whole point of this pass is
// to prove the motion in isolation first. Nothing here is wired to
// `RequestStore`, `.refreshable`, or any network call, and nothing here is
// reachable from ordinary app navigation (see `#if DEBUG` below and
// `ContentView`'s debug-only entry, if one is added).
//
// Architecture note (Section 7, "one persistent refresh cue"): the whole
// point of building this separately is to avoid the production flash
// (Section 13) suspected to come from conditionally mounting/unmounting the
// cue container as pull geometry resets. `PrototypeRefreshCue` below is
// ALWAYS mounted — only its internal icon/text/background properties change
// by phase. Nothing in this file inserts or removes the cue view itself.
import Combine
import SwiftUI

#if DEBUG

/// The candidate phase model (Section 7). Failure is not a phase of its
/// own — it is modeled as returning to `.unavailable(recovered: false)`,
/// matching the production contract's "still unavailable" outcome.
enum PrototypeRefreshPhase: Equatable {
    case idleUnavailable
    case idleHealthy
    case pulling(progress: CGFloat)
    case refreshing
    case recoverySuccess
    case stillUnavailable
}

/// Deterministic, manually-driven state — the "lightweight debug/Preview
/// state driver" the spec calls for. No timers tied to real network
/// latency; every transition is explicit so the motion can be paused,
/// replayed, and inspected at each step.
@MainActor
final class RefreshMotionPrototypeDriver: ObservableObject {
    @Published private(set) var phase: PrototypeRefreshPhase = .idleUnavailable
    @Published var reduceMotionOverride = false
    @Published var startedFromHealthyBoard = false

    func setPullProgress(_ progress: Double) {
        phase = .pulling(progress: CGFloat(min(max(progress, 0), 1)))
    }

    /// Mirrors `performAuthoredRefresh()` entering `isRefreshInFlight`: the
    /// only way into `.refreshing` is from a pull already in progress or an
    /// idle state, never a synthetic shortcut.
    func activateRefresh() {
        phase = .refreshing
    }

    /// Recovery succeeds (Section 11): Unavailable → pulling → refreshing →
    /// authoritative healthy truth → brief checkmark → next Home state.
    func resolveRecoverySuccess() {
        phase = .recoverySuccess
    }

    /// Still unavailable (Section 11): no checkmark, straight back to the
    /// unavailable idle cue.
    func resolveStillUnavailable() {
        phase = .stillUnavailable
    }

    /// Normal healthy-board refresh (Section 11): no checkmark required; the
    /// refreshed board content itself is the outcome, so this returns
    /// straight to the healthy idle state.
    func resolveHealthyRefresh() {
        phase = .idleHealthy
    }

    func reset(toHealthy: Bool) {
        startedFromHealthyBoard = toHealthy
        phase = toHealthy ? .idleHealthy : .idleUnavailable
    }
}

/// The persistently-mounted refresh cue (Section 7/8/9/10). Every visual
/// property below is driven by `phase`; the view itself is never
/// conditionally inserted or removed by its caller — see
/// `RefreshMotionPrototypeHarness.body`, which always renders this.
struct PrototypeRefreshCue: View {
    let phase: PrototypeRefreshPhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    var reduceMotionOverride: Bool = false
    @State private var isSpinning = false

    private var reduceMotion: Bool { systemReduceMotion || reduceMotionOverride }

    var body: some View {
        HStack(spacing: CommonPlateStyle.Spacing.xs) {
            icon
            if let text {
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.opacity)
            }
        }
        .foregroundStyle(Color.accentColor)
        .frame(minHeight: 28)
        .padding(.horizontal, CommonPlateStyle.Spacing.m)
        .padding(.vertical, CommonPlateStyle.Spacing.s)
        .background(
            Color.accentColor.opacity(backgroundOpacity),
            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: phase)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Section 9: "the existing cue should TRANSFORM rather than disappear
    /// and be replaced." One `Image(systemName:)` whose symbol and
    /// modifiers change by phase — never a second overlaid spinner, never a
    /// blank frame between arrow and spinner.
    ///
    /// `.symbolEffect(.rotate, options: .repeating, ...)` would be the ideal
    /// continuous-spin mechanism, but it requires iOS 18 — this repository's
    /// deployment target is 17.6 (`docs/testing.md` section 7), and the spec
    /// explicitly forbids raising it merely for a newer animation API. The
    /// fallback below is an ordinary `.rotationEffect` driven by
    /// `withAnimation(...).repeatForever()`, matching the same
    /// state-driven-repeat pattern the *production* idle-bounce cue already
    /// uses in `HomeExchangeView.PullRefreshCueRow` — a compatible,
    /// continuity-preserving equivalent rather than an unsupported hack.
    @ViewBuilder
    private var icon: some View {
        Image(systemName: symbolName)
            .font(.body.weight(.semibold))
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .rotationEffect(.degrees(isSpinning && !reduceMotion ? 360 : 0))
            .symbolEffect(
                .bounce,
                options: .nonRepeating,
                value: isRecoverySuccessTransition
            )
            .offset(y: reduceMotion ? 0 : pullOffsetY)
            .opacity(reduceMotion ? 1 : pullOpacity)
            .accessibilityHidden(true)
            .onAppear { updateSpinning() }
            .onChange(of: phase) { updateSpinning() }
            .onChange(of: reduceMotion) { updateSpinning() }
    }

    private func updateSpinning() {
        guard phase == .refreshing, !reduceMotion else {
            isSpinning = false
            return
        }
        isSpinning = false
        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
            isSpinning = true
        }
    }

    private var symbolName: String {
        switch phase {
        case .idleUnavailable, .idleHealthy, .pulling, .stillUnavailable:
            return "arrow.down"
        case .refreshing:
            return "arrow.triangle.2.circlepath"
        case .recoverySuccess:
            return "checkmark.circle.fill"
        }
    }

    private var isRecoverySuccessTransition: Bool {
        phase == .recoverySuccess
    }

    private var pullOffsetY: CGFloat {
        guard case .pulling(let progress) = phase else { return 0 }
        return progress * 10
    }

    private var pullOpacity: Double {
        guard case .pulling(let progress) = phase else { return 1 }
        return 0.55 + Double(progress) * 0.45
    }

    private var backgroundOpacity: Double {
        switch phase {
        case .idleUnavailable, .idleHealthy: return 0
        default: return 0.12
        }
    }

    private var text: String? {
        switch phase {
        case .idleUnavailable, .pulling, .stillUnavailable:
            return "Pull down to refresh"
        case .idleHealthy:
            return nil
        case .refreshing:
            return "Refreshing"
        case .recoverySuccess:
            return nil
        }
    }

    private var accessibilityLabel: String {
        switch phase {
        case .recoverySuccess: return "Updated"
        default: return text ?? ""
        }
    }
}

/// The smallest DEBUG-only harness screen: exercises every phase manually,
/// against the real CommonPlate warm canvas / typography / purple token and
/// the real "Helping is temporarily unavailable" wording, without requiring
/// Simulator network timing. Not reachable from ordinary product navigation.
struct RefreshMotionPrototypeHarness: View {
    @StateObject private var driver = RefreshMotionPrototypeDriver()
    @State private var pullSlider: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.l) {
            header

            VStack(spacing: CommonPlateStyle.Spacing.m) {
                if driver.startedFromHealthyBoard {
                    healthyBoardPreview
                } else {
                    unavailablePreview
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, CommonPlateStyle.Spacing.xl)
            .background(
                CommonPlateStyle.Color.baseCanvas,
                in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
            )

            controls
        }
        .padding(CommonPlateStyle.Spacing.l)
        .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("iOS Implementation Prototype")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text("H2 Refresh Motion")
                .font(.title3.weight(.bold))
        }
    }

    private var unavailablePreview: some View {
        VStack(spacing: CommonPlateStyle.Spacing.m) {
            Text("Helping is\ntemporarily unavailable")
                .font(.headline.weight(.bold))
                .multilineTextAlignment(.center)

            // Always mounted — see `PrototypeRefreshCue` doc comment.
            PrototypeRefreshCue(phase: driver.phase, reduceMotionOverride: driver.reduceMotionOverride)
        }
    }

    private var healthyBoardPreview: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.s) {
            PrototypeRefreshCue(phase: driver.phase, reduceMotionOverride: driver.reduceMotionOverride)
                .opacity(driver.phase == .idleHealthy ? 0 : 1)
                .frame(height: driver.phase == .idleHealthy ? 0 : nil)

            ForEach(["Palladium — Rice bowl", "Kimmel — Sandwich"], id: \.self) { row in
                Text(row)
                    .font(.subheadline)
                    .padding(.horizontal, CommonPlateStyle.Spacing.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, CommonPlateStyle.Spacing.l)
    }

    // MARK: - Deterministic driver controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
            Toggle("Start from healthy board", isOn: Binding(
                get: { driver.startedFromHealthyBoard },
                set: { driver.reset(toHealthy: $0) }
            ))

            Toggle("Reduce Motion (override)", isOn: $driver.reduceMotionOverride)

            VStack(alignment: .leading) {
                Text("Pull progress: \(Int(pullSlider * 100))%")
                    .font(.footnote)
                Slider(value: $pullSlider, in: 0...1) { editing in
                    if editing { driver.setPullProgress(pullSlider) }
                }
                .onChange(of: pullSlider) { _, newValue in
                    driver.setPullProgress(newValue)
                }
            }

            HStack {
                Button("Refreshing") { driver.activateRefresh() }
                Button("Recovery success") { driver.resolveRecoverySuccess() }
                Button("Still unavailable") { driver.resolveStillUnavailable() }
            }
            .buttonStyle(.bordered)

            Button("Healthy refresh (no checkmark)") { driver.resolveHealthyRefresh() }
                .buttonStyle(.bordered)

            Button("Reset to idle") { driver.reset(toHealthy: driver.startedFromHealthyBoard) }
                .buttonStyle(.borderedProminent)
        }
    }
}

// Reduce Motion is exercised via the harness's own "Reduce Motion
// (override)" toggle rather than an injected `#Preview` environment value —
// this keeps one interactive Simulator/canvas surface for every phase
// instead of a separate static preview that would drift from it.
#Preview("H2 Refresh Motion Prototype") {
    RefreshMotionPrototypeHarness()
}

#endif
