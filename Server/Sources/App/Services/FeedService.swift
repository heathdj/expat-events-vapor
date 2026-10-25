import Fluent
import Vapor
import ExpatEventsAPI

/// Shared by `FeedWebController` and `FeedAPIController` (architecture
/// doc, M7). The actual feed-item *generation* lives where the triggering
/// action happens -- `EventService.fanOutActivity` (join/leave) and
/// `FollowService.follow` (startedFollowing) -- not here; this service is
/// read-only, the same split `GroupService`'s tab-data methods already
/// use relative to `EventService`'s own mutations.
struct FeedService {
    let db: Database

    /// M7 acceptance criterion #5's underlying data: every
    /// `ActivityFeedItem` recipient-addressed to `userID`, newest first.
    /// No pagination -- matches this MVP's other listings
    /// (`GroupService.members`, `filteredEvents`'s own modest page size)
    /// in not needing one yet at seed-data scale.
    func feed(for userID: UUID) async throws -> [ActivityFeedItemDTO] {
        let items = try await ActivityFeedItem.query(on: db)
            .filter(\.$recipient.$id == userID)
            .with(\.$actor)
            .with(\.$event)
            .sort(\.$createdAt, .descending)
            .all()
        return try items.map { item in
            ActivityFeedItemDTO(
                id: try item.requireID(),
                type: item.type,
                actorUserID: item.$actor.id,
                actorDisplayName: item.actor.displayName,
                actorPhotoURL: item.actor.photoURL,
                eventID: item.$event.id,
                eventTitle: item.event?.title,
                createdAt: item.createdAt ?? Date()
            )
        }
    }
}
