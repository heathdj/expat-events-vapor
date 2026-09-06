import Fluent
import Vapor
import ExpatEventsAPI

/// App-level rule enforced in `GroupService`, not the schema: at most 5
/// moderators per group (architecture §4, §9, M6).
final class GroupMembership: Model, Content, @unchecked Sendable {
    static let schema = "group_memberships"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "group_id")
    var group: Group

    @Parent(key: "user_id")
    var user: User

    @Enum(key: "role")
    var role: GroupRole

    @Timestamp(key: "joined_at", on: .create)
    var joinedAt: Date?

    init() {}

    init(id: UUID? = nil, groupID: Group.IDValue, userID: User.IDValue, role: GroupRole = .member) {
        self.id = id
        self.$group.id = groupID
        self.$user.id = userID
        self.role = role
    }
}
