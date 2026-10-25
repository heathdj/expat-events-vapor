import Vapor

/// `/privacy` and `/terms` (architecture §6, M9 acceptance criterion #7).
/// Public, signed in or not.
///
/// Placeholder body text, per the user's M9 decision: the legacy app's
/// policy (photo-tracker, last updated May 8, 2023) names Firebase/Google
/// as processors and describes tracking cookies, neither of which is true
/// of this stack, so it wasn't carried over. The final wording is the
/// user's to supply. What IS real is the version stamp: each page shows
/// the exact `LegalVersions` string `AuthService` records on every new
/// account, read from that single constant rather than repeated here, so
/// the page and the recorded consent can't drift apart.
struct LegalWebController: RouteCollection {
    struct LegalPageContext: Encodable {
        let title: String
        let isSignedIn: Bool
        let version: String
    }

    func boot(routes: RoutesBuilder) throws {
        let optionallyAuthenticated = routes.grouped(User.activeSessionAuthenticator())
        optionallyAuthenticated.get("privacy", use: privacy)
        optionallyAuthenticated.get("terms", use: terms)
    }

    @Sendable
    func privacy(req: Request) async throws -> View {
        try await req.view.render("pages/privacy", LegalPageContext(
            title: "Privacy Policy",
            isSignedIn: req.auth.has(User.self),
            version: LegalVersions.privacyPolicy
        ))
    }

    @Sendable
    func terms(req: Request) async throws -> View {
        try await req.view.render("pages/terms", LegalPageContext(
            title: "Terms and Conditions",
            isSignedIn: req.auth.has(User.self),
            version: LegalVersions.terms
        ))
    }
}
