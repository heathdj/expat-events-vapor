import Fluent
import Vapor

/// Backs the web app's cookie-session auth (architecture §7: "Vapor runs a
/// cookie-session authenticator on the web route group ... resolving to the
/// same `User` model" as the bearer-token side). `User.IDValue` (`UUID`) is
/// `LosslessStringConvertible`, so the default session-ID encoding just works.
extension User: ModelSessionAuthenticatable {}

extension User: Authenticatable {}
