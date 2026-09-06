import Fluent
import Vapor

/// Stores only what WebAuthn ever hands the server — a public key and a
/// signature counter — no biometric data ever leaves the user's device
/// (architecture §4, §18). M3 (Passkeys) is a stretch milestone; this model
/// exists from M1 so the schema doesn't shift under M3 later.
final class PasskeyCredential: Model, Content, @unchecked Sendable {
    static let schema = "passkey_credentials"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "credential_id")
    var credentialID: String

    @Field(key: "public_key")
    var publicKey: String

    @Field(key: "sign_count")
    var signCount: Int

    /// e.g. "iPhone 15 Pro" — shown in `/account/passkeys`.
    @Field(key: "device_label")
    var deviceLabel: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @OptionalField(key: "last_used_at")
    var lastUsedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: User.IDValue,
        credentialID: String,
        publicKey: String,
        signCount: Int = 0,
        deviceLabel: String
    ) {
        self.id = id
        self.$user.id = userID
        self.credentialID = credentialID
        self.publicKey = publicKey
        self.signCount = signCount
        self.deviceLabel = deviceLabel
    }
}
