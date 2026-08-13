//
//  ParticipantVerificationView.swift
//  CommonPlateios
//
// The one screen that establishes participant identity (W3-I1). It owns the
// address and code the student is typing and nothing else: the flow itself,
// the credential, and every decision about what is verified belong to
// `ParticipantIdentityStore`, and the backend remains authoritative over both.
import SwiftUI

struct ParticipantVerificationView: View {
    @ObservedObject var store: ParticipantIdentityStore
    private let cancel: () -> Void

    init(
        store: ParticipantIdentityStore,
        cancel: (() -> Void)? = nil
    ) {
        self.store = store
        self.cancel = cancel ?? store.cancelVerification
    }

    /// Local input only. Deliberately not seeded from a remembered identity,
    /// even during Change Email: prefilling the address being replaced would
    /// invite verifying the one already held.
    @State private var email = ""
    @State private var code = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case email
        case code
    }

    static let title = "Verify your NYU email"
    static let replacementTitle = "Change your NYU email"

    /// Says what verification is for, and what it is not. "Not a login" is
    /// load-bearing copy: there is no account, no password, and no cross-device
    /// recovery, and a student who believes otherwise will expect this to
    /// follow them to another phone.
    static let purposeNotice =
        "We email a code to confirm you can read mail at this NYU address. It isn’t a login, and it stays on this device."

    static let replacementNotice =
        "Your current email keeps working until the new one is verified. Requests and reservations you already made stay with the email that made them."

    /// Shown when a stored identity was refused by the backend.
    static let revokedNotice =
        "We couldn’t use your saved verification, so we need to verify this device again."

    static let newInstallNotice =
        "A new device or a reinstall needs to verify again."

    static func codeSentNotice(email: String) -> String {
        "Enter the 6-digit code we sent to \(email)."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xl) {
                    verificationBrandHeader

                    switch store.flow?.stage {
                    case .enteringEmail, .none:
                        emailSection
                    case .awaitingCode(let address, _, _):
                        codeSection(address: address)
                    }

                    if let error = store.verificationError {
                        CommonPlateInlineStatus(kind: .error, message: error.message)
                            .accessibilityIdentifier("participant-verification-error")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, CommonPlateStyle.Spacing.l)
                .padding(.vertical, CommonPlateStyle.Spacing.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(CommonPlateStyle.Color.baseCanvas.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: cancel) {
                        Image(systemName: "xmark")
                            // The fixed circle owns the symbol geometry, so
                            // Dynamic Type cannot enlarge this quiet dismissal
                            // control while nearby text remains accessible.
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .background(CommonPlateStyle.Color.warmSurface, in: Circle())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CommonPlateWarmGhostDismissButtonStyle())
                    .accessibilityLabel("Close email verification")
                    .accessibilityIdentifier("participant-verification-cancel")
                }
            }
        }
    }

    /// Verification is an approved, rare trust/entry moment for CommonPlate
    /// character. The brand/display type remains here; fields, controls, and
    /// explanatory copy below deliberately remain system typography.
    private var verificationBrandHeader: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.xs) {
            Text("CommonPlate at NYU")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.accentColor)

            Text(
                store.flow?.purpose == .emailReplacement
                    ? Self.replacementTitle
                    : Self.title
            )
            .font(.commonPlateBrandDisplay(.title2))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("participant-verification-brand-header")
    }

    @ViewBuilder
    private var emailSection: some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
            // Primary action first (W3-I3): the field and Send code are what
            // this screen is for, so they lead. Everything below is
            // supporting explanation, visually secondary, and never gates or
            // delays these two controls.
            TextField("NYU email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .email)
                .accessibilityIdentifier("participant-verification-email")

            Button {
                let address = email
                Task { await store.requestCode(for: address) }
            } label: {
                if store.isRequestingCode {
                    HStack {
                        Spacer()
                        ProgressView()
                        Text("Sending…")
                        Spacer()
                    }
                } else {
                    Text("Send code")
                        .frame(maxWidth: .infinity)
                }
            }
            // Bordered-prominent + large control (W3-I3 physical-device
            // correction), now the shared primary-action convention (W4-F1):
            // the plain in-row button style this shared with every other row
            // read as one more line of text, not the screen's actual primary
            // action. Full-width for the same reason "Send code" needed a
            // stronger visual claim than its own label width gave it.
            .commonPlatePrimaryAction()
            .disabled(!Self.canSendCode(email: email, isRequesting: store.isRequestingCode))
            .accessibilityIdentifier("participant-verification-send")

            Text(Self.codeLifetimeNotice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("participant-verification-code-lifetime")

            Divider()

            Text(NYUEmailPolicy.requiredMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("participant-verification-eligibility")

            Text(Self.purposeNotice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.flow?.purpose == .emailReplacement {
                Text(Self.replacementNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("participant-replacement-notice")
            } else if store.wasIdentityRevoked {
                Text(Self.revokedNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("participant-revoked-notice")
            }
        }
    }

    private func codeSection(address: String) -> some View {
        VStack(alignment: .leading, spacing: CommonPlateStyle.Spacing.m) {
            Text(Self.codeSentNotice(email: address))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("participant-code-sent-notice")

            TextField("6-digit code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .code)
                .accessibilityIdentifier("participant-verification-code")

            Button {
                let submitted = code
                Task {
                    let verified = await store.submitCode(submitted)
                    if verified { code = "" }
                }
            } label: {
                if store.isSubmittingCode {
                    HStack {
                        Spacer()
                        ProgressView()
                        Text("Verifying…")
                        Spacer()
                    }
                } else {
                    Text("Verify")
                        .frame(maxWidth: .infinity)
                }
            }
            // Same shared primary-action convention (W4-F1) as Send code
            // above, for the same reason: this is the code-entry state's one
            // primary action, and the plain in-row style did not read as one.
            .commonPlatePrimaryAction()
            .disabled(
                !Self.canSubmitCode(
                    code: code,
                    isSubmitting: store.isSubmittingCode,
                    isRequesting: store.isRequestingCode
                )
            )
            .accessibilityIdentifier("participant-verification-submit")

            Button("Send a new code") {
                Task { await store.resendCode() }
            }
            .disabled(store.isRequestingCode || store.isSubmittingCode)
            .accessibilityIdentifier("participant-verification-resend")
        }
    }

    static let codeLifetimeNotice = "Your code expires in 10 minutes."

    /// Local completeness and eligibility only. The backend applies the
    /// identical allowlist and remains authoritative; this exists so an
    /// obviously ineligible address does not spend a request — and a mailing.
    static func canSendCode(email: String, isRequesting: Bool) -> Bool {
        !isRequesting && NYUEmailPolicy.isAllowed(email)
    }

    /// Shape only. Whether the code is *correct* is not something this app may
    /// decide, and a locally "valid-looking" code still proves nothing.
    static func canSubmitCode(
        code: String,
        isSubmitting: Bool,
        isRequesting: Bool
    ) -> Bool {
        guard !isSubmitting, !isRequesting else { return false }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count == 6 && trimmed.allSatisfy(\.isNumber)
    }
}

private struct CommonPlateWarmGhostDismissButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
