import Fluent
import Vapor
import ExpatEventsAPI

/// Mapped from the current Firestore `users` collection (architecture §4).
/// No password field at all — every sign-in method is passwordless
/// (Apple, Google, and eventually passkeys).
final class User: Model, Content, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "display_name")
    var displayName: String

    @Field(key: "email")
    var email: String

    @OptionalField(key: "photo_url")
    var photoURL: String?

    @Enum(key: "role")
    var role: UserRole

    @Field(key: "is_suspended")
    var isSuspended: Bool

    /// *Which* version of the Privacy Policy / Terms was agreed to, and when
    /// (architecture §13) — replaces the old flat `privacy`/`terms` booleans.
    @Field(key: "privacy_policy_version")
    var privacyPolicyVersion: String

    @Field(key: "terms_version")
    var termsVersion: String

    @Field(key: "consented_at")
    var consentedAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Children(for: \.$user)
    var oauthIdentities: [OAuthIdentity]

    @Children(for: \.$user)
    var passkeyCredentials: [PasskeyCredential]

    init() {}

    init(
        id: UUID? = nil,
        displayName: String,
        email: String,
        photoURL: String? = nil,
        role: UserRole = .member,
        isSuspended: Bool = false,
        privacyPolicyVersion: String,
        termsVersion: String,
        consentedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.photoURL = photoURL
        self.role = role
        self.isSuspended = isSuspended
        self.privacyPolicyVersion = privacyPolicyVersion
        self.termsVersion = termsVersion
        self.consentedAt = consentedAt
    }
}

extension User {
    /// Convert to the wire-format DTO. `plan` is looked up separately since
    /// it lives on `Subscription`, not `User` — callers pass it in.
    func toDTO(plan: PlanTier) throws -> UserDTO {
        UserDTO(
            id: try requireID(),
            displayName: displayName,
            email: email,
            photoURL: photoURL,
            role: role,
            plan: plan,
            createdAt: createdAt ?? Date()
        )
    }
}
