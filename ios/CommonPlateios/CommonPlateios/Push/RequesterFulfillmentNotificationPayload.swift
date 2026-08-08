//
//  RequesterFulfillmentNotificationPayload.swift
//  CommonPlateios
//
// Parses the requester-fulfillment push payload
// (`src/requesterFulfillmentPushPayload.ts`, Week 3 Day 6 Slice 6E) out of a
// delivered notification's `userInfo`. Pure and side-effect free, matching
// `HelperNotificationPayload.swift` — a tap always opens Home regardless of
// `requestId`, so nothing here needs to carry or validate one.
import Foundation

enum RequesterFulfillmentNotificationPayloadParser {
    /// Must match `REQUESTER_FULFILLMENT_NOTIFICATION_TYPE` in
    /// `src/requesterFulfillmentPushPayload.ts` exactly.
    static let requesterFulfillmentType = "requester-order-placed"

    /// Whether `userInfo` is a well-formed requester-fulfillment payload. An
    /// unrelated or missing `type` is not one, so an unrelated or malformed
    /// notification never routes as one.
    static func isRequesterFulfillmentPayload(userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["type"] as? String) == requesterFulfillmentType
    }
}
