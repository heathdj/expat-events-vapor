import Fluent
import Vapor

/// Replaces the Realtime Database comments (architecture §4, M5).
/// `parentID` is self-referencing and nullable — one level of replies,
/// matching the current UI.
final class ChatMessage: Model, Content, @unchecked Sendable {
    static let schema = "chat_messages"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "event_id")
    var event: Event

    @Parent(key: "user_id")
    var user: User

    @OptionalParent(key: "parent_id")
    var parent: ChatMessage?

    @Field(key: "text")
    var text: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        eventID: Event.IDValue,
        userID: User.IDValue,
        parentID: ChatMessage.IDValue? = nil,
        text: String
    ) {
        self.id = id
        self.$event.id = eventID
        self.$user.id = userID
        self.$parent.id = parentID
        self.text = text
    }
}
