import Vapor
import ExpatEventsAPI

/// Gates every `/admin/*` route (web) and `/api/v1/admin/*` route (native
/// admin app) — architecture §12. A non-admin gets blocked outright, never
/// rendered the page (M10 acceptance criterion #1).
struct AdminMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let user = request.auth.get(User.self), user.role == .admin, !user.isSuspended else {
            throw Abort(.forbidden, reason: "Admin access required.")
        }
        return try await next.respond(to: request)
    }
}

/// Suspended users can't authenticate onward even with a still-valid
/// session/token (M10 acceptance criterion #3) — checked as a matter of
/// course by both the session and bearer authenticators, but this
/// middleware gives every protected route group a second, explicit check.
struct NotSuspendedMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        if let user = request.auth.get(User.self), user.isSuspended {
            request.auth.logout(User.self)
            throw Abort(.unauthorized, reason: "This account has been suspended.")
        }
        return try await next.respond(to: request)
    }
}
