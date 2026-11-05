@testable import App
import ExpatEventsAPI
import XCTVapor
import Fluent

/// Theme foundation: the shared layout's nav, account menu, footer and
/// avatar helper.
final class ThemeTests: XCTestCase {
    func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await app.autoMigrate()
            try await test(app)
            try await app.autoRevert()
        } catch {
            try await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func makeUser(db: Database, email: String, displayName: String, photoURL: String? = nil, role: UserRole = .member) async throws -> User {
        let user = User(displayName: displayName, email: email, photoURL: photoURL, role: role,
                        privacyPolicyVersion: LegalVersions.privacyPolicy, termsVersion: LegalVersions.terms)
        try await user.save(on: db)
        try await Subscription(userID: try user.requireID(), plan: .free, status: .active).save(on: db)
        return user
    }

    private func sessionCookie(for user: User, db: Database) async throws -> String {
        var data = SessionData()
        data["_UserSession"] = try user.requireID().uuidString
        let key = SessionID(string: UUID().uuidString)
        try await SessionRecord(key: key, data: data).create(on: db)
        return "vapor-session=\(key.string)"
    }

    /// Only https URLs and site paths are used as photos; anything else
    /// (missing, http, protocol-relative, javascript:) shows the default.
    func testAvatarURLOnlyAllowsSafePhotoURLs() {
        let placeholder = AvatarURLTag.placeholder
        XCTAssertEqual(AvatarURLTag.resolve(nil), placeholder)
        XCTAssertEqual(AvatarURLTag.resolve(""), placeholder)
        XCTAssertEqual(AvatarURLTag.resolve("https://lh3.googleusercontent.com/a/photo"), "https://lh3.googleusercontent.com/a/photo")
        XCTAssertEqual(AvatarURLTag.resolve("/uploads/avatars/abc.jpg"), "/uploads/avatars/abc.jpg")
        XCTAssertEqual(AvatarURLTag.resolve("http://example.com/a.jpg"), placeholder)
        XCTAssertEqual(AvatarURLTag.resolve("//evil.example/a.jpg"), placeholder)
        XCTAssertEqual(AvatarURLTag.resolve("javascript:alert(1)"), placeholder)
        XCTAssertEqual(AvatarURLTag.resolve("/\\evil.example/a.jpg"), placeholder, "Browsers read /\\ as //.")
    }

    /// Visitors get the gradient nav with Sign in and Pricing; a member
    /// gets "+ Create Event" and a user pill with their name and photo (or
    /// the default), whose menu links their profile and account and signs
    /// out. The current section's link is highlighted. Every page has the
    /// footer with the legal links and the real logo.
    func testNavShowsTheRightStateAndHighlightsTheSection() async throws {
        try await withApp { app in
            try await app.test(.GET, "/events") { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains(#"class="app-nav""#))
                XCTAssertTrue(html.contains(">Sign in<"))
                XCTAssertTrue(html.contains(">Pricing<"))
                XCTAssertFalse(html.contains("+ Create Event"))
                XCTAssertTrue(html.contains(#"<a href="/events" class="app-nav-link is-active">Events</a>"#))
                XCTAssertTrue(html.contains(#"<a href="/groups" class="app-nav-link ">Groups</a>"#))
                XCTAssertTrue(html.contains(#"src="/design/logo.png""#))
                XCTAssertTrue(html.contains(#"class="app-footer""#))
                XCTAssertTrue(html.contains(#"href="/privacy""#))
            }

            let member = try await makeUser(db: app.db, email: "nav@example.com", displayName: "Nadia Nav")
            let cookie = try await sessionCookie(for: member, db: app.db)
            try await app.test(.GET, "/groups", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("+ Create Event"))
                XCTAssertTrue(html.contains("Nadia Nav"))
                XCTAssertTrue(html.contains(#"src="/design/avatar-placeholder.png""#), "No photo: the default avatar.")
                XCTAssertTrue(html.contains(#"href="/profile/\#(try member.requireID().uuidString)""#))
                XCTAssertTrue(html.contains(#"action="/logout""#))
                XCTAssertTrue(html.contains(#"<a href="/groups" class="app-nav-link is-active">Groups</a>"#))
                XCTAssertFalse(html.contains(">Sign in<"))
                XCTAssertFalse(html.contains("Admin site"), "Members don't see the admin item.")
            }

            let admin = try await makeUser(db: app.db, email: "nav-admin@example.com", displayName: "Ada Admin",
                                           photoURL: "https://example.com/ada.jpg", role: .admin)
            let adminCookie = try await sessionCookie(for: admin, db: app.db)
            try await app.test(.GET, "/events", headers: ["Cookie": adminCookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains(#"src="https://example.com/ada.jpg""#), "Their own photo in the pill.")
                XCTAssertTrue(html.contains("Admin site"))
                XCTAssertTrue(html.contains(#"<a href="/admin" class="app-nav-link">Admin site</a>"#), "In the phone menu too.")
            }

            // Pages that need sign-in show the signed-in nav.
            try await app.test(.GET, "/groups/new", headers: ["Cookie": cookie]) { res async in
                XCTAssertTrue(res.body.string.contains("+ Create Event"))
                XCTAssertFalse(res.body.string.contains(">Sign in<"))
            }
        }
    }

    /// The real assets are in place: the logo, the default avatar and a
    /// photo for every event category.
    func testDesignAssetsAreServed() async throws {
        try await withApp { app in
            var paths = ["/design/logo.png", "/design/avatar-placeholder.png", "/css/app-theme.css"]
            paths += EventCategory.allCases.map { "/design/categories/\($0.rawValue).jpg" }
            for path in paths {
                try await app.test(.GET, path) { res async in
                    XCTAssertEqual(res.status, .ok, path)
                }
            }
        }
    }

    /// Confirm-dialog PR: every page on the main layout carries the themed
    /// dialog and its script, so hx-confirm questions use it instead of the
    /// browser's box; confirmations carry their own button labels; the
    /// admin site uses the same script with its own dialog.
    func testConfirmationsUseTheThemedDialog() async throws {
        try await withApp { app in
            let member = try await makeUser(db: app.db, email: "dialog@example.com", displayName: "Dana")
            let admin = try await makeUser(db: app.db, email: "dialog-admin@example.com", displayName: "Ada", role: .admin)

            try await app.test(.GET, "/account", headers: ["Cookie": try await sessionCookie(for: member, db: app.db)]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains(#"<dialog class="app-confirm" data-confirm-dialog role="alertdialog"#))
                for part in ["question", "detail", "ok", "cancel"] {
                    XCTAssertTrue(html.contains(#"data-confirm-part="\#(part)""#), "Site dialog has its \(part) part.")
                }
                XCTAssertTrue(html.contains(#"<script src="/js/confirm-dialog.js"></script>"#))
                XCTAssertTrue(html.contains(#"hx-confirm="Delete your ExpatEvents account?""#))
                XCTAssertTrue(html.contains(#"data-confirm-ok="Delete account""#))
            }
            try await app.test(.GET, "/events") { res async in
                XCTAssertTrue(res.body.string.contains("data-confirm-dialog"), "Visitors' pages have it too.")
            }
            try await app.test(.GET, "/admin", headers: ["Cookie": try await sessionCookie(for: admin, db: app.db)]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains(#"<dialog id="admin-confirm" data-confirm-dialog"#))
                for part in ["question", "detail", "ok", "cancel"] {
                    XCTAssertTrue(html.contains(#"data-confirm-part="\#(part)""#), "Admin dialog has its \(part) part.")
                }
                XCTAssertTrue(html.contains(#"<script src="/js/confirm-dialog.js"></script>"#))
                XCTAssertFalse(html.contains("adminConfirmReady"), "The old inline copy is gone.")
            }
            try await app.test(.GET, "/js/confirm-dialog.js") { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(res.body.string.contains("htmx:confirm"))
            }
        }
    }
}
