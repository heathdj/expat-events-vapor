import Fluent
import Vapor
import ExpatEventsAPI

/// One user can link more than one identity (e.g. registered with Google,
/// later linked Apple too) — account linking happens by verified email
/// (architecture §4, M2).
final class OAuthIdentity: Model, Content, @unchecked Sendable {
    static let schema = "oauth_identities"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Enum(key: "provider")
    var provider: IdentityProvider

    @Field(key: "provider_user_id")
    var providerUserID: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, userID: User.IDValue, provider: IdentityProvider, providerUserID: String) {
        self.id = id
        self.$user.id = userID
        self.provider = provider
        self.providerUserID = providerUserID
    }
}
