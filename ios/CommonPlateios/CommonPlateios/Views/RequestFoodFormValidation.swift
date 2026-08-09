//
//  RequestFoodFormValidation.swift
//  CommonPlateios
//

import Foundation

/// The requester form's editable values. This stays specific to
/// `RequestFoodView`; it is not shared with fulfillment or persisted outside
/// the screen.
struct RequestFoodFormDraft: Equatable {
    var selectedDiningSpot: DiningSpot?
    var foodRequest: String
    var pickupName: String
    var timing: RequestTiming
    var preferredPickupTime: Date

    init(
        selectedDiningSpot: DiningSpot? = nil,
        foodRequest: String = "",
        pickupName: String = "",
        timing: RequestTiming = .asap,
        preferredPickupTime: Date = Date()
    ) {
        self.selectedDiningSpot = selectedDiningSpot
        self.foodRequest = foodRequest
        self.pickupName = pickupName
        self.timing = timing
        self.preferredPickupTime = preferredPickupTime
    }
}

/// Request-form fields in screen order. Only text fields can receive focus;
/// pickers still participate in submit-time validation and live correction
/// after their error has been presented.
///
/// The requester's email is deliberately absent (W3-I1): it is no longer a
/// field, because the requester is the verified participant this installation
/// remembers and the backend binds the request to that principal.
enum RequestFoodFormField: Hashable, CaseIterable {
    case diningSpot
    case foodDescription
    case pickupName
    case pickupSchedule

    var isTextField: Bool {
        switch self {
        case .foodDescription, .pickupName:
            return true
        case .diningSpot, .pickupSchedule:
            return false
        }
    }
}

struct RequestFoodFieldError: Equatable, Identifiable {
    let field: RequestFoodFormField
    let error: RequestFoodFormError

    var id: RequestFoodFormField { field }
    var message: String { error.message }
}

/// Locally knowable request-form rules. The backend remains authoritative;
/// this validator exists only to keep obvious failures beside their fields and
/// prevent them from reaching the store.
enum RequestFoodFormValidator {
    /// Completeness for button presentation only. The timing picker is
    /// non-optional and a Later selection always carries a Date, so both of its
    /// representable states are complete. Whether that Date still fits today is
    /// validation, not completeness, and is intentionally checked on Submit.
    static func hasRequiredInput(_ draft: RequestFoodFormDraft) -> Bool {
        guard let diningSpot = draft.selectedDiningSpot,
              !diningSpot.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.foodRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.pickupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        switch draft.timing {
        case .asap, .later:
            return true
        }
    }

    /// `isScheduledWindowValid` answers whether *this* chosen start still fits;
    /// `isScheduledTimingAvailable` answers whether any start does. Both are
    /// derived from the same time snapshot by the caller, and the pair is what
    /// separates a start the requester can correct from scheduling having closed
    /// underneath them — two failures that need different instructions, because
    /// only one of them still has a control to act on.
    static func validate(
        selectedDiningSpot: DiningSpot?,
        foodRequest: String,
        pickupName: String,
        timing: RequestTiming,
        isScheduledWindowValid: Bool,
        isScheduledTimingAvailable: Bool
    ) -> [RequestFoodFieldError] {
        var errors: [RequestFoodFieldError] = []

        if selectedDiningSpot?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            errors.append(RequestFoodFieldError(field: .diningSpot, error: .missingDiningSpot))
        }
        if foodRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(RequestFoodFieldError(field: .foodDescription, error: .missingFood))
        }
        if pickupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(RequestFoodFieldError(field: .pickupName, error: .missingPickupName))
        }
        if timing == .later && !isScheduledWindowValid {
            // Telling someone to choose a different pickup time is only useful
            // while there is a time left to choose. Once the last full window
            // has passed, the picker is gone and the only move left is ASAP —
            // so that is what this says, rather than pointing at a control the
            // form has already withdrawn.
            errors.append(RequestFoodFieldError(
                field: .pickupSchedule,
                error: isScheduledTimingAvailable
                    ? .invalidScheduledTime
                    : .scheduledTimingUnavailable
            ))
        }

        return errors
    }
}

/// View-local presentation history. A field joins this set only after its own
/// error has actually been shown, so another field's failure cannot make an
/// untouched field validate during its first keystrokes.
struct RequestFoodValidationPresentation: Equatable {
    private(set) var presentedFields: Set<RequestFoodFormField> = []

    mutating func presentInvalidField(
        _ field: RequestFoodFormField,
        from errors: [RequestFoodFieldError]
    ) {
        guard errors.contains(where: { $0.field == field }) else { return }
        presentedFields.insert(field)
    }

    mutating func presentAll(_ errors: [RequestFoodFieldError]) {
        presentedFields.formUnion(errors.map(\.field))
    }

    /// The exact focus transition used by `RequestFoodView`. Only the invalid
    /// text field that actually lost focus is presented; programmatic changes
    /// with no previous field and sibling failures have no effect.
    mutating func handleFocusTransition(
        from previousField: RequestFoodFormField?,
        to currentField: RequestFoodFormField?,
        errors: [RequestFoodFieldError]
    ) {
        guard previousField != currentField,
              let previousField,
              previousField.isTextField else {
            return
        }
        presentInvalidField(previousField, from: errors)
    }

    func visibleErrors(from errors: [RequestFoodFieldError]) -> [RequestFoodFieldError] {
        errors.filter { presentedFields.contains($0.field) }
    }

    func visibleError(
        for field: RequestFoodFormField,
        from errors: [RequestFoodFieldError]
    ) -> RequestFoodFieldError? {
        visibleErrors(from: errors).first { $0.field == field }
    }
}

struct RequestFoodSubmissionResult: Equatable {
    let presentation: RequestFoodValidationPresentation
    let firstInvalidTextField: RequestFoodFormField?
    let didSubmit: Bool
}
