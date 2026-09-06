import Vapor
import ExpatEventsAPI

/// Verifies a Google ID token via Google's `tokeninfo` endpoint
/// (architecture §4 auth row, M2). This is Google's own documented
/// verification path and is simpler/more reliable to stand up for an MVP
/// than fetching and caching Google's JWKS ourselves — worth revisiting if
/// sign-in volume makes the extra network round trip per sign-in a real cost.
struct GoogleIdentityTokenVerifier {
    struct TokenInfoResponse: Codable {
        let aud: String
        let sub: String
        let email: String?
        let emailVerified: String?
        let exp: String

        enum CodingKeys: String, CodingKey {
            case aud, sub, email, exp
            case emailVerified = "email_verified"
        }
    }

    struct VerifiedIdentity {
        let providerUserID: String
        let email: String?
    }

    /// `expectedAudience` is the OAuth web client ID — set via
    /// `GOOGLE_CLIENT_ID` (see `.env.example`).
    static func verify(idToken: String, expectedAudience: String, client: Client) async throws -> VerifiedIdentity {
        let response = try await client.get("https://oauth2.googleapis.com/tokeninfo", beforeSend: { req in
            try req.query.encode(["id_token": idToken])
        })

        guard response.status == .ok, let body = response.body else {
            throw APIError.invalidProviderToken
        }

        let info: TokenInfoResponse
        do {
            info = try JSONDecoder().decode(TokenInfoResponse.self, from: body)
        } catch {
            throw APIError.invalidProviderToken
        }

        guard info.aud == expectedAudience else {
            throw APIError.invalidProviderToken
        }

        guard let expSeconds = Double(info.exp), Date(timeIntervalSince1970: expSeconds) > Date() else {
            throw APIError.invalidProviderToken
        }

        return VerifiedIdentity(providerUserID: info.sub, email: info.email)
    }
}
