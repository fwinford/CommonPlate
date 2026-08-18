//
//  RequestFoodEntryView.swift
//  CommonPlateios
//
// The screen `AppRoute.requestFood` actually opens (W3-I2). An unverified
// installation sees the existing participant-verification screen before it
// ever sees the Request Food form; a verified one — freshly, or restored from
// a previous launch — goes straight to `RequestFoodView`. This supersedes only
// W3-I1's entry sequencing: the identity, credential, storage, and lifetime it
// consumes are unchanged, and `RequestFoodView` keeps its own submit-time
// gate for the residual case where identity is lost after this screen already
// let the form through (a mid-form backend rejection).
import SwiftUI

enum RequestFoodEntryPresentation: Equatable {
    case verification
    case form
}

struct RequestFoodEntryView: View {
    @ObservedObject var store: RequestStore
    @ObservedObject var screenshotProposalStore: ScreenshotProposalStore
    /// Observed, not owned: the same identity every other participant action
    /// reads, so a verification completed here is immediately visible to the
    /// form this screen reveals.
    @ObservedObject var identityStore: ParticipantIdentityStore
    @ObservedObject var verificationCoordinator: ParticipantActionVerificationCoordinator
    @Binding var path: [AppRoute]
    let onExit: () -> Void

    /// Sticky once set (W3-I2 review correction): this session already
    /// legitimately admitted a verified requester into `RequestFoodView`. A
    /// later `PARTICIPANT_AUTHORITY_INVALID` (`identityStore.discardRejectedIdentity()`)
    /// clears `isVerified`, but that is a mid-form authority loss, not a
    /// reason to tear this screen's `.form` case down and destroy the mounted
    /// `RequestFoodView`'s draft — `RequestFoodView` already owns recovering
    /// from exactly that loss through its own submit-time gate and
    /// `verificationCoordinator`-driven continuation sheet. Never reset once
    /// true: this screen is not re-created without a fresh navigation to
    /// `.requestFood`, which starts a new instance with this back at `false`.
    @State private var hasEnteredForm = false
    @State private var hasRequestedExit = false

