import Foundation

/// The authenticated user's own view of themselves (`GET /api/v1/me`).
public struct UserDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let email: String
    public let photoURL: String?
    public let role: UserRole
    public let plan: PlanTier
    public let createdAt: Date

    public init(
        id: UUID,
        displayName: String,
        email: String,
        photoURL: String?,
        role: UserRole,
        plan: PlanTier,
        createdAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.photoURL = photoURL
        self.role = role
        self.plan = plan
        self.createdAt = createdAt
    }
}

/// A public-safe view of another user, exposed via `/api/v1/profile/:id`.
/// Deliberately omits `email` and any account/billing fields.
public struct ProfileDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let photoURL: String?
    public let followerCount: Int
    public let followingCount: Int
    public let isFollowedByRequester: Bool
    public let hostedEvents: [EventSummaryDTO]

    public init(
        id: UUID,
        displayName: String,
        photoURL: String?,
        followerCount: Int,
        followingCount: Int,
        isFollowedByRequester: Bool,
        hostedEvents: [EventSummaryDTO]
    ) {
        self.id = id
        self.displayName = displayName
        self.photoURL = photoURL
        self.followerCount = followerCount
        self.followingCount = followingCount
        self.isFollowedByRequester = isFollowedByRequester
        self.hostedEvents = hostedEvents
    }
}
