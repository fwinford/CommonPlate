//
//  HomeExchangeRefreshDeadlineTests.swift
//  CommonPlateiosTests
//
// W4-H2-FIX (manual refresh timeout + final cue transition): focused
// source-text coverage for HQ decision 8 (the 5-second manual-refresh
// deadline), the stale/cancel safety it relies on, and the pull-arrow →
// refresh-symbol transition/text-ghosting correction. This target has no UI
// test infrastructure to drive `.refreshable` interactively, so — following
// `HomeExchangeStatePresentationTests`'s existing precedent — these
// assertions pin the production source directly.
import Foundation
import XCTest
@testable import CommonPlateios

final class HomeExchangeRefreshDeadlineTests: XCTestCase {
    // MARK: - Manual refresh deadline (HQ decision 8)

    func testManualRefreshDeadlineIsFiveSeconds() {
        XCTAssertEqual(HomeExchangeView.manualRefreshDeadline, .seconds(5))
    }

    /// The initial-load deadline (HQ decision 5) and the manual-refresh
    /// deadline (HQ decision 8) are two distinct bounded presentation
    /// lifetimes; they must not collapse into a single shared flag/authority.
    func testInitialLoadAndManualRefreshDeadlinesAreDistinct() {
        XCTAssertEqual(HomeExchangeView.initialLoadDeadline, .seconds(5))
        XCTAssertEqual(HomeExchangeView.manualRefreshDeadline, .seconds(5))
    }

    func testPerformAuthoredRefreshRacesTheFetchAgainstTheManualDeadline() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertTrue(source.contains(
            "let didResolveInTime = await Self.awaitWithDeadline(Self.manualRefreshDeadline) {"
        ))
        XCTAssertTrue(source.contains("guard didResolveInTime else { return }"))
    }

    /// Cancellation/stale-result correctness relies entirely on
    /// `RequestStore`'s own existing `fetchGeneration`/`collectionRevision`
    /// fence — this delta introduces no second request-list truth owner and
    /// no independent reload/timeout authority in the store.
    func testAwaitWithDeadlineCancelsTheLoserAndInvokesNoSecondReloadAuthority() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertTrue(source.contains("private static func awaitWithDeadline("))
        XCTAssertTrue(source.contains("withTaskGroup(of: Bool.self)"))
        XCTAssertTrue(source.contains("group.cancelAll()"))

        // Exactly two call sites invoke the one authoritative reload directly
        // — the initial-appearance `.task` and the refresh closure the
        // deadline race wraps — and no independent reload/truth authority is
        // added beyond that same existing path.
        let reloadOccurrences = source.components(separatedBy: "await store.fetchRequests()").count - 1
        XCTAssertEqual(reloadOccurrences, 2)

        // The participant-identity-change re-key reaches that same reload
        // through `RequestStore.reconcileOwnershipForCurrentAuthority()`,
        // which invalidates the previous authority's caller-relative
        // ownership and then delegates to `fetchRequests()` itself. It is a
        // third *entry point* to the one existing reload, not a second
        // request-list truth owner.
        let reconcileOccurrences = source
            .components(separatedBy: "await store.reconcileOwnershipForCurrentAuthority()").count - 1
        XCTAssertEqual(reconcileOccurrences, 1)
    }

    /// A refresh that times out ends the refresh interaction without a
    /// success checkmark, and never invokes any recovery/fabrication path
    /// after the `guard didResolveInTime else { return }` above returns.
    func testTimeoutNeverReachesTheRecoveryCheckmarkAssignment() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        guard let refreshRange = source.range(of: "private func performAuthoredRefresh() async {"),
              let guardRange = source.range(
                of: "guard didResolveInTime else { return }",
                range: refreshRange.upperBound..<source.endIndex
              ),
              let checkmarkRange = source.range(
                of: "isShowingRecoverySuccess = true",
                range: refreshRange.upperBound..<source.endIndex
              )
        else {
            return XCTFail("expected performAuthoredRefresh to contain the deadline guard and checkmark assignment")
        }

        XCTAssertLessThan(guardRange.upperBound, checkmarkRange.lowerBound)
    }

    // MARK: - Refresh symbol transition (pull arrow → circular refresh symbol)

    /// The refreshing symbol itself spins; the pull arrow must never appear
    /// to rotate in place. Starting the continuous rotation in lockstep with
    /// the `.symbolEffect(.replace)` morph applied rotation to the morph
    /// itself, reading as the old arrow spinning into place — the delayed,
    /// generation-fenced start below keeps the two motions separate.
    func testSpinStartIsDeferredPastTheSymbolMorphAndGenerationFenced() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertTrue(source.contains("private static let symbolMorphDuration: Duration = .milliseconds(350)"))
        XCTAssertTrue(source.contains("@State private var spinGeneration = 0"))
        XCTAssertTrue(source.contains("try? await Task.sleep(for: Self.symbolMorphDuration)"))
        XCTAssertTrue(source.contains("guard generation == spinGeneration else { return }"))
    }

    // MARK: - Text ghosting

    /// Faith's screenshot showed `Refreshing`/`Pull down to refresh` reading
    /// simultaneously. `.contentTransition(.opacity)` on the cue's `Text`
    /// crossfades the old and new strings on top of each other while the
    /// symbol carries the authored motion instead; the fix is a clean,
    /// non-animated text swap.
    func testRefreshCueTextHasNoCrossfadeContentTransition() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        guard let cueRange = source.range(of: "private struct PullRefreshCue: View {") else {
            return XCTFail("expected PullRefreshCue to be defined")
        }
        let cueBody = source[cueRange.lowerBound...]
        XCTAssertFalse(cueBody.contains(".contentTransition(.opacity)"))
    }

    // MARK: - Recovery bounce respects Reduce Motion (review triage finding 2)

    /// The recovery checkmark itself must always render (static communication
    /// of recovery is never removed by Reduce Motion), but its `.bounce`
    /// symbol effect must not trigger while Reduce Motion is on — matching
    /// every other motion in this cue (spin, pull-progress offset/opacity).
    func testRecoveryBounceIsSuppressedByReduceMotion() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")

        XCTAssertTrue(source.contains(
            ".symbolEffect(.bounce, options: .nonRepeating, value: !reduceMotion && phase == .recoverySuccess)"
        ))
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
