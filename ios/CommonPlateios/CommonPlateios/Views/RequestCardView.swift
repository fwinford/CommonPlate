//
//  RequestCardView.swift
//  CommonPlateios
//
// The one live-exchange request card (W4-H2), used by Home for every board
// row and the Continue Helping priority item. Visual target: the approved
// H2 Figma `Request / Card` component (states Open / Your Request /
// Helping). Membership, order, and every displayed value are backend-owned;
// this view only arranges them.
import SwiftUI

/// Which H2 board treatment a card renders. `.own` and `.helping` are
/// mutually exclusive by construction — the backend's self-claim guard makes
/// it impossible for the same request to be both the caller's own request
/// and an active reservation the caller holds.
enum RequestCardKind: Equatable {
    case open
    /// W4-H2 authoritative ownership truth (`FoodRequest.isOwnRequest`).
    case own
    /// An active helper reservation, showing the authoritative remaining
    /// time until `claimExpiresAt`.
    case helping(claimExpiresAt: Date)
}

struct RequestCardView: View {
    let request: FoodRequest
    let kind: RequestCardKind

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if kind == .own {
                Text(Self.ownRequestEyebrow)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("request-card-your-request-eyebrow")
            }

            HStack(alignment: .firstTextBaseline) {
                Text(Self.mealSwipesText(request.mealSwipes))
                    .font(.headline)
                Spacer(minLength: CommonPlateStyle.Spacing.s)
                Text(timingText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }

            Text(request.diningSpot.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(request.foodDescription)
                .font(.body)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if case .helping = kind {
                Text(Self.continueLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)
                    .accessibilityIdentifier("request-card-continue-label")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CommonPlateStyle.Spacing.l)
        .background(
            surfaceColor,
            in: RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CommonPlateStyle.Radius.standard, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var surfaceColor: Color {
        switch kind {
        case .open, .own:
            return CommonPlateStyle.Color.requestCardSurface
        case .helping:
            return CommonPlateStyle.Color.helpingCardSurface
        }
    }

    private var borderColor: Color {
        switch kind {
        case .open, .own:
            return CommonPlateStyle.Color.requestCardBorder
        case .helping:
            return CommonPlateStyle.Color.helpingCardBorder
        }
    }

    /// The right-aligned timing badge. `.helping` shows authoritative
    /// remaining time to `claimExpiresAt`; every other card shows the
    /// backend's own canonical `pickupWindowText` (already "ASAP" or a
    /// formatted campus-time window — see `docs/system-contract.md`), never
    /// a locally reformatted value.
    private var timingText: String {
        switch kind {
        case .open, .own:
            return request.pickupWindowText
        case .helping(let claimExpiresAt):
            return Self.remainingTimeText(until: claimExpiresAt)
        }
    }

    static let ownRequestEyebrow = "YOUR REQUEST"
    static let continueLabel = "Continue →"

    static func mealSwipesText(_ count: Int) -> String {
        count == 1 ? "1 meal swipe" : "\(count) meal swipes"
    }

    /// Authoritative deadline, presented as whole minutes remaining — never
    /// a live countdown timer (M1: quiet/immediate, no new gesture or timer
    /// architecture). Floors at "Reserved" rather than a negative/zero
    /// reading, since an actually-expired reservation is reconciled by the
    /// existing accepted reservation lifecycle, not by this label.
    static func remainingTimeText(until claimExpiresAt: Date, now: Date = Date()) -> String {
        let remainingSeconds = claimExpiresAt.timeIntervalSince(now)
        let remainingMinutes = Int(ceil(remainingSeconds / 60))
        guard remainingMinutes > 0 else {
            return "Reserved"
        }
        return remainingMinutes == 1 ? "1 min left" : "\(remainingMinutes) min left"
    }
}
