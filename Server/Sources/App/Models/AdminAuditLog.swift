import Fluent
import Vapor

/// Every mutating admin action writes one row here (architecture §4, §12).
/// `targetType`/`targetID` are a generic polymorphic reference (a `User`,
/// `Event`, `Group`, etc.) so there's no FK — the target table varies.
final class AdminAuditLog: Model, Content, @unchecked Sendable {
    static let schema = "admin_audit_logs"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "admin_user_id")
    var adminUser: User

    @Field(key: "action")
    var action: String

    @Field(key: "target_type")
    var targetType: String

    @Field(key: "target_id")
    var targetID: UUID

    @Field(key: "metadata")
    var metadata: [String: String]

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        adminUserID: User.IDValue,
        action: String,
        targetType: String,
        targetID: UUID,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.$adminUser.id = adminUserID
        self.action = action
        self.targetType = targetType
        self.targetID = targetID
        self.metadata = metadata
    }
}
