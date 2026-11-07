import Foundation

/// How a member sees distances (Search & filters PR): kilometres by
/// default, or miles, chosen on `/account`. Visitors get kilometres.
enum DistanceUnit: String, CaseIterable, Codable, Sendable {
    case km
    case mi

    /// Kilometres in one of this unit.
    var kilometres: Double {
        switch self {
        case .km: 1
        case .mi: 1.609344
        }
    }

    /// The "Within" choices on `/events`, in this unit.
    var radiusOptions: [Double] {
        switch self {
        case .km: [10, 25, 50, 100]
        case .mi: [5, 15, 30, 60]
        }
    }

    var defaultRadius: Double {
        switch self {
        case .km: 25
        case .mi: 15
        }
    }

    var shortLabel: String {
        switch self {
        case .km: "km"
        case .mi: "mi"
        }
    }

    var label: String {
        switch self {
        case .km: "Kilometres"
        case .mi: "Miles"
        }
    }
}
