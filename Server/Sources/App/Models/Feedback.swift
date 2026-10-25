import Fluent
import Vapor

/// As today — `userID` is optional so anonymous/logged-out feedback still works.
final class Feedback: Model, Content, @unchecked Sendable {
    static let schema = "feedback"

    @ID(key: .id)
    var id: UUID?

    @OptionalParent(key: "user_id")
    var user: User?

    @Field(key: "message")
    var message: String

    /// Optional contact details (M9, legacy-app parity -- see
    /// `AddFeedbackContactFields`).
    @OptionalField(key: "name")
    var name: String?

    @OptionalField(key: "email")
    var email: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, userID: User.IDValue? = nil, message: String, name: String? = nil, email: String? = nil) {
        self.id = id
        self.$user.id = userID
        self.message = message
        self.name = name
        self.email = email
    }
}
