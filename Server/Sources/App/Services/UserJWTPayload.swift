import JWT
import Vapor

/// The bearer token payload minted for native/API clients on successful
/// sign-in (architecture §7). The web app uses cookie sessions instead —
/// see `configure.swift`'s `configureSessions`.
struct UserJWTPayload: JWTPayload {
    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case expiration = "exp"
    }

    var subject: SubjectClaim
    var expiration: ExpirationClaim

    func verify(using signer: JWTSigner) throws {
        try expiration.verifyNotExpired()
    }

    var userID: UUID? {
        UUID(uuidString: subject.value)
    }

    static func make(userID: UUID, expiresIn: TimeInterval = 60 * 60 * 24 * 30) -> UserJWTPayload {
        UserJWTPayload(
            subject: SubjectClaim(value: userID.uuidString),
            expiration: ExpirationClaim(value: Date().addingTimeInterval(expiresIn))
        )
    }
}

/// Verifies the `Authorization: Bearer <jwt>` header and resolves it to a
/// `User`, so `/api/v1` routes authenticate the same `User` model the web
/// session authenticator does (architecture §7).
struct UserBearerAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        let payload: UserJWTPayload
        do {
            payload = try request.jwt.verify(bearer.token, as: UserJWTPayload.self)
        } catch {
            // Never a 500 on a bad/expired token (M2 acceptance criterion #6) —
            // just leave the request unauthenticated; `.guardMiddleware()`
            // downstream turns that into a structured 401.
            return
        }
        guard let userID = payload.userID,
              let user = try await User.find(userID, on: request.db),
              !user.isSuspended
        else {
            return
        }
        request.auth.login(user)
    }
}
