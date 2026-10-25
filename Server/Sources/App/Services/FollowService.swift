import Fluent
import Vapor
import ExpatEventsAPI

/// Shared by `ProfileWebController` and (future, M11) any `/api/v1/profile`
/// surface -- same "one service, both surfaces" shape as `EventService`/
/// `GroupService` (architecture doc, M7).
struct FollowService {
    let db: Database

    // MARK: - Mutations

    /// M7 acceptance criterion #1: creates exactly one `Follow` row.
    /// Already-following is a no-op (idempotent, matching
    /// `EventService.join`'s style for an already-attending user) rather
    /// than an error -- `CreateFollow`'s own unique constraint on
    /// (follower_id, following_id) would otherwise turn a double-click
    /// into a 500. Self-follow is rejected explicitly rather than left to
    /// `CreateFollow`'s DB-level `follow_no_self_follow` CHECK constraint,
    /// so the caller gets a structured `APIError`, not a raw constraint
    /// violation.
    func follow(followerID: UUID, followingID: UUID) async throws {
        guard followerID != followingID else {
            throw APIError(code: "cannot_follow_self", message: "You can't follow yourself.")
        }
        guard try await User.find(followingID, on: db) != nil else {
            throw APIError.notFound
        }
        let alreadyFollowing = try await Follow.query(on: db)
            .filter(\.$follower.$id == followerID)
            .filter(\.$following.$id == followingID)
            .count() > 0
        if alreadyFollowing { return }

        let follow = Follow(followerID: followerID, followingID: followingID)
        try await follow.save(on: db)

        // M7 deliverable "activity-feed generation on join/leave/follow":
        // the person gaining a follower is notified in their own feed,
        // actor = the new follower -- the same "X did something, tell the
        // people who care" shape `EventService.fanOutActivity` already
        // uses for join/leave, just inverted (there the *followers* of the
        // actor are the recipients; here the recipient is the single
        // person just followed, which is simple enough not to need that
        // helper's fan-out-to-many shape).
        let item = ActivityFeedItem(recipientUserID: followingID, actorUserID: followerID, type: .startedFollowing)
        try await item.save(on: db)
    }

    /// M7 acceptance criterion #1 (removal half) + #4: removes exactly one
    /// `Follow` row and nothing else -- past `ActivityFeedItem` rows this
    /// follow relationship already generated are deliberately left alone,
    /// which is what criterion #4 ("doesn't retroactively delete past feed
    /// items") actually requires; there is no code path here that could
    /// touch them. A non-existent follow relationship is a harmless no-op,
    /// matching `GroupService.leave`'s style for a non-member.
    func unfollow(followerID: UUID, followingID: UUID) async throws {
        try await Follow.query(on: db)
            .filter(\.$follower.$id == followerID)
            .filter(\.$following.$id == followingID)
            .delete()
    }

    // MARK: - Reads

    func isFollowing(followerID: UUID, followingID: UUID) async throws -> Bool {
        try await Follow.query(on: db)
            .filter(\.$follower.$id == followerID)
            .filter(\.$following.$id == followingID)
            .count() > 0
    }

    func followerCount(of userID: UUID) async throws -> Int {
        try await Follow.query(on: db).filter(\.$following.$id == userID).count()
    }

    func followingCount(of userID: UUID) async throws -> Int {
        try await Follow.query(on: db).filter(\.$follower.$id == userID).count()
    }

    /// M7 acceptance criterion #2's Followers tab: everyone who follows
    /// `userID`, oldest-first (matches `GroupService.members`'s
    /// joined-oldest-first ordering convention).
    func followerEntries(of userID: UUID) async throws -> [FollowSummaryDTO] {
        let rows = try await Follow.query(on: db)
            .filter(\.$following.$id == userID)
            .with(\.$follower)
            .sort(\.$createdAt, .ascending)
            .all()
        return try rows.map { row in
            FollowSummaryDTO(
                id: try row.requireID(),
                userID: try row.follower.requireID(),
                displayName: row.follower.displayName,
                photoURL: row.follower.photoURL,
                followedAt: row.createdAt ?? Date()
            )
        }
    }

    /// M7 acceptance criterion #2's Following tab: everyone `userID`
    /// follows.
    func followingEntries(of userID: UUID) async throws -> [FollowSummaryDTO] {
        let rows = try await Follow.query(on: db)
            .filter(\.$follower.$id == userID)
            .with(\.$following)
            .sort(\.$createdAt, .ascending)
            .all()
        return try rows.map { row in
            FollowSummaryDTO(
                id: try row.requireID(),
                userID: try row.following.requireID(),
                displayName: row.following.displayName,
                photoURL: row.following.photoURL,
                followedAt: row.createdAt ?? Date()
            )
        }
    }

    // MARK: - DTO conversion

    /// `hostedEvents` reuses `EventService.filteredEvents`'s existing
    /// `hostUserID` filter rather than a second query here -- that method
    /// already excludes private group-hosted events the requester can't
    /// see (M6 criterion #5's own visibility rule), so a profile page
    /// doesn't need to reimplement that check to avoid leaking a private
    /// group event through someone's "hosted events" list.
    func profile(of user: User, requesterID: UUID?) async throws -> ProfileDTO {
        let userID = try user.requireID()
        let followerCount = try await followerCount(of: userID)
        let followingCount = try await followingCount(of: userID)
        var isFollowedByRequester = false
        if let requesterID {
            isFollowedByRequester = try await isFollowing(followerID: requesterID, followingID: userID)
        }

        let eventService = EventService(db: db)
        let hostedEvents = try await eventService.filteredEvents(
            EventFilterQuery(hostUserID: userID),
            requesterID: requesterID
        )
        var summaries: [EventSummaryDTO] = []
        for event in hostedEvents {
            summaries.append(try await eventService.summaryDTO(for: event, requesterID: requesterID))
        }

        return ProfileDTO(
            id: userID,
            displayName: user.displayName,
            photoURL: user.photoURL,
            followerCount: followerCount,
            followingCount: followingCount,
            isFollowedByRequester: isFollowedByRequester,
            hostedEvents: summaries
        )
    }
}
