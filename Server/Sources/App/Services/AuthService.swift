import Fluent
import Vapor
import ExpatEventsAPI

/// The current legal document versions new sign-ups implicitly consent to
/// (architecture §13). Bump these — and re-prompt existing users — when
/// either document changes materially.
enum LegalVersions {
    static let privacyPolicy = "2026-09-06"
    static let terms = "2026-09-06"
}

/// Finds-or-creates the `User`/`OAuthIdentity` pair for a verified
/// provider identity, implementing the account-linking rule from the
/// architecture doc and M2's acceptance criteria:
///
/// - A brand-new email creates exactly one `User` and one `OAuthIdentity`.
/// - Signing in with a *second* provider using an email already linked to
///   an existing account links a new `OAuthIdentity` to that **same**
///   `User` — never a second `User` (M2 criterion #3; §5 known-risk #7).
struct AuthService {
    let db: Database

    func findOrCreateUser(
        provider: IdentityProvider,
        providerUserID: String,
        email: String?,
        displayName: String?
    ) async throws -> User {
        // 1. Already linked via this exact provider identity? Use it as-is.
        if let identity = try await OAuthIdentity.query(on: db)
            .filter(\.$provider == provider)
            .filter(\.$providerUserID == providerUserID)
            .with(\.$user)
            .first()
        {
            return identity.user
        }

        // 2. A verified email that already belongs to a User (created via a
        //    different provider)? Link this provider to that same User
        //    rather than creating a second account.
        if let email, let existingUser = try await User.query(on: db)
            .filter(\.$email == email)
            .first()
        {
            let identity = OAuthIdentity(userID: try existingUser.requireID(), provider: provider, providerUserID: providerUserID)
            try await identity.save(on: db)
            return existingUser
        }

        // 3. Brand new account.
        guard let email else {
            throw APIError(code: "email_required", message: "This sign-in method didn't provide an email address.")
        }

        let user = User(
            displayName: displayName ?? email.components(separatedBy: "@").first ?? "New user",
            email: email,
            privacyPolicyVersion: LegalVersions.privacyPolicy,
            termsVersion: LegalVersions.terms,
            consentedAt: Date()
        )
        try await user.save(on: db)

        let identity = OAuthIdentity(userID: try user.requireID(), provider: provider, providerUserID: providerUserID)
        try await identity.save(on: db)

        // Every user starts on the Free plan (§11 plan enforcement).
        let subscription = Subscription(userID: try user.requireID(), plan: .free, status: .active)
        try await subscription.save(on: db)

        return user
    }
}
