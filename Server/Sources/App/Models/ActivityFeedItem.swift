import Fluent
import Vapor
import ExpatEventsAPI

/// Replaces the Cloud Functions that pushed to Realtime DB `/posts/{userId}`
/// (architecture §4, §10). Populated synchronously inside the relevant
/// handler (join/leave/follow) rather than via a trigger function.
final class ActivityFeedItem: Model, Content, @unchecked Sendable {
    static let schema = "activity_feed_items"

    @ID(key: .id)
    var id: UUID?

    /// Whose feed this appears in.
    @Parent(key: "recipient_user_id")
    var recipient: User

    @Parent(key: "actor_user_id")
    var actor: User

    @Enum(key: "type")
    var type: ActivityFeedItemType

    @OptionalParent(key: "event_id")
    var event: Event?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        recipientUserID: User.IDValue,
        actorUserID: User.IDValue,
        type: ActivityFeedItemType,
        eventID: Event.IDValue? = nil
    ) {
        self.id = id
        self.$recipient.id = recipientUserID
        self.$actor.id = actorUserID
        self.type = type
        self.$event.id = eventID
    }
}
