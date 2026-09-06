import Foundation

/// Route path helpers (architecture doc §5) so `/api/v1` endpoint paths
/// aren't hand-typed and drifting between the server and any client.
public enum APIRoute {
    public static let base = "/api/v1"

    public static let me = "\(base)/me"
    public static let events = "\(base)/events"
    public static func event(_ id: UUID) -> String { "\(events)/\(id)" }
    public static func eventJoin(_ id: UUID) -> String { "\(event(id))/join" }
    public static func eventLeave(_ id: UUID) -> String { "\(event(id))/leave" }
    public static func eventChatHistory(_ id: UUID) -> String { "\(event(id))/chat/history" }

    public static let groups = "\(base)/groups"
    public static func group(slug: String) -> String { "\(groups)/\(slug)" }
    public static func groupJoin(slug: String) -> String { "\(group(slug: slug))/join" }
    public static func groupLeave(slug: String) -> String { "\(group(slug: slug))/leave" }

    public static func profile(_ id: UUID) -> String { "\(base)/profile/\(id)" }
    public static func profileFollow(_ id: UUID) -> String { "\(profile(id))/follow" }
    public static func profileUnfollow(_ id: UUID) -> String { "\(profile(id))/unfollow" }

    public static let feed = "\(base)/feed"

    public static let accountPlan = "\(base)/account/plan"
    public static let accountPlanCheckout = "\(base)/account/plan/checkout"
    public static let accountExport = "\(base)/account/export"
    public static let accountDelete = "\(base)/account"

    public static let authApple = "\(base)/auth/apple"
    public static let authGoogle = "\(base)/auth/google"
    public static let authPasskeyRegisterOptions = "\(base)/auth/passkey/register/options"
    public static let authPasskeyRegisterVerify = "\(base)/auth/passkey/register/verify"
    public static let authPasskeyLoginOptions = "\(base)/auth/passkey/login/options"
    public static let authPasskeyLoginVerify = "\(base)/auth/passkey/login/verify"
}
