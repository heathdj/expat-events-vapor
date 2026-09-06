import Fluent
import Vapor
import ExpatEventsAPI

/// Owner must hold an active Premium subscription; one group per membership
/// (architecture §4, §9, M6).
final class Group: Model, Content, @unchecked Sendable {
    static let schema = "groups"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Field(key: "slug")
    var slug: String

    @Field(key: "description")
    var groupDescription: String

    @OptionalField(key: "avatar_url")
    var avatarURL: String?

    @OptionalField(key: "cover_url")
    var coverURL: String?

    @Enum(key: "visibility")
    var visibility: GroupVisibility

    @Parent(key: "owner_id")
    var owner: User

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Children(for: \.$group)
    var memberships: [GroupMembership]

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        slug: String,
        description: String,
        avatarURL: String? = nil,
        coverURL: String? = nil,
        visibility: GroupVisibility = .public,
        ownerID: User.IDValue
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.groupDescription = description
        self.avatarURL = avatarURL
        self.coverURL = coverURL
        self.visibility = visibility
        self.$owner.id = ownerID
    }
}
