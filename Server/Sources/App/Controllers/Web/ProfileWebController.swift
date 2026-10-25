import Fluent
import Vapor
import ExpatEventsAPI

/// `/profile/:userID` (architecture doc, M7). Follows `EventWebController`/
/// `GroupWebController`'s established shape: signed-out visitors can view
/// a profile (optionally-authenticated GET), but only a signed-in visitor
/// can follow/unfollow (authenticated POST, htmx-fragment-swap on success
/// -- same pattern `partials/group-fragment.leaf` already uses for
/// join/leave/promote/demote).
struct ProfileWebController: RouteCollection {
    /// One row in the Followers or Following tab.
    struct FollowEntryContext: Encodable {
        let userID: UUID
        let displayName: String
        let photoURL: String?
    }

    /// Same shape as `ProfilePageContext` minus the page-level `title`/
    /// `followers`/`following` -- what `partials/profile-fragment.leaf`
    /// reads, whether rendered inline (via `\#extend`, sharing the full
    /// page's context) or standalone (an htmx fragment response below) --
    /// the exact pattern `GroupFragmentContext`'s own doc comment
    /// describes for M6.
    struct ProfileFragmentContext: Encodable {
        let profile: ProfileDTO
        let isSignedIn: Bool
        let isOwnProfile: Bool
        let canFollow: Bool
    }

    struct ProfilePageContext: Encodable {
        let title: String
        let profile: ProfileDTO
        let isSignedIn: Bool
        let isOwnProfile: Bool
        let canFollow: Bool
        let followers: [FollowEntryContext]
        let following: [FollowEntryContext]
    }

    func boot(routes: RoutesBuilder) throws {
        let optionallyAuthenticated = routes.grouped(User.sessionAuthenticator())
        optionallyAuthenticated.get("profile", ":userID", use: detail)

        let authenticated = routes.grouped(User.sessionAuthenticator(), User.guardMiddleware(), NotSuspendedMiddleware())
        authenticated.post("profile", ":userID", "follow", use: follow)
        authenticated.post("profile", ":userID", "unfollow", use: unfollow)
    }

    @Sendable
    func detail(req: Request) async throws -> View {
        let user = req.auth.get(User.self)
        let requesterID = try? user?.requireID()
        let profileUser = try await userOrNotFound(req)
        let profileUserID = try profileUser.requireID()
        let service = FollowService(db: req.db)

        let dto = try await service.profile(of: profileUser, requesterID: requesterID)
        let followers = try await service.followerEntries(of: profileUserID)
        let following = try await service.followingEntries(of: profileUserID)
        let isOwnProfile = requesterID == profileUserID

        return try await req.view.render("pages/profile", ProfilePageContext(
            title: dto.displayName,
            profile: dto,
            isSignedIn: user != nil,
            isOwnProfile: isOwnProfile,
            canFollow: user != nil && !isOwnProfile,
            followers: followers.map { FollowEntryContext(userID: $0.userID, displayName: $0.displayName, photoURL: $0.photoURL) },
            following: following.map { FollowEntryContext(userID: $0.userID, displayName: $0.displayName, photoURL: $0.photoURL) }
        ))
    }

    @Sendable
    func follow(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let profileUser = try await userOrNotFound(req)
        try await FollowService(db: req.db).follow(followerID: try user.requireID(), followingID: try profileUser.requireID())
        return try await respondWithProfileFragment(req: req, profileUser: profileUser)
    }

    @Sendable
    func unfollow(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let profileUser = try await userOrNotFound(req)
        try await FollowService(db: req.db).unfollow(followerID: try user.requireID(), followingID: try profileUser.requireID())
        return try await respondWithProfileFragment(req: req, profileUser: profileUser)
    }

    /// M7 acceptance criterion #1's "the button updates immediately via
    /// htmx" -- mirrors `GroupWebController.respondWithGroupFragment`
    /// exactly, including the same non-htmx fallback redirect.
    private func respondWithProfileFragment(req: Request, profileUser: User) async throws -> Response {
        guard req.headers.first(name: "HX-Request") != nil else {
            return req.redirect(to: "/profile/\(try profileUser.requireID())")
        }
        let user = try req.auth.require(User.self)
        let requesterID = try user.requireID()
        let profileUserID = try profileUser.requireID()
        let dto = try await FollowService(db: req.db).profile(of: profileUser, requesterID: requesterID)
        let isOwnProfile = requesterID == profileUserID
        let view = try await req.view.render("partials/profile-fragment", ProfileFragmentContext(
            profile: dto,
            isSignedIn: true,
            isOwnProfile: isOwnProfile,
            canFollow: !isOwnProfile
        ))
        return try await view.encodeResponse(for: req)
    }

    private func userOrNotFound(_ req: Request) async throws -> User {
        guard let idString = req.parameters.get("userID"), let id = UUID(uuidString: idString),
              let user = try await User.find(id, on: req.db)
        else {
            throw Abort(.notFound)
        }
        return user
    }
}
