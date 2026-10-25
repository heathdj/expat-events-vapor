import Fluent
import Vapor
import ExpatEventsAPI

/// `/feed` (architecture doc, M7). Authenticated only -- there's no
/// meaningful feed for a signed-out visitor (it's keyed entirely to the
/// requester's own `Follow` rows), unlike `/events`/`/groups`, which stay
/// browsable while signed out.
struct FeedWebController: RouteCollection {
    /// One rendered feed row. `message` and `hasEvent` are precomputed
    /// here in Swift rather than left for the template to branch on
    /// `item.type`'s raw enum value -- this codebase has no example
    /// anywhere of a Leaf `#if` doing an equality comparison (every one is
    /// a plain truthy/nil check, per `GroupFragmentContext`'s own doc
    /// comment), so this follows that same convention instead of being
    /// the first to introduce untested Leaf syntax.
    struct FeedItemContext: Encodable {
        let actorUserID: UUID
        let actorDisplayName: String
        let actorPhotoURL: String?
        let message: String
        let hasEvent: Bool
        let eventID: UUID?
    }

    struct FeedPageContext: Encodable {
        let title = "Your feed"
        let isSignedIn = true
        let items: [FeedItemContext]
    }

    func boot(routes: RoutesBuilder) throws {
        let authenticated = routes.grouped(User.activeSessionAuthenticator(), User.guardMiddleware(), NotSuspendedMiddleware())
        authenticated.get("feed", use: index)
    }

    @Sendable
    func index(req: Request) async throws -> View {
        let user = try req.auth.require(User.self)
        let items = try await FeedService(db: req.db).feed(for: try user.requireID())
        return try await req.view.render("pages/feed", FeedPageContext(items: items.map(Self.rowContext)))
    }

    private static func rowContext(_ item: ActivityFeedItemDTO) -> FeedItemContext {
        FeedItemContext(
            actorUserID: item.actorUserID,
            actorDisplayName: item.actorDisplayName,
            actorPhotoURL: item.actorPhotoURL,
            message: message(for: item),
            hasEvent: item.eventID != nil,
            eventID: item.eventID
        )
    }

    private static func message(for item: ActivityFeedItemDTO) -> String {
        let eventTitle = item.eventTitle ?? "an event"
        switch item.type {
        case .joinedEvent:
            return "joined \u{201C}\(eventTitle)\u{201D}"
        case .leftEvent:
            return "left \u{201C}\(eventTitle)\u{201D}"
        case .startedFollowing:
            return "started following you"
        case .groupPostedEvent:
            return "posted a new group event: \u{201C}\(eventTitle)\u{201D}"
        }
    }
}
