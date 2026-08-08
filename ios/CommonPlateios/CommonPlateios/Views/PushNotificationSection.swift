//
//  PushNotificationSection.swift
//  CommonPlateios
//
// The smallest push-notification control, shown alongside the existing email
// signup form (Week 3 Day 6 Slice 6A.2). It does not restyle, reorder, or
// otherwise touch the email section around it — the two controls are
// independent and this section owns none of `AlertSubscriptionStore`'s state.
//
// Whether and how this eventually shares one restored layout with email is a
// Slice 6B decision, not this one; this section is deliberately minimal.
import SwiftUI

struct PushNotificationSection: View {
    // MARK: - Copy

    static let offTitle = "Push notifications: Off"
    static let onTitle = "Push notifications: On"
    static let settingUpTitle = "Setting up push notifications…"
    static let deniedTitle = "Notifications are off"
    static let failedTitle = "Push alerts couldn’t be turned on"

    static let turnOnButtonTitle = "Turn on push notifications"
    static let turnOffButtonTitle = "Turn off"
    static let openSettingsButtonTitle = "Open Settings"
    static let tryAgainButtonTitle = "Try again"
    static let enableButtonTitle = "Enable notifications"
    static let notNowButtonTitle = "Not now"

    static let explanationTitle = "Turn on push notifications"
    static let explanationBody =
        "CommonPlate can send you alerts about new food requests. Apple will ask for permission next. You can change this later in iPhone Settings."

    static let couldNotDisableMessage =
        "We couldn’t turn off push notifications just now. Push is still on."

    // MARK: - View

    @ObservedObject var store: PushSubscriptionStore
    @State private var isShowingExplanation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch store.state {
            case .off:
                offState
            case .settingUp:
                settingUpState
            case .on:
                onState
            case .denied:
                deniedState
            case .failed:
                failedState
            }
        }
        .task {
            await store.refreshAuthorizationStatus()
        }
    }

    private var offState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.offTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if isShowingExplanation {
                explanation
            } else {
                Button(Self.turnOnButtonTitle) {
                    isShowingExplanation = true
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.explanationTitle)
                .font(.subheadline)
                .fontWeight(.medium)
            Text(Self.explanationBody)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button(Self.enableButtonTitle) {
                    isShowingExplanation = false
                    Task { await store.enableAfterExplanation() }
                }
                .buttonStyle(.borderedProminent)

                Button(Self.notNowButtonTitle) {
                    isShowingExplanation = false
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var settingUpState: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(Self.settingUpTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var onState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.onTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if store.failure == .couldNotDisable {
                Text(Self.couldNotDisableMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button(Self.turnOffButtonTitle) {
                Task { await store.disable() }
            }
            .buttonStyle(.bordered)
        }
    }

    private var deniedState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.deniedTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(Self.openSettingsButtonTitle) {
                store.openSystemSettings()
            }
            .buttonStyle(.bordered)
        }
    }

    private var failedState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.failedTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(Self.tryAgainButtonTitle) {
                Task { await store.enableAfterExplanation() }
            }
            .buttonStyle(.bordered)
        }
    }
}
