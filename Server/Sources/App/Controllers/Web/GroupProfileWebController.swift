import Fluent
import Vapor
import ExpatEventsAPI

/// `/groups/:slug/edit` and its form posts (theme PR 3): the group's owner
/// and moderators edit its name, description and visibility, and upload or
/// remove its logo. Anyone else gets a 403. Plain styling for now, using
/// the design tokens like `/account`; the Groups restyle comes later.
struct GroupProfileWebController: RouteCollection {
    struct EditPageContext: Encodable {
        let title: String
        let isSignedIn = true
        let group: GroupDTO
        let name: String
        let description: String
        let isPublic: Bool
        /// Only the owner sees the visibility choice.
        let isOwner: Bool
        let hasLogo: Bool
        let errorMessage: String?
        let logoError: String?
        let notice: String?
    }

    struct EditForm: Content {
        let name: String
        let description: String
        let visibility: GroupVisibility?
    }

    struct LogoForm: Content {
        let logo: File?
    }

    static let forbidden = Abort(.forbidden, reason: "Only the group's owner and moderators can edit it.")

    static let notices = [
        "details": "Group details saved.",
        "logo": "Logo uploaded.",
        "logo-removed": "Logo removed.",
    ]

    func boot(routes: RoutesBuilder) throws {
        let authenticated = routes.grouped(User.activeSessionAuthenticator(), User.redirectMiddleware(path: "/login"), NotSuspendedMiddleware())
        authenticated.get("groups", ":slug", "edit", use: editPage)
        authenticated.post("groups", ":groupID", "edit", use: update)
        // Room above the 2 MB limit, so a too-big logo gets the message
        // rather than Vapor's bare 413 (same as profile photos).
        authenticated.on(.POST, "groups", ":groupID", "logo", body: .collect(maxSize: "10mb"), use: uploadLogo)
        authenticated.post("groups", ":groupID", "logo", "remove", use: removeLogo)
    }

    @Sendable
    func editPage(req: Request) async throws -> View {
        let user = try req.auth.require(User.self)
        guard let slug = req.parameters.get("slug"), let group = try await GroupService(db: req.db).find(slug: slug) else {
            throw Abort(.notFound)
        }
        try await assertCanManage(group, user: user, req: req)
        return try await render(req: req, group: group, user: user, input: nil, errorMessage: nil, logoError: nil)
    }

    @Sendable
    func update(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let group = try await groupByID(req)
        try await assertCanManage(group, user: user, req: req)
        guard let form = try? req.content.decode(EditForm.self) else {
            throw Abort(.badRequest)
        }
        do {
            try await service(req).updateProfile(group, name: form.name, description: form.description,
                                                 visibility: form.visibility, by: user.requireID())
        } catch let error as APIError where error.code != APIError.forbidden.code {
            return try await render(req: req, group: group, user: user, input: form, errorMessage: error.message, logoError: nil)
                .encodeResponse(status: .unprocessableEntity, for: req)
        } catch let error as APIError where error.code == APIError.forbidden.code {
            throw Self.forbidden
        }
        return req.redirect(to: "/groups/\(group.slug)/edit?saved=details")
    }

    @Sendable
    func uploadLogo(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let group = try await groupByID(req)
        try await assertCanManage(group, user: user, req: req)
        let data = (try? req.content.decode(LogoForm.self))?.logo.map { Data($0.data.readableBytesView) } ?? Data()
        do {
            try await service(req).uploadLogo(data, for: group, by: user.requireID())
        } catch let error as APIError where error.code != APIError.forbidden.code {
            return try await render(req: req, group: group, user: user, input: nil, errorMessage: nil, logoError: error.message)
                .encodeResponse(status: .unprocessableEntity, for: req)
        } catch let error as APIError where error.code == APIError.forbidden.code {
            throw Self.forbidden
        }
        return req.redirect(to: "/groups/\(group.slug)/edit?saved=logo#logo")
    }

    /// Posted over htmx for its hx-confirm, so it answers with HX-Redirect.
    @Sendable
    func removeLogo(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let group = try await groupByID(req)
        try await assertCanManage(group, user: user, req: req)
        do {
            try await service(req).removeLogo(for: group, by: user.requireID())
        } catch let error as APIError where error.code == APIError.forbidden.code {
            throw Self.forbidden
        }
        let target = "/groups/\(group.slug)/edit?saved=logo-removed#logo"
        if req.headers.first(name: "HX-Request") != nil {
            let response = Response(status: .ok)
            response.headers.replaceOrAdd(name: "HX-Redirect", value: target)
            return response
        }
        return req.redirect(to: target)
    }

    // MARK: - Helpers

    private func service(_ req: Request) -> GroupProfileService {
        GroupProfileService(db: req.db, storage: req.application.photoStorage)
    }

    private func groupByID(_ req: Request) async throws -> Group {
        guard let text = req.parameters.get("groupID"), let id = UUID(uuidString: text),
              let group = try await GroupService(db: req.db).find(id) else {
            throw Abort(.notFound)
        }
        return group
    }

    private func assertCanManage(_ group: Group, user: User, req: Request) async throws {
        guard try await GroupProfileService.canManage(group, userID: user.requireID(), on: req.db) else {
            throw Self.forbidden
        }
    }

    private func render(req: Request, group: Group, user: User, input: EditForm?,
                        errorMessage: String?, logoError: String?) async throws -> View {
        let dto = try await GroupService(db: req.db).toDTO(group, requesterID: try user.requireID())
        let visibility = input?.visibility ?? group.visibility
        return try await req.view.render("pages/group-edit", EditPageContext(
            title: "Edit \(group.name)",
            group: dto,
            name: input?.name ?? group.name,
            description: input?.description ?? group.groupDescription,
            isPublic: visibility == .public,
            isOwner: group.$owner.id == (try user.requireID()),
            hasLogo: group.avatarURL != nil,
            errorMessage: errorMessage,
            logoError: logoError,
            notice: (try? req.query.get(String.self, at: "saved")).flatMap { Self.notices[$0] }
        ))
    }
}
