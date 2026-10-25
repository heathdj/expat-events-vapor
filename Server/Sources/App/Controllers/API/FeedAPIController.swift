import Fluent
import Vapor
import ExpatEventsAPI

/// `/api/v1/feed` (architecture doc, M7). Shares `FeedService` with
/// `FeedWebController` -- same "one service, both surfaces" shape as
/// every other domain in this codebase.
struct FeedAPIController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let protected = routes.grouped("api", "v1", "feed")
            .grouped(UserBearerAuthenticator(), User.guardMiddleware(), NotSuspendedMiddleware())
        protected.get(use: index)
    }

    /// M7 acceptance criterion #5: always the authenticated requester's
    /// own feed, regardless of query parameters -- there's nothing to
    /// bypass because no query parameter is ever read here at all; the
    /// only identity this route consults is `req.auth.require(User.self)`.
    @Sendable
    func index(req: Request) async throws -> [ActivityFeedItemDTO] {
        let user = try req.auth.require(User.self)
        return try await FeedService(db: req.db).feed(for: try user.requireID())
    }
}
