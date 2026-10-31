import Leaf
import Vapor

/// `#adminNavLink()` in `layouts/base.leaf`'s nav (M10): an "Admin" link,
/// shown only to a signed-in admin. A tag rather than a context flag, so
/// every page gets it without each of the app's page contexts carrying an
/// `isAdmin` key. Reads the request's signed-in user, which the active
/// session authenticator on every web route group has already checked
/// (not suspended, not erased). The output is fixed HTML, never built from
/// user data, so it's safe unescaped.
struct AdminNavLinkTag: UnsafeUnescapedLeafTag {
    func render(_ ctx: LeafContext) throws -> LeafData {
        guard let user = ctx.request?.auth.get(User.self), user.role == .admin else {
            return .string("")
        }
        return .string(#"<a href="/admin" class="hover:underline">Admin</a>"#)
    }
}
