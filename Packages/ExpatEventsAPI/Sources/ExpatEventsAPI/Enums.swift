import Foundation

// MARK: - Shared enums (§5 of the architecture doc)
//
// These are the wire-format enums, shared verbatim between the Vapor server
// and any native client. Keep raw values stable — they round-trip through
// JSON and (server-side) through Fluent's `@Enum` field type.

public enum EventCategory: String, Codable, CaseIterable, Sendable {
    case culture
    case drinks
    case film
    case food
    case music
    case travel
}

public enum EventVisibility: String, Codable, CaseIterable, Sendable {
    case `public`
    case `private`
}

public enum PlanTier: String, Codable, CaseIterable, Sendable {
    case free
    case premium
}

public enum BillingCycle: String, Codable, CaseIterable, Sendable {
    case monthly
    case yearly
}

public enum SubscriptionStatus: String, Codable, CaseIterable, Sendable {
    case active
    case pastDue
    case canceled
}

public enum GroupVisibility: String, Codable, CaseIterable, Sendable {
    case `public`
    case inviteOnly
}

public enum GroupRole: String, Codable, CaseIterable, Sendable {
    case owner
    case moderator
    case member
}

public enum UserRole: String, Codable, CaseIterable, Sendable {
    case member
    case admin
}

public enum IdentityProvider: String, Codable, CaseIterable, Sendable {
    case apple
    case google
}

public enum ActivityFeedItemType: String, Codable, CaseIterable, Sendable {
    case joinedEvent
    case leftEvent
    case startedFollowing
    case groupPostedEvent
}

public enum InvoiceStatus: String, Codable, CaseIterable, Sendable {
    case paid
    case open
    case uncollectible
    case void
}

public enum DataExportStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case ready
    case expired
}
