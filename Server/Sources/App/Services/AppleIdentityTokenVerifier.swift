import JWT
import Vapor
import ExpatEventsAPI

/// Verifies the `identityToken` from `ASAuthorizationAppleIDCredential`
/// (native) or Sign in with Apple JS (web) against Apple's published JWKS
/// (architecture §4 auth row, M2).
///
/// NOTE for whoever picks this up next: Apple rotates its signing keys
/// periodically. This fetches the JWKS fresh on every verification for
/// simplicity/correctness in the MVP; caching with the `Cache-Control`
/// header Apple returns (typically ~24h) is a reasonable fast-follow once
/// sign-in volume makes the extra round trip worth avoiding.
struct AppleIdentityTokenVerifier {
    struct ApplePayload: JWTPayload {
        enum CodingKeys: String, CodingKey {
            case issuer = "iss"
            case audience = "aud"
            case expiration = "exp"
            case subject = "sub"
            case email
        }

        var issuer: IssuerClaim
        var audience: AudienceClaim
        var expiration: ExpirationClaim
        var subject: SubjectClaim
        var email: String?

        func verify(using signer: JWTSigner) throws {
            try expiration.verifyNotExpired()
            try issuer.verify(equals: "https://appleid.apple.com")
        }
    }

    struct VerifiedIdentity {
        let providerUserID: String
        let email: String?
    }

    static let jwksURL = URI(string: "https://appleid.apple.com/auth/keys")

    /// `expectedAudience` is the Services ID / app bundle ID configured for
    /// "Sign in with Apple" — set via `APPLE_CLIENT_ID` (see `.env.example`).
    static func verify(identityToken: String, expectedAudience: String, client: Client) async throws -> VerifiedIdentity {
        let jwksResponse = try await client.get(jwksURL)
        guard let jwksData = jwksResponse.body else {
            throw APIError.invalidProviderToken
        }
        let jwks = try JSONDecoder().decode(JWKS.self, from: jwksData)
        let signers = JWTSigners()
        try signers.use(jwks: jwks)

        let payload: ApplePayload
        do {
            payload = try signers.verify(identityToken, as: ApplePayload.self)
        } catch {
            throw APIError.invalidProviderToken
        }

        guard payload.audience.value.contains(expectedAudience) else {
            throw APIError.invalidProviderToken
        }

        return VerifiedIdentity(providerUserID: payload.subject.value, email: payload.email)
    }
}
