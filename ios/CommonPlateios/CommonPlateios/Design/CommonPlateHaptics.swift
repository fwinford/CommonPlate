//
//  CommonPlateHaptics.swift
//  CommonPlateios
//
// W4-M1's "selective, semantic haptics" direction, given exactly two call
// sites (W4-R2): one success haptic at authoritative request creation, one
// error haptic at an authoritative definitive non-create. Nothing else in
// the requester journey — including any screenshot proposal state, D1
// checking/ambiguity, or ordinary local validation — may trigger either.
import UIKit

@MainActor
enum CommonPlateHaptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
