import Fluent
import Vapor
import ExpatEventsAPI

/// `/login`, `/register`, and the session-creating callbacks the page's
/// "Continue with Apple" / "Continue with Google" JS widgets POST to
/// (architecture §6, M2). No password field anywhere (M2 criterion #1) —
/// `/register` renders the same page as `/login`, since there's nothing
/// separate to "register" with a passwordless flow.
struct AuthWebController: RouteCollection {
    struct LoginPageContext: Encodable {
        let title = "Sign in"
        let appleClientID: String?
        let googleClientID: String?
    }

    func boot(routes: RoutesBuilder) throws {
        routes.get("login", use: loginPage)
        routes.get("register", use: loginPage)
        routes.post("login", "apple", use: signInWithApple)
        routes.post("login", "google", use: signInWithGoogle)

        let protected = routes.grouped(User.sessionAuthenticator())
            .grouped(User.guardMiddleware())
        protected.post("logout", use: logout)
    }

    @Sendable
    func loginPage(req: Request) async throws -> View {
        try await req.view.render("pages/login", LoginPageContext(
            appleClientID: Environment.get("APPLE_CLIENT_ID"),
            googleClientID: Environment.get("GOOGLE_CLIENT_ID")
        ))
    }

    @Sendable
    func signInWithApple(req: Request) async throws -> Response {
        let body = try req.content.decode(AppleSignInRequest.self)
        guard let clientID = Environment.get("APPLE_CLIENT_ID") else {
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
            throw Abort(.unauthorized, reason: APIError.invalidProviderToken.message)
        }
        let user = try await AuthService(db: req.db).findOrCreateUser(
            provider: .apple,
            providerUserID: identity.providerUserID,
            email: identity.email,
            displayName: body.displayName
        )
        req.auth.login(user)
        req.session.authenticate(user)
        return req.redirect(to: "/events")
    }

    @Sendable
    func signInWithGoogle(req: Request) async throws -> Response {
        let body = try req.content.decode(GoogleSignInRequest.self)
        guard let clientID = Environment.get("GOOGLE_CLIENT_ID") else {
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
        req.auth.login(user)
        req.session.authenticate(user)
        return req.redirect(to: "/events")
    }

    /// M2 acceptance criterion #7: signing out invalidates the web session.
    @Sendable
    func logout(req: Request) async throws -> Response {
        req.auth.logout(User.self)
        req.session.unauthenticate(User.self)
        req.session.destroy()
        return req.redirect(to: "/login")
    }
}
