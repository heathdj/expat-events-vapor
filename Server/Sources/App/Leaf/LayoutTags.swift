import Leaf
import Vapor

/// Leaf tags for the shared app layout (theme foundation PR). The nav needs
/// the signed-in member's name, photo and ID on every page, and which
/// section is current; reading them from the request here means none of
/// the app's page contexts has to carry them. Each one reads the user the
/// active session authenticator already checked (not suspended, not
/// erased). All output is escaped by Leaf except where noted.

/// `#avatarURL(photoURL)`: the photo to show for a person, or the default
/// avatar. Only `https:` URLs and site paths are used, so a stored value
/// can never become a `javascript:` link in an `src` attribute.
struct AvatarURLTag: LeafTag {
    static let placeholder = "/design/avatar-placeholder.png"

    func render(_ ctx: LeafContext) throws -> LeafData {
        let value = ctx.parameters.first?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .string(Self.resolve(value))
    }

    static func resolve(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return placeholder }
        let lowered = value.lowercased()
        // "/\host" is excluded too: browsers read it as "//host".
        if lowered.hasPrefix("https://") || (value.hasPrefix("/") && !value.hasPrefix("//") && !value.hasPrefix("/\\")) {
            return value
        }
        return placeholder
    }
}

/// `#currentUser("name")`, `#currentUser("avatar")` or `#currentUser("id")`:
/// the signed-in member, for the nav's user pill and menu. Empty when
/// nobody is signed in.
struct CurrentUserTag: LeafTag {
    func render(_ ctx: LeafContext) throws -> LeafData {
        guard let user = ctx.request?.auth.get(User.self) else { return .string("") }
        switch ctx.parameters.first?.string ?? "name" {
        case "avatar": return .string(AvatarURLTag.resolve(user.photoURL))
        case "id": return .string(user.id?.uuidString ?? "")
        case "initial": return .string(user.displayName.first.map { String($0).uppercased() } ?? "")
        default: return .string(user.displayName)
        }
    }
}

/// `#navActive("/events")`: "is-active" when the current page is under
/// that path, for the nav's pill highlight; otherwise empty.
struct NavActiveTag: LeafTag {
    func render(_ ctx: LeafContext) throws -> LeafData {
        guard let prefix = ctx.parameters.first?.string, let path = ctx.request?.url.path else {
            return .string("")
        }
        let matches = path == prefix || path.hasPrefix(prefix + "/")
        return .string(matches ? "is-active" : "")
    }
}
