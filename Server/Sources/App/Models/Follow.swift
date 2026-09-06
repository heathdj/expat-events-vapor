import Fluent
import Vapor

/// Kept from the current app's `following` collection (architecture §4).
final class Follow: Model, Content, @unchecked Sendable {
    static let schema = "follows"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "follower_id")
    var follower: User

    @Parent(key: "following_id")
    var following: User

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, followerID: User.IDValue, followingID: User.IDValue) {
        self.id = id
        self.$follower.id = followerID
        self.$following.id = followingID
    }
}
