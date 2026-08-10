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
    /// Observed, not owned: the same identity every other participant action
    /// reads, so a verification completed here is immediately visible to the
    /// form this screen reveals.
    @ObservedObject var identityStore: ParticipantIdentityStore
    @ObservedObject var verificationCoordinator: ParticipantActionVerificationCoordinator
    @Binding var path: [AppRoute]

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
                Color.clear
            case .form:
                RequestFoodView(
                    store: store,
                    identityStore: identityStore,
                    verificationCoordinator: verificationCoordinator,
                    path: $path
                )
            }
        }
        .navigationTitle("Request Food")
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
        .sheet(isPresented: isPresentingEntryVerification) {
            ParticipantVerificationView(
                store: identityStore,
                cancel: cancelEntryVerification
            )
        }
    }

    /// Open exactly while this gate has not yet been satisfied and never has
    /// been — once `hasEnteredForm` is set, a later authority loss is
    /// `RequestFoodView`'s own in-form sheet to reopen, not this entry gate's.
    /// A swipe-to-dismiss sets this to `false` through the binding, which
    /// retires the flow the same way the explicit Cancel button does; either
    /// path leaves nothing presenting an unverified installation's form
    /// underneath.
    private var isPresentingEntryVerification: Binding<Bool> {
        Binding(
            get: { !identityStore.isVerified && !hasEnteredForm },
            set: { isPresented in
                guard !isPresented else { return }
                entryVerificationSheetDismissed()
            }
        )
    }

    /// The physical-device fix: SwiftUI also invokes this binding's `set`
    /// with `false` when the *get* itself is what flipped the sheet closed —
    /// exactly what happens the instant verification succeeds, since
    /// `identityStore.isVerified` becoming `true` makes `get` return `false`
    /// on its own, with no user swipe or Cancel tap involved. Treating every
    /// `set(false)` as a real cancellation — the previous behavior — popped
    /// `.requestFood` off the path on that success dismissal too, which is
    /// the exact physical-device symptom: verification genuinely succeeded
    /// and persisted, but the requester was bounced out of Request Food and
    /// had to re-enter to see the now-verified direct path. Only a dismissal
    /// that happens *without* a completed verification is a real
    /// cancellation to act on — the identical guard `RequestFoodView`'s own
    /// analogous `requesterSheetDismissed()` already applies to this same
    /// SwiftUI race.
    private func entryVerificationSheetDismissed() {
        guard Self.shouldTreatSheetDismissalAsCancellation(
            isVerified: identityStore.isVerified,
            hasEnteredForm: hasEnteredForm
        ) else { return }
        cancelEntryVerification()
    }

    /// Abandoning verification here has no filled draft to protect — unlike
    /// the in-form sheet, nothing has been shown yet — so Cancel also leaves
    /// Request Food rather than reopening the same empty gate.
    private func cancelEntryVerification() {
        identityStore.cancelVerification()
        path = Self.pathAfterCancellingEntry(path)
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

    /// The exact predicate the sheet's `set` closure applies (physical-device
    /// correction): SwiftUI calls that closure with `false` both for a real
    /// user cancellation/swipe-to-dismiss *and* for the dismissal SwiftUI
    /// itself performs the instant `get` flips to `false` on its own —
    /// which is exactly what happens when verification succeeds, since
    /// `identityStore.isVerified` becoming `true` makes `get` return `false`
    /// with no user action at all. Only the former is a real cancellation:
    /// a dismissal that coincides with — or follows — successful admission
    /// must not pop `.requestFood` off the path.
    static func shouldTreatSheetDismissalAsCancellation(
        isVerified: Bool,
        hasEnteredForm: Bool
    ) -> Bool {
        !isVerified && !hasEnteredForm
    }

    static func pathAfterCancellingEntry(_ path: [AppRoute]) -> [AppRoute] {
        guard path.last == .requestFood else { return path }
        return Array(path.dropLast())
    }
}
