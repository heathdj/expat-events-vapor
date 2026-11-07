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
        /// Theme PR 2: the profile photo card.
        let photoOptions: [PhotoOption]
        let hasUpload: Bool
        let photoError: String?
        let photoNotice: String?
        /// Search & filters PR: kilometres or miles.
        let unitOptions: [UnitOption]
        let preferencesNotice: String?
    }

    struct UnitOption: Encodable {
        let value: String
        let label: String
        let isSelected: Bool
    }

    struct PreferencesForm: Content {
        let distanceUnit: String
    }

    /// One choice in the photo card. `previewURL` is what it would show;
    /// unavailable choices explain why instead of offering a radio button.
    struct PhotoOption: Encodable {
        let value: String
        let label: String
        let detail: String
        let previewURL: String?
        let isSelected: Bool
        let isAvailable: Bool
    }

    struct PhotoSourceForm: Content {
        let source: String
    }

    struct PhotoUploadForm: Content {
        let photo: File?
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
        // Theme PR 2. The upload route accepts a larger body than Vapor's
        // 16 KB default: room above the service's 2 MB limit, so a too-big
        // photo gets the friendly message rather than Vapor's bare 413.
        authenticated.on(.POST, "account", "photo", body: .collect(maxSize: "10mb"), use: uploadPhoto)
        authenticated.post("account", "photo", "source", use: choosePhotoSource)
        authenticated.post("account", "preferences", use: updatePreferences)
        authenticated.post("account", "photo", "remove", use: removePhoto)
    }

    @Sendable
    func uploadPhoto(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let form = try? req.content.decode(PhotoUploadForm.self)
        let data = form?.photo.map { Data($0.data.readableBytesView) } ?? Data()
        return try await photoAction(req: req, user: user, notice: "uploaded") {
            try await req.profilePhotos.upload(data, for: user)
        }
    }

    @Sendable
    func choosePhotoSource(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        guard let source = (try? req.content.decode(PhotoSourceForm.self)).flatMap({ PhotoSource(rawValue: $0.source) }) else {
            return try await renderPage(req: req, user: user, profileError: nil, photoError: "Choose a photo.")
                .encodeResponse(status: .badRequest, for: req)
        }
        return try await photoAction(req: req, user: user, notice: "chosen") {
            try await req.profilePhotos.choose(source, for: user)
        }
    }

    @Sendable
    func removePhoto(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        return try await photoAction(req: req, user: user, notice: "removed") {
            try await req.profilePhotos.removeUpload(for: user)
        }
    }

    /// Success redirects back with a fixed notice; a rejected photo
    /// re-renders the page with the reason.
    private func photoAction(req: Request, user: User, notice: String, _ action: () async throws -> Void) async throws -> Response {
        do {
            try await action()
        } catch let error as APIError {
            return try await renderPage(req: req, user: user, profileError: nil, photoError: error.message)
                .encodeResponse(status: .unprocessableEntity, for: req)
        }
        let target = "/account?photo=\(notice)#photo"
        // "Remove" posts over htmx (for its hx-confirm): send the whole
        // page there rather than swapping the account page into the form.
        if req.headers.first(name: "HX-Request") != nil {
            let response = Response(status: .ok)
            response.headers.replaceOrAdd(name: "HX-Redirect", value: target)
            return response
        }
        return req.redirect(to: target)
    }

    static let photoNotices = [
        "uploaded": "Photo uploaded. It's now your profile photo.",
        "chosen": "Profile photo updated.",
        "removed": "Uploaded photo removed.",
    ]

    @Sendable
    func page(req: Request) async throws -> View {
        let user = try req.auth.require(User.self)
        return try await renderPage(req: req, user: user, profileError: nil, photoError: nil)
    }

    @Sendable
    func updateProfile(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let form = try req.content.decode(ProfileForm.self)
        do {
            try await AccountService(db: req.db).updateDisplayName(form.displayName, for: user)
            return req.redirect(to: "/account")
        } catch let error as APIError {
            let response = try await renderPage(req: req, user: user, profileError: error.message, photoError: nil).encodeResponse(for: req)
            response.status = .unprocessableEntity
            return response
        }
    }

    /// Search & filters PR: the distance unit `/events` uses.
    @Sendable
    func updatePreferences(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        guard let form = try? req.content.decode(PreferencesForm.self),
              let unit = DistanceUnit(rawValue: form.distanceUnit) else {
            throw Abort(.badRequest)
        }
        user.distanceUnit = unit
        try await user.save(on: req.db)
        return req.redirect(to: "/account?prefs=saved#preferences")
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

    private func renderPage(req: Request, user: User, profileError: String?, photoError: String?) async throws -> View {
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
            deletionRequestedOn: pending?.requestedAt.map(Self.displayDateFormatter.string(from:)),
            photoOptions: Self.photoOptions(for: user),
            hasUpload: user.uploadedPhotoPath != nil,
            photoError: photoError,
            photoNotice: (try? req.query.get(String.self, at: "photo")).flatMap { Self.photoNotices[$0] },
            unitOptions: DistanceUnit.allCases.map {
                UnitOption(value: $0.rawValue, label: $0.label, isSelected: $0 == user.distanceUnit)
            },
            preferencesNotice: (try? req.query.get(String.self, at: "prefs")) == "saved" ? "Preferences saved." : nil
        ))
    }

    /// Automatic first, then each source (available or not, so members see
    /// what they could use), then the default icon.
    static func photoOptions(for user: User) -> [PhotoOption] {
        let available = Dictionary(ProfilePhotoService.available(user).map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
        // A chosen source that's no longer available (say, the upload was
        // removed) falls back to automatic, so that's what shows as chosen.
        let chosen = user.photoSource ?? .automatic
        let selected: PhotoSource = (chosen == .automatic || chosen == .none || available[chosen] != nil) ? chosen : .automatic
        let automatic = ProfilePhotoService.available(user).first(where: { $0.0 != .gravatar })?.1
        func option(_ source: PhotoSource, _ label: String, detail: String) -> PhotoOption {
            let url = available[source]
            return PhotoOption(value: source.rawValue, label: label, detail: detail,
                               previewURL: url, isSelected: selected == source && url != nil, isAvailable: url != nil)
        }
        // Gravatar is opt-in, so it's always offered: choosing it is what
        // asks gravatar.com (and says so if there's none).
        let gravatarURL = available[.gravatar]
        let gravatar = PhotoOption(
            value: PhotoSource.gravatar.rawValue, label: "Gravatar",
            detail: "The Gravatar for your email address. Choosing it asks gravatar.com, and visitors' browsers load it from there.",
            previewURL: gravatarURL, isSelected: selected == .gravatar && gravatarURL != nil, isAvailable: true
        )
        return [
            PhotoOption(value: PhotoSource.automatic.rawValue, label: "Automatic",
                        detail: "Your Google photo, then your uploaded photo, then the default.",
                        previewURL: automatic, isSelected: selected == .automatic, isAvailable: true),
            option(.google, "Google photo", detail: "From your Google account, updated each time you sign in with Google."),
            gravatar,
            option(.upload, "Uploaded photo", detail: "The photo you uploaded below."),
            PhotoOption(value: PhotoSource.none.rawValue, label: "Default icon", detail: "Don't show a photo.",
                        previewURL: nil, isSelected: selected == .none, isAvailable: true),
        ]
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
