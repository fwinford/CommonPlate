//
//  CommonPlateModels.swift
//  CommonPlateios
//
//  Created by faith on 7/9/26.
//
import Foundation

struct DiningSpot: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let address: String
}

enum RequestTiming: String, CaseIterable, Identifiable {
    case asap = "ASAP"
    case later = "Later"

    var id: String { rawValue }
}

enum FoodRequestStatus: String {
    case open = "Open"
    case placed = "Placed"
}

struct FulfillmentDetails {
    let helperEmail: String
    let helperPhoneNumber: String
    let orderConfirmation: String
    let pickupTimeOrETA: String
    let noteToRequester: String
    let submittedAt = Date()
}

struct FoodRequest: Identifiable {
    let id = UUID()
    let diningSpot: DiningSpot
    let foodDescription: String
    let pickupName: String
    let email: String
    let phoneNumber: String
    let timing: RequestTiming
    let preferredPickupTime: Date?
    let createdAt = Date()
    var status: FoodRequestStatus = .open
    var fulfillmentDetails: FulfillmentDetails?

    var expiresAt: Date {
        switch timing {
        case .asap:
            return createdAt.addingTimeInterval(5 * 60 * 60)

        case .later:
            if let preferredPickupTime {
                return preferredPickupTime.addingTimeInterval(5 * 60 * 60)
            } else {
                return createdAt.addingTimeInterval(5 * 60 * 60)
            }
        }
    }

    var isExpired: Bool {
        Date() >= expiresAt
    }

    var isActive: Bool {
        status == .open && !isExpired
    }

    var shouldShowInASAPSection: Bool {
        switch timing {
        case .asap:
            return true

        case .later:
            guard let preferredPickupTime else {
                return false
            }

            let oneHourFromNow = Date().addingTimeInterval(60 * 60)
            return preferredPickupTime <= oneHourFromNow
        }
    }

    var timingDescription: String {
        switch timing {
        case .asap:
            return "ASAP"

        case .later:
            if let preferredPickupTime {
                return "Around \(preferredPickupTime.formatted(date: .omitted, time: .shortened))"
            } else {
                return "Later today"
            }
        }
    }

    var listTimingDescription: String {
        if shouldShowInASAPSection && timing == .later, let preferredPickupTime {
            return "Due around \(preferredPickupTime.formatted(date: .omitted, time: .shortened))"
        }

        return timingDescription
    }
}