    var body: some View {
        Group {
            switch Self.presentation(isVerified: identityStore.isVerified, hasEnteredForm: hasEnteredForm) {
            // `ParticipantVerificationView` wraps its own `NavigationStack`
            // (needed for its own title/toolbar when it is the app's one
            // in-form sheet). Pushing it as this destination's own body — a
            // `NavigationStack` nested directly inside another
            // `NavigationStack`'s `.navigationDestination` content — corrupted
            // this app's typed `[AppRoute]` path comparison on a physical
            // device (`AnyNavigationPath.Error.comparisonTypeMismatch`),
            // reachable only through real interactive navigation state that
            // an `XCTest` run never mounts. Presenting it as a sheet instead
            // reuses the exact modal-presentation pattern `RequestFoodView`'s
            // own defensive gate already relies on, so nothing here is a new
            // verification implementation — the destination itself is never
            // more than this placeholder while unverified, and the sheet is
            // what the requester actually sees.
            case .verification:
                ParticipantVerificationView(
                    store: identityStore,
                    cancel: cancelEntryVerification
                )
            case .form:
                NavigationStack {
                    RequestFoodView(
                        store: store,
                        screenshotProposalStore: screenshotProposalStore,
                        identityStore: identityStore,
                        verificationCoordinator: verificationCoordinator,
                        path: $path,
                        onExit: beginExit
                    )
                    .navigationBarBackButtonHidden(true)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: beginExit) {
                                Image(systemName: "chevron.left")
                            }
                            .accessibilityLabel("Back")
                        }
                    }
                }
            }
        }
        // Entry-owned admission only: once `hasEnteredForm` is set, a later
        // appearance (e.g. returning from backgrounding after a mid-form
        // `PARTICIPANT_AUTHORITY_INVALID` cleared identity) must not start
        // another `.firstVerification` flow here. `beginVerification(for:)`
        // refuses a second flow while one already exists, so a stray entry
        // flow left running by this call would silently block
        // `RequestFoodView`'s own coordinator-owned recovery flow from ever
        // starting — the exact rereview finding. Before admission this
        // remains `beginVerificationIfNeeded()`'s own idempotent guard: a
        // no-op when already verified, and a no-op that resumes rather than
        // restarts when a flow this same gate opened is still running.
        .onAppear {
            guard Self.shouldBeginEntryVerificationOnAppear(hasEnteredForm: hasEnteredForm) else {
                return
            }
            identityStore.beginVerificationIfNeeded()
        }
        // Latches `hasEnteredForm` the moment identity first becomes usable —
        // covering both a fresh verification finishing here and an
        // already-verified/restored identity present at first appearance,
        // since `onChange` fires once for the initial value's own appearance
        // in that case too. Never unlatched: `identityStore.isVerified`
        // becoming false afterward is the exact mid-form loss this screen
        // must not react to.
        .onChange(of: identityStore.isVerified, initial: true) { _, isVerified in
            hasEnteredForm = Self.nextHasEnteredForm(
                previousHasEnteredForm: hasEnteredForm,
                isVerified: isVerified
            )
        }
    }

    /// Abandoning verification here has no filled draft to protect — unlike
    /// the in-form sheet, nothing has been shown yet — so Cancel also leaves
    /// Request Food rather than reopening the same empty gate.
    private func cancelEntryVerification() {
        Self.cancelEntryVerification(identityStore: identityStore, onExit: beginExit)
    }

    /// The Home-owned sheet's binding is changed by `onExit`; this entry does
    /// not retain a second presentation state or animate itself out.
    static func cancelEntryVerification(
        identityStore: ParticipantIdentityStore,
        onExit: () -> Void
    ) {
        identityStore.cancelVerification()
        onExit()
    }

    private func beginExit() {
        guard !hasRequestedExit else { return }
        hasRequestedExit = true
        // `ContentView` owns the native sheet binding and clears its local
        // requester route only from that sheet's `onDismiss`. This entry has
        // no visual exit layer, so Home remains the stable surface below it.
        onExit()
    }

    /// `hasEnteredForm` defaults to `false` so every existing initial-entry
    /// call site (no prior admission this session) is unaffected; the review
    /// correction's sticky-admission behavior is additive.
    static func presentation(
        isVerified: Bool,
        hasEnteredForm: Bool = false
    ) -> RequestFoodEntryPresentation {
        (isVerified || hasEnteredForm) ? .form : .verification
    }

    /// The latch itself, pulled out as pure logic so the exact rule the
    /// `onChange` above applies is independently testable: sticky once
    /// `isVerified` is ever seen true, and otherwise unchanged — a later
    /// `false` (mid-form authority loss) does not clear an existing `true`.
    static func nextHasEnteredForm(
        previousHasEnteredForm: Bool,
        isVerified: Bool
    ) -> Bool {
        previousHasEnteredForm || isVerified
    }

    /// The exact predicate `onAppear` applies (rereview correction): entry
    /// owns starting `.firstVerification` only before this session has ever
    /// admitted the form. Once admitted, a later appearance — e.g. returning
    /// from backgrounding after a mid-form authority loss — must leave
    /// verification ownership to `RequestFoodView`'s own coordinator-owned
    /// recovery. Calling `beginVerificationIfNeeded()` here after admission
    /// would open a hidden `.firstVerification` flow that
    /// `ParticipantIdentityStore.beginVerification(for:)` — the entry point
    /// `RequestFoodView`'s recovery actually needs — then refuses to
    /// replace, silently blocking that recovery from ever starting.
    static func shouldBeginEntryVerificationOnAppear(hasEnteredForm: Bool) -> Bool {
        !hasEnteredForm
    }

}
