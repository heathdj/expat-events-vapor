import Fluent
import Vapor

/// Backs the web app's cookie-session auth (architecture §7: "Vapor runs a
/// cookie-session authenticator on the web route group ... resolving to the
/// same `User` model" as the bearer-token side). `User.IDValue` (`UUID`) is
/// `LosslessStringConvertible`, so the default session-ID encoding just works.
extension User: ModelSessionAuthenticatable {}

extension User: Authenticatable {}

/// The session authenticator every web route group uses (M9, replacing
/// Fluent's stock `User.sessionAuthenticator()`). The stock one just
/// looks the user up by the session's stored ID, so an account that's
/// been erased (or suspended) would still count as signed in on every
/// optionally-authenticated page -- `NotSuspendedMiddleware` only guards
/// the routes that *require* sign-in. This one refuses both outright, so
/// the session middleware unauthenticates the session on the way out.
///
/// Found by M9's independent review: `AccountService.process` purges an
/// erased user's sessions, but a sign-in racing the erasure transaction
/// could still insert a fresh session afterwards. With this check that
/// session is inert.
struct ActiveUserSessionAuthenticator: AsyncSessionAuthenticator {
    typealias User = App.User

    func authenticate(sessionID: UUID, for request: Request) async throws {
        guard let user = try await App.User.find(sessionID, on: request.db),
              !user.isSuspended,
              user.erasedAt == nil
        else {
            return
        }
        request.auth.login(user)
    }
}

extension User {
    static func activeSessionAuthenticator() -> ActiveUserSessionAuthenticator {
        ActiveUserSessionAuthenticator()
    }
}
