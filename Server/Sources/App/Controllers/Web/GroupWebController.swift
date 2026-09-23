import Fluent
import Vapor
import ExpatEventsAPI

/// The server-rendered group pages (architecture §9, M6): directory,
/// create form, and a three-tab detail page (Upcoming Events / About /
/// Members). Follows `EventWebController`'s established shape closely —
/// same optionally-authenticated-for-reads / authenticated-for-writes
/// split, same htmx-fragment-swap pattern for join/leave (here also
/// promote), same "shared service, not reimplemented logic" reuse of
/// `PlanLimitsService`/`GroupService`.
struct GroupWebController: RouteCollection {
    struct GroupsPageContext: Encodable {
        let title = "Groups"
        let groups: [GroupDTO]
        let isSignedIn: Bool
    }

    struct NewGroupPageContext: Encodable {
        let title = "Start a group"
        /// M6 acceptance criterion #1: set when a plan-limit rejection
        /// (not Premium, or already owns a group) needs to be shown back
        /// to the user as a clear message, not a raw error page.
        let errorMessage: String?
    }

    /// One row in the Members tab, with the promote button's visibility
    /// precomputed here rather than compared in the Leaf template — see
    /// `GroupFragmentContext`'s doc comment for why.
    struct MemberRowContext: Encodable {
        let member: GroupMemberDTO
        let isPromotable: Bool
        let isDemotable: Bool
    }

    /// Same shape as `GroupDetailPageContext` minus the page-level
    /// `title`/`upcomingEvents` — this is what `partials/group-fragment.leaf`
    /// actually reads, whether rendered inline (via `#extend`, sharing the
    /// full page's context — the same proven pattern
    /// `EventFragmentContext`/`event-fragment.leaf` already use) or
    /// standalone (an htmx fragment response below).
    ///
    /// Every field here is a plain `Bool` (or a pre-filtered `[MemberRowContext]`)
    /// rather than something the template would need to compare against a
    /// raw enum value — `isOwner`, `canJoin`, `isPromotable`, etc. are all
    /// computed once in `membershipFlags(...)` below. This codebase has no
    /// existing example anywhere of a Leaf `#if` doing an equality
    /// comparison (every one is a plain truthy/nil check), so this avoids
    /// introducing untested Leaf syntax — the same caution M5 applied to
    /// its own templates.
    struct GroupFragmentContext: Encodable {
        let group: GroupDTO
        let isSignedIn: Bool
        let isOwner: Bool
        let isMemberNotOwner: Bool
        let canJoin: Bool
        let isInviteOnlyAndNotMember: Bool
        let members: [MemberRowContext]
    }

    struct GroupDetailPageContext: Encodable {
        let title: String
        let group: GroupDTO
        let upcomingEvents: [EventSummaryDTO]
        let isSignedIn: Bool
        let isOwner: Bool
        let isMemberNotOwner: Bool
        let canJoin: Bool
        let isInviteOnlyAndNotMember: Bool
        let members: [MemberRowContext]
    }

    func boot(routes: RoutesBuilder) throws {
        // Signed-out visitors can browse groups, same reasoning
        // EventWebController's dashboard/detail routes already documented:
        // session-authenticated-but-not-guarded, so isSignedIn reflects a
        // real session without requiring one.
        let optionallyAuthenticated = routes.grouped(User.sessionAuthenticator())
        optionallyAuthenticated.get("groups", use: directory)
        optionallyAuthenticated.get("groups", ":slug", use: detail)

        let authenticated = routes.grouped(User.sessionAuthenticator(), User.guardMiddleware(), NotSuspendedMiddleware())
        authenticated.get("groups", "new", use: newForm)
        authenticated.post("groups", use: create)
        authenticated.post("groups", ":groupID", "join", use: join)
        authenticated.post("groups", ":groupID", "leave", use: leave)
        authenticated.post("groups", ":groupID", "members", ":userID", "promote", use: promote)
        authenticated.post("groups", ":groupID", "members", ":userID", "demote", use: demote)
    }

    @Sendable
    func directory(req: Request) async throws -> View {
        let user = req.auth.get(User.self)
        let requesterID = try? user?.requireID()
        let service = GroupService(db: req.db)
        let groups = try await service.publicGroups()
        var dtos: [GroupDTO] = []
        for group in groups {
            dtos.append(try await service.toDTO(group, requesterID: requesterID))
        }
        return try await req.view.render("pages/groups", GroupsPageContext(groups: dtos, isSignedIn: user != nil))
    }

    @Sendable
    func newForm(req: Request) async throws -> View {
        try await req.view.render("pages/group-form", NewGroupPageContext(errorMessage: nil))
    }

    struct GroupFormInput: Content {
        let name: String
        let description: String
        let visibility: GroupVisibility?
    }

    @Sendable
    func create(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let input = try req.content.decode(GroupFormInput.self)
        let request = CreateGroupRequest(name: input.name, description: input.description, visibility: input.visibility ?? .public)
        let service = GroupService(db: req.db)
        do {
            let group = try await service.createGroup(request, ownerID: try user.requireID())
            return req.redirect(to: "/groups/\(group.slug)")
        } catch let error as APIError {
            // M6 acceptance criterion #1: a Free user's attempt gets a
            // clear upgrade prompt rendered back into the form, not a raw
            // error page. EventWebController.create's equivalent catch
            // block currently re-renders its form with no message at all
            // for the analogous private-event rejection — a pre-existing,
            // separately tracked gap (see MILESTONES.md's M4 section) —
            // fixed here rather than backported there, to keep this PR
            // scoped to M6.
            req.logger.notice("Group creation rejected: \(error.code) — \(error.message)")
            let view = try await req.view.render("pages/group-form", NewGroupPageContext(errorMessage: error.message))
            return try await view.encodeResponse(status: .badRequest, for: req)
        }
    }

