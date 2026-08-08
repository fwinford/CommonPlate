//
//  AlertSignupView.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
// The email half of "Notify me". This screen is email-only on purpose: it
// shows no channel picker, no disabled control, and no "coming soon" row,
// because a control that cannot be used is not information. The Home entry
// above it stays broad, so another channel can be added behind it later
// without moving or renaming anything the person already knows.
import SwiftUI

struct AlertSignupView: View {
    // MARK: - Copy

    static let title = "Get email alerts"
    static let explanation =
        "Enter your NYU email to receive alerts when new meal requests are posted. You’ll need to confirm your email before alerts begin."
    static let fieldLabel = "NYU email address"
    static let continueButtonTitle = "Continue"
    static let submittingLabel = "Sending…"

    /// The accepted-state copy. Every sentence here is true of all four
    /// subscriber states the identical 202 covers — new, pending, confirmed,
    /// and unsubscribed — because the response cannot distinguish them and the
    /// app must not pretend otherwise. Nothing here claims that a subscription
    /// exists, that alerts are on, or that an email was sent.
    static let checkEmailTitle = "Check your email"
    static let checkEmailBody =
        "Check your NYU email for a message from CommonPlate. Follow the confirmation step if one is needed. If you already confirmed this address, there may be nothing else to do."
    static let useDifferentEmailTitle = "Use a different email"
    static let doneTitle = "Done"

    static func message(for failure: AlertSignupFailure) -> String {
        switch failure {
        case .paused:
            // Deliberately says nothing about the address: it was never the
            // problem, and blaming it would send someone off to retype a
            // perfectly good email.
            return "Email alerts aren’t open for signup right now. Try again later."
        case .rateLimited:
            return "Too many attempts from this device. Wait a minute, then try again."
        case .confirmationEmailUnavailable:
            return "We couldn’t start the confirmation email just now, so your signup didn’t go through. Try again in a moment."
        case .ambiguousOutcome:
            return "We couldn’t confirm whether your signup was received. Check your email before trying again."
        case .unknown:
            return "Something went wrong. Try again in a moment."
        }
    }

    /// Continue stays available for any non-empty entry so a rejected address
    /// can say why beside its own field. Local validation still decides whether
    /// anything is actually sent, so an unusable address never becomes a
    /// request.
    static func isSubmissionEnabled(email: String, phase: AlertSignupPhase) -> Bool {
        phase == .editing && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - View

    @ObservedObject var store: AlertSubscriptionStore
    /// Push keeps its own state owner and its own small section below the
    /// email form (Week 3 Day 6 Slice 6A.2). It shares no state with `store`:
    /// email and push are independent controls.
    @ObservedObject var pushStore: PushSubscriptionStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isEmailFocused: Bool

    /// The field reads and writes the store's address. Keeping a second copy in
    /// `@State` would let the screen and its one state owner disagree about
    /// what is being submitted.
    private var emailBinding: Binding<String> {
        Binding(
            get: { store.email },
            set: { store.updateEmail($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.phase == .checkEmail {
                acceptedState
            } else {
                form
            }

            Divider()

            PushNotificationSection(store: pushStore)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .navigationTitle(Self.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Self.title)
                .font(.title2)
                .fontWeight(.semibold)

            Text(Self.explanation)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(Self.fieldLabel)
                    .font(.subheadline)
                    .fontWeight(.medium)

                TextField("name@nyu.edu", text: emailBinding)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(store.isSubmitting)
                    .focused($isEmailFocused)

                if store.fieldError == .invalidNYUEmail {
                    Text(AlertSignupEmailValidator.invalidEmailMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if let failure = store.failure {
                Text(Self.message(for: failure))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            Button {
                isEmailFocused = false
                Task { await store.submit(email: store.email) }
            } label: {
                if store.isSubmitting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(Self.submittingLabel)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text(Self.continueButtonTitle)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!Self.isSubmissionEnabled(email: store.email, phase: store.phase))
        }
    }

    private var acceptedState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Self.checkEmailTitle)
                .font(.title2)
                .fontWeight(.semibold)

            Text(Self.checkEmailBody)
                .foregroundStyle(.secondary)

            Button(Self.useDifferentEmailTitle) {
                store.useDifferentEmail()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)

            Button(Self.doneTitle) {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
    }
}
