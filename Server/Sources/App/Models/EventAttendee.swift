import Fluent
import Vapor

/// Replaces the embedded `attendees[]`/`attendeeIds[]` arrays from the
/// current app (architecture §4).
final class EventAttendee: Model, Content, @unchecked Sendable {
    static let schema = "event_attendees"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "event_id")
    var event: Event

    @Parent(key: "user_id")
    var user: User

    @Timestamp(key: "joined_at", on: .create)
    var joinedAt: Date?

    init() {}

    init(id: UUID? = nil, eventID: Event.IDValue, userID: User.IDValue) {
        self.id = id
        self.$event.id = eventID
        self.$user.id = userID
    }
}
