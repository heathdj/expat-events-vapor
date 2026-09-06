import Fluent
import Vapor
import ExpatEventsAPI

/// `/api/v1/auth/*` and `/api/v1/me` (architecture §7, M2). Bearer-token
/// auth for native/API clients — the web app's equivalent flow lives in
/// `AuthWebController` and shares `AuthService`/the verifiers below it.
struct AuthAPIController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let auth = routes.grouped("api", "v1", "auth")
        auth.post("apple", use: signInWithApple)
        auth.post("google", use: signInWithGoogle)

        let protected = routes.grouped("api", "v1")
            .grouped(UserBearerAuthenticator())
            .grouped(User.guardMiddleware())
            .grouped(NotSuspendedMiddleware())
        protected.get("me", use: me)
    }

    @Sendable
    func signInWithApple(req: Request) async throws -> AuthTokenResponse {
        let body = try req.content.decode(AppleSignInRequest.self)
        guard let clientID = Environment.get("APPLE_CLIENT_ID") else {
            req.logger.error("APPLE_CLIENT_ID is not configured.")
            throw Abort(.internalServerError)
        }

        let identity: AppleIdentityTokenVerifier.VerifiedIdentity
        do {
            identity = try await AppleIdentityTokenVerifier.verify(
                identityToken: body.identityToken,
                expectedAudience: clientID,
                client: req.client
            )
        } catch {
            // M2 acceptance criterion #6: invalid/expired provider token ->
            // structured 401, never a 500.
            throw Abort(.unauthorized, reason: APIError.invalidProviderToken.message)
        }

        let user = try await AuthService(db: req.db).findOrCreateUser(
            provider: .apple,
            providerUserID: identity.providerUserID,
            email: identity.email,
            displayName: body.displayName
        )
        return try await tokenResponse(for: user, on: req)
    }

    @Sendable
    func signInWithGoogle(req: Request) async throws -> AuthTokenResponse {
        let body = try req.content.decode(GoogleSignInRequest.self)
        guard let clientID = Environment.get("GOOGLE_CLIENT_ID") else {
            req.logger.error("GOOGLE_CLIENT_ID is not configured.")
            throw Abort(.internalServerError)
        }

        let identity: GoogleIdentityTokenVerifier.VerifiedIdentity
        do {
            identity = try await GoogleIdentityTokenVerifier.verify(
                idToken: body.idToken,
                expectedAudience: clientID,
                client: req.client
            )
        } catch {
            throw Abort(.unauthorized, reason: APIError.invalidProviderToken.message)
        }

        let user = try await AuthService(db: req.db).findOrCreateUser(
            provider: .google,
            providerUserID: identity.providerUserID,
            email: identity.email,
            displayName: nil
        )
        return try await tokenResponse(for: user, on: req)
    }

    @Sendable
    func me(req: Request) async throws -> UserDTO {
        let user = try req.auth.require(User.self)
        let plan = try await PlanLimitsService(db: req.db).subscription(for: user.requireID()).plan
        return try user.toDTO(plan: plan)
    }

    private func tokenResponse(for user: User, on req: Request) async throws -> AuthTokenResponse {
        let payload = UserJWTPayload.make(userID: try user.requireID())
        let token = try req.jwt.sign(payload)
        let plan = try await PlanLimitsService(db: req.db).subscription(for: user.requireID()).plan
        return AuthTokenResponse(token: token, user: try user.toDTO(plan: plan))
    }
}