    @Sendable
    func detail(req: Request) async throws -> View {
        let user = req.auth.get(User.self)
        let requesterID = try? user?.requireID()
        let group = try await groupOrNotFound(req)
        let service = GroupService(db: req.db)
        let dto = try await service.toDTO(group, requesterID: requesterID)
        let upcoming = try await service.upcomingEvents(of: group, requesterID: requesterID)
        let members = try await service.members(of: group)
        let flags = membershipFlags(group: group, dto: dto, isSignedIn: user != nil, members: members)

        return try await req.view.render("pages/group-detail", GroupDetailPageContext(
            title: dto.name,
            group: dto,
            upcomingEvents: upcoming,
            isSignedIn: user != nil,
            isOwner: flags.isOwner,
            isMemberNotOwner: flags.isMemberNotOwner,
            canJoin: flags.canJoin,
            isInviteOnlyAndNotMember: flags.isInviteOnlyAndNotMember,
            members: flags.memberRows
        ))
    }

    @Sendable
    func join(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let group = try await groupOrNotFound(req)
        try await GroupService(db: req.db).join(group, userID: try user.requireID())
        return try await respondWithGroupFragment(req: req, group: group)
    }

    @Sendable
    func leave(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let group = try await groupOrNotFound(req)
        try await GroupService(db: req.db).leave(group, userID: try user.requireID())
        return try await respondWithGroupFragment(req: req, group: group)
    }

    @Sendable
    func promote(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let group = try await groupOrNotFound(req)
        guard let memberIDString = req.parameters.get("userID"), let memberID = UUID(uuidString: memberIDString) else {
            throw Abort(.badRequest)
        }
        try await GroupService(db: req.db).promoteModerator(group, memberUserID: memberID, requesterID: try user.requireID())
        return try await respondWithGroupFragment(req: req, group: group)
    }

    /// Owner-only mirror of `promote` -- see `GroupService.demoteModerator`'s
    /// doc comment for what "remove a moderator" means here (revoke the
    /// role, not remove them from the group).
    @Sendable
    func demote(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let group = try await groupOrNotFound(req)
        guard let memberIDString = req.parameters.get("userID"), let memberID = UUID(uuidString: memberIDString) else {
            throw Abort(.badRequest)
        }
        try await GroupService(db: req.db).demoteModerator(group, memberUserID: memberID, requesterID: try user.requireID())
        return try await respondWithGroupFragment(req: req, group: group)
    }

    /// M6 acceptance criterion #6 (htmx fragment update, mirroring M4's
    /// `respondWithEventUpdate`): `req.auth.require` in each of the three
    /// callers above already guarantees a signed-in user, so `isSignedIn`
    /// is always `true` in the fragment.
    private func respondWithGroupFragment(req: Request, group: Group) async throws -> Response {
        guard req.headers.first(name: "HX-Request") != nil else {
            return req.redirect(to: "/groups/\(group.slug)")
        }
        let user = try req.auth.require(User.self)
        let requesterID = try user.requireID()
        let service = GroupService(db: req.db)
        let dto = try await service.toDTO(group, requesterID: requesterID)
        let members = try await service.members(of: group)
        let flags = membershipFlags(group: group, dto: dto, isSignedIn: true, members: members)
        let view = try await req.view.render("partials/group-fragment", GroupFragmentContext(
            group: dto,
            isSignedIn: true,
            isOwner: flags.isOwner,
            isMemberNotOwner: flags.isMemberNotOwner,
            canJoin: flags.canJoin,
            isInviteOnlyAndNotMember: flags.isInviteOnlyAndNotMember,
            members: flags.memberRows
        ))
        return try await view.encodeResponse(for: req)
    }

    private struct MembershipFlags {
        let isOwner: Bool
        let isMemberNotOwner: Bool
        let canJoin: Bool
        let isInviteOnlyAndNotMember: Bool
        let memberRows: [MemberRowContext]
    }

    /// All Swift-side, all computed once — see `GroupFragmentContext`'s
    /// doc comment for why nothing enum-shaped crosses into a Leaf `#if`.
    private func membershipFlags(group: Group, dto: GroupDTO, isSignedIn: Bool, members: [GroupMemberDTO]) -> MembershipFlags {
        let isOwner = dto.requesterRole == .owner
        let isMemberNotOwner = dto.isRequesterMember && !isOwner
        let canJoin = isSignedIn && !dto.isRequesterMember && group.visibility == .public
        let isInviteOnlyAndNotMember = isSignedIn && !dto.isRequesterMember && group.visibility != .public
        let rows = members.map { MemberRowContext(member: $0, isPromotable: isOwner && $0.role == .member, isDemotable: isOwner && $0.role == .moderator) }
        return MembershipFlags(
            isOwner: isOwner,
            isMemberNotOwner: isMemberNotOwner,
            canJoin: canJoin,
            isInviteOnlyAndNotMember: isInviteOnlyAndNotMember,
            memberRows: rows
        )
    }

    /// Detail requests are keyed by slug (`:slug` in the URL, readable
    /// pages); join/leave/promote's `:groupID` is the group's UUID
    /// instead (posted from a form whose action embeds `#(group.id)`, not
    /// the slug). Trying both means this one helper serves both route
    /// shapes without duplicating the not-found handling.
    private func groupOrNotFound(_ req: Request) async throws -> Group {
        if let idString = req.parameters.get("groupID"), let id = UUID(uuidString: idString),
           let group = try await GroupService(db: req.db).find(id) {
            return group
        }
        if let slug = req.parameters.get("slug"), let group = try await GroupService(db: req.db).find(slug: slug) {
            return group
        }
        throw Abort(.notFound)
    }
}
