import Fluent
import Vapor

/// `/` (architecture doc, M7 -- added after the M6 PR merged, at the
/// user's request to "get more of the base app done"). There was no root
/// route at all before this milestone -- `base.leaf`'s own nav brand link
/// already pointed at `/`, but hitting it 404'd.
///
/// A signed-in visitor is never shown the marketing page below -- they're
/// redirected straight to `/feed`, which is also where `AuthWebController`
/// now sends a fresh sign-in, so `/` and "just signed in" land in the same
/// place either way. That's also why `pages/home.leaf` doesn't need an
/// `isSignedIn` branch the way every other page's template does: this
/// route only ever renders it for a signed-out request.
struct HomeWebController: RouteCollection {
    struct HomePageContext: Encodable {
        /// The hero's "N events on ExpatEvents" badge -- a real count, not
        /// the canvas mockup's hardcoded "212 events live now" sample
        /// copy (docs/design-system.md is explicit that the canvas's own
        /// inline sample data is never a data spec to carry over
        /// verbatim). Same non-cancelled-event count `EventService`'s own
        /// listings filter on.
        let activeEventCount: Int
    }

    func boot(routes: RoutesBuilder) throws {
        let optionallyAuthenticated = routes.grouped(User.activeSessionAuthenticator())
        optionallyAuthenticated.get(use: index)
    }

    @Sendable
    func index(req: Request) async throws -> Response {
        if req.auth.get(User.self) != nil {
            return req.redirect(to: "/feed")
        }
        let activeEventCount = try await Event.query(on: req.db)
            .filter(\.$isCancelled == false)
            .count()
        let view = try await req.view.render("pages/home", HomePageContext(activeEventCount: activeEventCount))
        return try await view.encodeResponse(for: req)
    }
}
