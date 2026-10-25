import Fluent
import Vapor
import ExpatEventsAPI

/// `/account` (architecture §6, M9 acceptance criteria #2, #3, #6) --
/// the private, self-only counterpart to M7's public `/profile/:id`.
/// Styled from the design canvas's Account & billing artboard, minus its
/// Stripe-backed parts (plan changes, payment method, billing history),
/// which wait on M8.
struct AccountWebController: RouteCollection {
    /// The part of the page that changes when "Delete account" is
    /// confirmed (`partials/account-data-fragment.leaf`). Flat keys, the
    /// same inline-`#extend` / standalone-render pattern as every other
    /// fragment in this codebase.
    struct AccountDataFragmentContext: Encodable {
        let hasPendingDeletion: Bool
        let deletionRequestedOn: String?
    }

    struct AccountPageContext: Encodable {
        let title = "Account"
        let isSignedIn = true
        let displayName: String
        let email: String
        let photoURL: String?
        let memberSince: String
        let isPremium: Bool
        let planLabel: String
        let profileError: String?
        /// Re-open the edit form when it's being re-rendered with an error.
        let startEditing: Bool
        let hasPendingDeletion: Bool
        let deletionRequestedOn: String?
    }

    struct ProfileForm: Content {
        let displayName: String
    }

    func boot(routes: RoutesBuilder) throws {
        let authenticated = routes.grouped(
            User.activeSessionAuthenticator(),
            User.redirectMiddleware(path: "/login"),
            NotSuspendedMiddleware()
        )
        authenticated.get("account", use: page)
        authenticated.post("account", "profile", use: updateProfile)
        authenticated.post("account", "export", use: export)
        authenticated.post("account", "delete", use: requestDeletion)
    }

    @Sendable
    func page(req: Request) async throws -> View {
        let user = try req.auth.require(User.self)
        return try await renderPage(req: req, user: user, profileError: nil)
    }

    @Sendable
    func updateProfile(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let form = try req.content.decode(ProfileForm.self)
        do {
            try await AccountService(db: req.db).updateDisplayName(form.displayName, for: user)
            return req.redirect(to: "/account")
        } catch let error as APIError {
            let response = try await renderPage(req: req, user: user, profileError: error.message).encodeResponse(for: req)
            response.status = .unprocessableEntity
            return response
        }
    }

    /// Criterion #2: the export downloads straight away as a JSON file.
    @Sendable
    func export(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let export = try await AccountService(db: req.db).exportData(for: user)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601WithFractionalSeconds
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(export)

        var headers = HTTPHeaders()
        headers.contentType = .json
        headers.replaceOrAdd(
            name: .contentDisposition,
            value: "attachment; filename=\"expatevents-data-\(Self.fileDateFormatter.string(from: export.exportedAt)).json\""
        )
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }

    /// Criterion #3, first half: records a pending request. Nothing is
    /// erased until `process-deletions` (or M10's admin site) runs --
    /// see `AccountService.requestDeletion`.
    @Sendable
    func requestDeletion(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let request = try await AccountService(db: req.db).requestDeletion(for: try user.requireID())
        guard req.headers.first(name: "HX-Request") != nil else {
            return req.redirect(to: "/account")
        }
        return try await req.view.render("partials/account-data-fragment", AccountDataFragmentContext(
            hasPendingDeletion: true,
            deletionRequestedOn: request.requestedAt.map(Self.displayDateFormatter.string(from:))
        )).encodeResponse(for: req)
    }

    private func renderPage(req: Request, user: User, profileError: String?) async throws -> View {
        let userID = try user.requireID()
        let subscription = try await PlanLimitsService(db: req.db).subscription(for: userID)
        let pending = try await AccountService(db: req.db).pendingDeletionRequest(for: userID)
        return try await req.view.render("pages/account", AccountPageContext(
            displayName: user.displayName,
            email: user.email,
            photoURL: user.photoURL,
            memberSince: user.createdAt.map(Self.displayDateFormatter.string(from:)) ?? "",
            isPremium: subscription.isActivePremium,
            planLabel: subscription.isActivePremium ? "Premium member" : "Free plan",
            profileError: profileError,
            startEditing: profileError != nil,
            hasPendingDeletion: pending != nil,
            deletionRequestedOn: pending?.requestedAt.map(Self.displayDateFormatter.string(from:))
        ))
    }

    static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
