import Foundation

/// Carries the provider's identity token for server-side verification
/// (architecture doc §5, §7).
public struct AppleSignInRequest: Codable, Sendable, Equatable {
    /// The `identityToken` from `ASAuthorizationAppleIDCredential`, base64/JWT string.
    public let identityToken: String
    /// Apple only sends the user's name on the *first* authorization — pass
    /// it through if present so the server can seed `displayName`.
    public let displayName: String?

    public init(identityToken: String, displayName: String? = nil) {
        self.identityToken = identityToken
        self.displayName = displayName
    }
}

public struct GoogleSignInRequest: Codable, Sendable, Equatable {
    /// The Google ID token (JWT) from Google Identity Services / native SDK.
    public let idToken: String

    public init(idToken: String) {
        self.idToken = idToken
    }
}

public struct AuthTokenResponse: Codable, Sendable, Equatable {
    public let token: String
    public let user: UserDTO

    public init(token: String, user: UserDTO) {
        self.token = token
        self.user = user
    }
}
