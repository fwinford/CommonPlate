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
            Form {
                switch store.flow?.stage {
                case .enteringEmail, .none:
                    emailSection
                case .awaitingCode(let address, _, _):
                    codeSection(address: address)
                }

                if let error = store.verificationError {
                    Section {
                        Text(error.message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("participant-verification-error")
                    }
                }
            }
            .navigationTitle(
                store.flow?.purpose == .emailReplacement
                    ? Self.replacementTitle
                    : Self.title
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancel()
                    }
                    .accessibilityIdentifier("participant-verification-cancel")
                }
            }
        }
    }

    private var emailSection: some View {
        Section {
            TextField("NYU email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .email)
                .accessibilityIdentifier("participant-verification-email")

            Text(NYUEmailPolicy.requiredMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("participant-verification-eligibility")

            Text(Self.purposeNotice)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.flow?.purpose == .emailReplacement {
                Text(Self.replacementNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("participant-replacement-notice")
            } else if store.wasIdentityRevoked {
                Text(Self.revokedNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("participant-revoked-notice")
            }

            Button {
                let address = email
                Task { await store.requestCode(for: address) }
            } label: {
                if store.isRequestingCode {
                    HStack {
                        ProgressView()
                        Text("Sending…")
                    }
                } else {
                    Text("Send code")
                }
            }
            .disabled(!Self.canSendCode(email: email, isRequesting: store.isRequestingCode))
            .accessibilityIdentifier("participant-verification-send")
        }
    }

    private func codeSection(address: String) -> some View {
        Section {
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
                        ProgressView()
                        Text("Verifying…")
                    }
                } else {
                    Text("Verify")
                }
            }
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
