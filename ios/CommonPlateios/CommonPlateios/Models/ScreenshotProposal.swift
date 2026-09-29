//
//  ScreenshotProposal.swift
//  CommonPlateios
//
// W4-S1 non-authoritative proposal domain shape. Distinct from
// `CreateRequestPayload`: this can never reach `RequestStore.createRequest`
// directly, only `RequestFoodFormDraft` via `ScreenshotProposalStore`'s
// manual-precedence application.
import Foundation

/// The allowlisted proposal fields: location, literal food, meal swipes.
/// Every field is independently optional — partial and empty proposals are
/// both ordinary outcomes, never a failure.
///
/// W4-R4 proposals use the same `MealItem` shape as manual entry.  A current
/// cart's order-level amount may also be proposed as an estimate, but never
/// selects the requester-owned menu path or submits anything.
struct ScreenshotProposal: Equatable {
    var selectedDiningSpot: DiningSpot?
    var mealItems: [MealItem]?
    var mealSwipes: Int?
    var estimatedDiningDollarsCents: Int?

    static let empty = ScreenshotProposal()
}

/// One completed analysis attempt. `eligible` distinguishes an unsupported
/// screenshot category from a supported one that simply yielded nothing
/// safe to propose, so presentation can explain the two differently without
/// either one ever becoming a hard failure.
struct ScreenshotProposalOutcome: Equatable {
    let eligible: Bool
    let proposal: ScreenshotProposal

    var isEmpty: Bool {
        proposal.selectedDiningSpot == nil
            && (proposal.mealItems?.isEmpty ?? true)
            && proposal.mealSwipes == nil
            && proposal.estimatedDiningDollarsCents == nil
    }
}
