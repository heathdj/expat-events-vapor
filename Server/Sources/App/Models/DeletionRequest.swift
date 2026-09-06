import Fluent
import Vapor

/// Formalizes the current `deleteUserRequest` into a real GDPR erasure
/// pipeline (architecture §13, M9). `processedAt` nil = still pending.
final class DeletionRequest: Model, Content, @unchecked Sendable {
    static let schema = "deletion_requests"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Timestamp(key: "requested_at", on: .create)
    var requestedAt: Date?

    @OptionalField(key: "processed_at")
    var processedAt: Date?

    init() {}

    init(id: UUID? = nil, userID: User.IDValue) {
        self.id = id
        self.$user.id = userID
    }
}
