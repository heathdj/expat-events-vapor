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

    /// Set when this account's `DeletionRequest` is processed (M9). The row
    /// survives as a tombstone with every identifying field erased --
    /// see `AddUserErasedAt`'s doc comment for why it isn't soft-deleted.
    @OptionalField(key: "erased_at")
    var erasedAt: Date?

    /// Theme PR 2: the inputs to `photoURL`, which stays the one value
    /// every page and DTO shows (`ProfilePhotoService.refresh` keeps it in
    /// step). nil source means automatic: Google, then an upload, then the
    /// default avatar. Gravatar is opt-in.
    /// Stored as plain text and read through `photoSource`, so an
    /// unexpected value can't make the whole row fail to load.
    @OptionalField(key: "photo_source")
    var photoSourceValue: String?

    var photoSource: PhotoSource? {
        get { photoSourceValue.flatMap(PhotoSource.init(rawValue:)) }
        set { photoSourceValue = newValue?.rawValue }
    }

    /// From the Google sign-in token's `picture` claim, refreshed on every
    /// Google sign-in. Apple sign-in provides no photo.
    @OptionalField(key: "google_photo_url")
    var googlePhotoURL: String?

    /// Where the member's uploaded photo is served (`PhotoStorage`).
    @OptionalField(key: "uploaded_photo_path")
    var uploadedPhotoPath: String?

    /// Whether gravatar.com has a photo for this email; nil = never checked.
    /// Only ever checked for members who chose Gravatar.
    @OptionalField(key: "gravatar_available")
    var gravatarAvailable: Bool?

    @OptionalField(key: "gravatar_checked_at")
    var gravatarCheckedAt: Date?

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
