@testable import App
import ExpatEventsAPI
import XCTVapor
import Fluent

/// M10: the admin site. One test (or more) per acceptance criterion:
/// #1 access, #2 users, #3 suspension, #4 ownership transfer, #5 data
/// requests, #6 exactly one audit row per action (checked in every test
/// that performs an action, including that rejected actions write none).
final class AdminTests: XCTestCase {
    // MARK: - Helpers

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

    private func makeUser(
        db: Database,
        email: String,
        plan: PlanTier = .free,
        role: UserRole = .member,
        displayName: String? = nil
    ) async throws -> User {
        let user = User(
            displayName: displayName ?? email,
            email: email,
            role: role,
            privacyPolicyVersion: LegalVersions.privacyPolicy,
            termsVersion: LegalVersions.terms
        )
        try await user.save(on: db)
        try await Subscription(userID: try user.requireID(), plan: plan, status: .active).save(on: db)
        return user
    }

    private func sessionCookie(for user: User, db: Database) async throws -> String {
        var data = SessionData()
        data["_UserSession"] = try user.requireID().uuidString
        let key = SessionID(string: UUID().uuidString)
        try await SessionRecord(key: key, data: data).create(on: db)
        return "vapor-session=\(key.string)"
    }

    private func auditRows(_ db: Database) async throws -> [AdminAuditLog] {
        try await AdminAuditLog.query(on: db).sort(\.$createdAt).all()
    }

    private func form(_ cookie: String, htmx: Bool = true) -> HTTPHeaders {
        var headers: HTTPHeaders = ["Cookie": cookie, "Content-Type": "application/x-www-form-urlencoded"]
        if htmx { headers.add(name: "HX-Request", value: "true") }
        return headers
    }

    // MARK: - Criterion #1: access

    /// Every admin route: a signed-out visitor is sent to sign in, a
    /// signed-in member gets a 403 with no admin page in it, and only an
    /// admin gets the page. The nav's Admin link shows for admins only.
    func testOnlyAdminsReachAnyAdminRoute() async throws {
        try await withApp { app in
            let member = try await makeUser(db: app.db, email: "member@example.com")
            let admin = try await makeUser(db: app.db, email: "admin@example.com", role: .admin)
            let memberCookie = try await sessionCookie(for: member, db: app.db)
            let adminCookie = try await sessionCookie(for: admin, db: app.db)
            let someID = UUID().uuidString
            let pages = ["/admin", "/admin/users", "/admin/users/table", "/admin/users/\(try member.requireID().uuidString)",
                         "/admin/events", "/admin/groups", "/admin/billing", "/admin/data-requests", "/admin/audit-log"]
            let actions = ["/admin/users/\(someID)/plan", "/admin/users/\(someID)/suspend", "/admin/users/\(someID)/unsuspend",
                           "/admin/events/\(someID)/cancel", "/admin/groups/\(someID)/transfer-owner",
                           "/admin/data-requests/deletions/\(someID)/process", "/admin/data-requests/exports/\(someID)/process"]

            for path in pages {
                try await app.test(.GET, path) { res async in
                    XCTAssertEqual(res.status, .seeOther, "\(path): signed out goes to sign-in")
                    XCTAssertEqual(res.headers.first(name: .location), "/login")
                }
                try await app.test(.GET, path, headers: ["Cookie": memberCookie]) { res async in
                    XCTAssertEqual(res.status, .forbidden, path)
                    XCTAssertFalse(res.body.string.contains("Every change is recorded"), "\(path): no admin page for a member")
                }
                try await app.test(.GET, path, headers: ["Cookie": adminCookie]) { res async in
                    XCTAssertEqual(res.status, .ok, path)
                }
            }
            for path in actions {
                try await app.test(.POST, path, headers: form(memberCookie), body: .init(string: "plan=premium&newOwnerEmail=x%40y.z")) { res async in
                    XCTAssertEqual(res.status, .forbidden, path)
                }
                try await app.test(.POST, path, headers: ["Content-Type": "application/x-www-form-urlencoded"], body: .init(string: "plan=premium")) { res async in
                    XCTAssertEqual(res.status, .seeOther, path)
                }
            }
            let rows = try await auditRows(app.db)
            XCTAssertTrue(rows.isEmpty, "Blocked requests change nothing.")

            // An htmx request after the session expired: the whole page
            // goes to sign-in, rather than the login page being swapped
            // into the admin page.
            try await app.test(.GET, "/admin/users/table", headers: ["HX-Request": "true"]) { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.headers.first(name: "HX-Redirect"), "/login")
                XCTAssertTrue(res.body.string.isEmpty)
            }

            try await app.test(.GET, "/events", headers: ["Cookie": adminCookie]) { res async in
                XCTAssertTrue(res.body.string.contains(#"href="/admin""#))
            }
            try await app.test(.GET, "/events", headers: ["Cookie": memberCookie]) { res async in
                XCTAssertFalse(res.body.string.contains(#"href="/admin""#))
            }
            try await app.test(.GET, "/events") { res async in
                XCTAssertFalse(res.body.string.contains(#"href="/admin""#))
            }
        }
    }

    // MARK: - Criterion #2: users

    /// The Users table searches name and email, case-insensitively and
    /// with LIKE wildcards taken literally; the search box's fragment is
    /// just the table; the detail page shows the account's events and
    /// groups.
    func testUsersTableSearchesAndDetailShowsEventsAndGroups() async throws {
        try await withApp { app in
            let admin = try await makeUser(db: app.db, email: "admin@example.com", role: .admin, displayName: "Ada Admin")
            let cookie = try await sessionCookie(for: admin, db: app.db)
            let zed = try await makeUser(db: app.db, email: "zed@example.com", plan: .premium, displayName: "Zed Quartermaine")
            _ = try await makeUser(db: app.db, email: "yolanda@example.com", displayName: "Yolanda 100% Fun")
            _ = try await makeUser(db: app.db, email: "x_ray@example.com", displayName: "Xavier")
            _ = try await makeUser(db: app.db, email: "xyrus@example.com", displayName: "Xyrus")

            try await app.test(.GET, "/admin/users?q=QUARTER", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Zed Quartermaine"))
                XCTAssertFalse(html.contains("Yolanda"))
                XCTAssertTrue(html.contains(#"value="QUARTER""#), "The search is kept in the box.")
            }
            try await app.test(.GET, "/admin/users/table?q=zed%40example", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Zed Quartermaine"), "Matches email too.")
                XCTAssertFalse(html.contains("<html"), "The search fragment is just the table.")
            }
            try await app.test(.GET, "/admin/users/table?q=%25", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Yolanda"), "A literal % matches only text containing %.")
                XCTAssertFalse(html.contains("Zed Quartermaine"))
            }
            try await app.test(.GET, "/admin/users/table?q=x_r", headers: ["Cookie": cookie]) { res async in
                XCTAssertTrue(res.body.string.contains("Xavier"))
                XCTAssertFalse(res.body.string.contains("Xyrus"), "A literal _ isn't a wildcard (it would match the y).")
            }

            let zedID = try zed.requireID()
            let group = try await GroupService(db: app.db).createGroup(CreateGroupRequest(name: "Zed Club", description: "d"), ownerID: zedID)
            _ = try await EventService(db: app.db).createEvent(CreateEventRequest(
                title: "Zed Picnic", description: "d", category: .food, date: Date().addingTimeInterval(3600),
                cityAddress: "Lisbon", cityLat: 38.72, cityLng: -9.14, venueAddress: "Park", venueLat: 38.72, venueLng: -9.14
            ), hostUserID: zedID)
            try await app.test(.GET, "/admin/users/\(zedID.uuidString)", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(html.contains("Zed Picnic"))
                XCTAssertTrue(html.contains("Zed Club"))
                XCTAssertTrue(html.contains("/groups/\(group.slug)"))
                XCTAssertTrue(html.contains("Premium"))
                XCTAssertTrue(html.contains("Suspend account"))
                XCTAssertFalse(html.contains("Comp Premium"), "Already Premium.")
            }
            try await app.test(.GET, "/admin/users/\(UUID().uuidString)", headers: ["Cookie": cookie]) { res async in
                XCTAssertEqual(res.status, .notFound)
            }
        }
    }

    /// Comping Premium and returning to Free each write one audit row,
    /// change what the plan limits allow, and a repeat (no change) is
    /// rejected with a message and no row. A paid Stripe subscription
    /// can't be downgraded here.
    func testCompingAndRevertingAPlanWritesOneAuditRowEach() async throws {
        try await withApp { app in
            let admin = try await makeUser(db: app.db, email: "admin@example.com", role: .admin)
            let adminID = try admin.requireID()
            let cookie = try await sessionCookie(for: admin, db: app.db)
            let user = try await makeUser(db: app.db, email: "comp@example.com")
            let userID = try user.requireID()
            let path = "/admin/users/\(userID.uuidString)/plan"

            try await app.test(.POST, path, headers: form(cookie), body: .init(string: "plan=premium")) { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.headers.first(name: "HX-Redirect"), "/admin/users/\(userID.uuidString)?notice=plan")
            }
            let comped = try await PlanLimitsService(db: app.db).subscription(for: userID)
            XCTAssertTrue(comped.isActivePremium)
            XCTAssertTrue(comped.grantedByAdmin)
            try await PlanLimitsService(db: app.db).assertCanCreateGroup(ownerID: userID)

            var rows = try await auditRows(app.db)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.$adminUser.id, adminID)
            XCTAssertEqual(rows.first?.action, AdminService.Action.planChanged)
            XCTAssertEqual(rows.first?.targetType, "user")
            XCTAssertEqual(rows.first?.targetID, userID)
            XCTAssertEqual(rows.first?.metadata, ["from": "free", "to": "premium_comped"])

            try await app.test(.POST, path, headers: form(cookie), body: .init(string: "plan=premium")) { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.headers.first(name: "HX-Retarget"), "#admin-alert")
                XCTAssertTrue(res.body.string.contains("already on Premium"))
            }
            rows = try await auditRows(app.db)
            XCTAssertEqual(rows.count, 1, "No change, no audit row.")

            try await app.test(.GET, "/admin/users/\(userID.uuidString)?notice=plan", headers: ["Cookie": cookie]) { res async in
                XCTAssertTrue(res.body.string.contains("Plan updated."))
                XCTAssertTrue(res.body.string.contains("data-admin-notice"))
                XCTAssertTrue(res.body.string.contains("Return to Free"))
            }
            try await app.test(.GET, "/admin/users/\(userID.uuidString)?notice=%3Cscript%3E", headers: ["Cookie": cookie]) { res async in
                // (The layout's own HTML comments mention script tags, so
                // check for the escaped text and the notice box instead.)
                XCTAssertFalse(res.body.string.contains("&lt;script&gt;"), "Only known notices are shown.")
                XCTAssertFalse(res.body.string.contains("data-admin-notice"))
            }

            // Without htmx: a plain redirect.
            try await app.test(.POST, path, headers: form(cookie, htmx: false), body: .init(string: "plan=free")) { res async in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/admin/users/\(userID.uuidString)?notice=plan")
            }
            let free = try await PlanLimitsService(db: app.db).subscription(for: userID)
            XCTAssertFalse(free.isActivePremium)
            XCTAssertFalse(free.grantedByAdmin)
            rows = try await auditRows(app.db)
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows.last?.metadata, ["from": "premium_comped", "to": "free"])

            // A paying subscriber is changed in Stripe, not here.
            let payer = try await makeUser(db: app.db, email: "payer@example.com", plan: .premium)
            let payerSub = try await PlanLimitsService(db: app.db).subscription(for: try payer.requireID())
            payerSub.stripeSubscriptionID = "sub_123"
            try await payerSub.save(on: app.db)
            try await app.test(.POST, "/admin/users/\(try payer.requireID().uuidString)/plan", headers: form(cookie, htmx: false),
                               body: .init(string: "plan=free")) { res async in
                XCTAssertEqual(res.status, .badRequest, "Without htmx, a rejection is an error page.")
                XCTAssertTrue(res.body.string.contains("Cancel the subscription in Stripe"))
            }
            rows = try await auditRows(app.db)
            XCTAssertEqual(rows.count, 2)
        }
    }

    // MARK: - Criterion #3: suspension

    /// After an admin suspends an account it can't sign in (website or
    /// API, by either lookup), its existing session and token stop
    /// working, and restoring it lets it back in. An admin can't suspend
    /// themselves. One audit row per suspend/restore.
    func testSuspendedAccountCannotSignInOrUseExistingSessions() async throws {
        try await withApp { app in
            let admin = try await makeUser(db: app.db, email: "admin@example.com", role: .admin)
            let adminCookie = try await sessionCookie(for: admin, db: app.db)
            let user = try await makeUser(db: app.db, email: "suspend-me@example.com")
            let userID = try user.requireID()
            try await OAuthIdentity(userID: userID, provider: .google, providerUserID: "google-123").save(on: app.db)
            let userCookie = try await sessionCookie(for: user, db: app.db)
            let req = Request(application: app, on: app.eventLoopGroup.any())
            let token = try req.jwt.sign(UserJWTPayload.make(userID: userID))

            try await app.test(.GET, "/account", headers: ["Cookie": userCookie]) { res async in
                XCTAssertEqual(res.status, .ok, "Signed in before the suspension.")
            }

            try await app.test(.POST, "/admin/users/\(userID.uuidString)/suspend", headers: form(adminCookie)) { res async in
                XCTAssertEqual(res.headers.first(name: "HX-Redirect"), "/admin/users/\(userID.uuidString)?notice=suspended")
            }
            let suspended = try await User.find(userID, on: app.db)
            XCTAssertEqual(suspended?.isSuspended, true)
            try await app.test(.GET, "/admin/users/\(userID.uuidString)?notice=suspended", headers: ["Cookie": adminCookie]) { res async in
                XCTAssertTrue(res.body.string.contains("data-suspended-banner"), "The account page says it's suspended, not just the notice.")
                XCTAssertTrue(res.body.string.contains("Restore account"))
            }

            // Signing in again: refused by both lookups, and nothing is linked.
            let auth = AuthService(db: app.db)
            do {
                _ = try await auth.findOrCreateUser(provider: .google, providerUserID: "google-123", email: "suspend-me@example.com", displayName: nil)
                XCTFail("A suspended account must not sign in.")
            } catch let error as APIError {
                XCTAssertEqual(error, AuthService.suspendedError)
                XCTAssertEqual(error.httpStatus, .forbidden)
            }
            do {
                _ = try await auth.findOrCreateUser(provider: .apple, providerUserID: "apple-456", email: "suspend-me@example.com", displayName: nil)
                XCTFail("A suspended account must not sign in through a new provider either.")
            } catch let error as APIError {
                XCTAssertEqual(error, AuthService.suspendedError)
            }
            let identities = try await OAuthIdentity.query(on: app.db).filter(\.$user.$id == userID).count()
            XCTAssertEqual(identities, 1, "The refused Apple sign-in linked nothing.")

            // The session and token they already had stop working.
            try await app.test(.GET, "/account", headers: ["Cookie": userCookie]) { res async in
                XCTAssertNotEqual(res.status, .ok)
            }
            try await app.test(.GET, "/api/v1/me", headers: ["Authorization": "Bearer \(token)"]) { res async in
                XCTAssertEqual(res.status, .unauthorized)
            }

            // Can't suspend yourself.
            try await app.test(.POST, "/admin/users/\(try admin.requireID().uuidString)/suspend", headers: form(adminCookie)) { res async in
                XCTAssertTrue(res.body.string.contains("your own account"))
            }

            try await app.test(.POST, "/admin/users/\(userID.uuidString)/unsuspend", headers: form(adminCookie)) { res async in
                XCTAssertEqual(res.headers.first(name: "HX-Redirect"), "/admin/users/\(userID.uuidString)?notice=unsuspended")
            }
            let back = try await auth.findOrCreateUser(provider: .google, providerUserID: "google-123", email: "suspend-me@example.com", displayName: nil)
            XCTAssertEqual(try back.requireID(), userID, "Restored accounts sign in again.")
            try await app.test(.GET, "/account", headers: ["Cookie": userCookie]) { res async in
                XCTAssertNotEqual(res.status, .ok, "Suspending deleted the old session, so restoring doesn't revive it.")
            }

            let rows = try await auditRows(app.db)
            XCTAssertEqual(rows.map(\.action), [AdminService.Action.suspended, AdminService.Action.unsuspended])
            XCTAssertEqual(rows.map(\.targetID), [userID, userID])
        }
    }

    // MARK: - Criterion #4: ownership transfer

    /// Transferring to a Premium moderator: the group's owner and both
    /// memberships end up right (no duplicate membership), with one audit
    /// row. Transfers to a Free account, someone who already owns a group,
    /// an unknown email or the current owner are refused and change and
    /// log nothing.
    func testTransferringOwnershipSetsBothRolesAndAuditsOnce() async throws {
        try await withApp { app in
            let admin = try await makeUser(db: app.db, email: "admin@example.com", role: .admin)
            let adminID = try admin.requireID()
            let cookie = try await sessionCookie(for: admin, db: app.db)
            let owner = try await makeUser(db: app.db, email: "owner@example.com", plan: .premium)
            let ownerID = try owner.requireID()
            let heir = try await makeUser(db: app.db, email: "heir@example.com", plan: .premium)
            let heirID = try heir.requireID()
            let freeUser = try await makeUser(db: app.db, email: "free@example.com")
            let otherOwner = try await makeUser(db: app.db, email: "other-owner@example.com", plan: .premium)

            let groups = GroupService(db: app.db)
            let group = try await groups.createGroup(CreateGroupRequest(name: "Handover Club", description: "d"), ownerID: ownerID)
            let groupID = try group.requireID()
            _ = try await groups.createGroup(CreateGroupRequest(name: "Other Club", description: "d"), ownerID: try otherOwner.requireID())
            try await groups.join(group, userID: heirID)
            try await groups.promoteModerator(group, memberUserID: heirID, requesterID: ownerID)
            try await groups.join(group, userID: try freeUser.requireID())
            let path = "/admin/groups/\(groupID.uuidString)/transfer-owner"

            for (email, message) in [("free%40example.com", "needs a Premium plan"),
                                     ("other-owner%40example.com", "already owns a group"),
                                     ("nobody%40example.com", "No account uses that email"),
                                     ("owner%40example.com", "already owns this group"),
                                     ("", "Enter the new owner")] {
                try await app.test(.POST, path, headers: form(cookie), body: .init(string: "newOwnerEmail=\(email)")) { res async in
                    XCTAssertEqual(res.status, .ok)
                    XCTAssertTrue(res.body.string.contains(message), "\(email): \(res.body.string)")
                }
            }
            var rows = try await auditRows(app.db)
            XCTAssertTrue(rows.isEmpty)
            let unchanged = try await Group.find(groupID, on: app.db)
            XCTAssertEqual(unchanged?.$owner.id, ownerID)

            try await app.test(.POST, path, headers: form(cookie), body: .init(string: "newOwnerEmail=HEIR%40Example.com")) { res async in
                XCTAssertEqual(res.headers.first(name: "HX-Redirect"), "/admin/groups?notice=transferred")
            }
            let moved = try await Group.find(groupID, on: app.db)
            XCTAssertEqual(moved?.$owner.id, heirID)
            func roles(_ userID: UUID) async throws -> [GroupRole] {
                try await GroupMembership.query(on: app.db)
                    .filter(\.$group.$id == groupID)
                    .filter(\.$user.$id == userID)
                    .all()
                    .map(\.role)
            }
            let heirRoles = try await roles(heirID)
            let ownerRoles = try await roles(ownerID)
            XCTAssertEqual(heirRoles, [.owner], "Exactly one membership, now the owner's.")
            XCTAssertEqual(ownerRoles, [.member])
            let ownerCount = try await GroupMembership.query(on: app.db)
                .filter(\.$group.$id == groupID).filter(\.$role == .owner).count()
            XCTAssertEqual(ownerCount, 1)

            rows = try await auditRows(app.db)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.action, AdminService.Action.ownershipTransferred)
            XCTAssertEqual(rows.first?.$adminUser.id, adminID)
            XCTAssertEqual(rows.first?.targetType, "group")
            XCTAssertEqual(rows.first?.targetID, groupID)
            XCTAssertEqual(rows.first?.metadata, ["fromUserID": ownerID.uuidString, "toUserID": heirID.uuidString])
        }
    }

    /// A group left owned by an erased account (M9) can be handed to
    /// someone who wasn't a member: they get an owner membership and the
    /// tombstone's membership is removed.
    func testTransferringAGroupOwnedByAnErasedAccount() async throws {
        try await withApp { app in
            let admin = try await makeUser(db: app.db, email: "admin@example.com", role: .admin)
            let owner = try await makeUser(db: app.db, email: "leaving@example.com", plan: .premium)
            let ownerID = try owner.requireID()
            let heir = try await makeUser(db: app.db, email: "new-owner@example.com", plan: .premium)
            let heirID = try heir.requireID()
            let group = try await GroupService(db: app.db).createGroup(CreateGroupRequest(name: "Orphan Club", description: "d"), ownerID: ownerID)
            let groupID = try group.requireID()
            let account = AccountService(db: app.db)
            try await account.process(try await account.requestDeletion(for: ownerID))

            let cookie = try await sessionCookie(for: admin, db: app.db)
            try await app.test(.GET, "/admin/groups", headers: ["Cookie": cookie]) { res async in
                XCTAssertTrue(res.body.string.contains("Owner account erased"))
            }
            _ = try await AdminService(db: app.db).transferOwnership(of: groupID, toEmail: "new-owner@example.com", by: try admin.requireID())
            let memberships = try await GroupMembership.query(on: app.db).filter(\.$group.$id == groupID).all()
            XCTAssertEqual(memberships.map(\.$user.id), [heirID])
            XCTAssertEqual(memberships.map(\.role), [.owner])
        }
    }

    // MARK: - Criterion #5: data requests

    /// Pending deletion and export requests are listed; "Erase account
    /// now" erases the account just like `process-deletions` and marks the
    /// request processed; marking an export processed sets it ready. One
    /// audit row each, holding IDs only; repeats are refused.
    func testDataRequestsAreListedAndProcessed() async throws {
        try await withApp { app in
            let admin = try await makeUser(db: app.db, email: "admin@example.com", role: .admin)
            let cookie = try await sessionCookie(for: admin, db: app.db)
            let leaver = try await makeUser(db: app.db, email: "leaver@example.com", displayName: "Lena Leaver")
            let leaverID = try leaver.requireID()
            let request = try await AccountService(db: app.db).requestDeletion(for: leaverID)
            let requestID = try request.requireID()
            let exporter = try await makeUser(db: app.db, email: "exporter@example.com", displayName: "Ezra Exporter")
            let export = DataExportRequest(userID: try exporter.requireID(), status: .pending, downloadToken: "t")
            try await export.save(on: app.db)

            try await app.test(.GET, "/admin/data-requests", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Lena Leaver"))
                XCTAssertTrue(html.contains("days left"), "The 30-day deadline is shown.")
                XCTAssertTrue(html.contains("Ezra Exporter"))
                XCTAssertTrue(html.contains("hx-confirm="), "Erasing asks first.")
            }
            try await app.test(.GET, "/admin", headers: ["Cookie": cookie]) { res async in
                XCTAssertTrue(res.body.string.contains(#"data-stat="pending-deletions">1<"#))
            }

            let processPath = "/admin/data-requests/deletions/\(requestID.uuidString)/process"
            try await app.test(.POST, processPath, headers: form(cookie)) { res async in
                XCTAssertEqual(res.headers.first(name: "HX-Redirect"), "/admin/data-requests?notice=deletion-processed")
            }
            let erased = try await User.find(leaverID, on: app.db)
            XCTAssertNotNil(erased?.erasedAt)
            XCTAssertEqual(erased?.displayName, AccountService.erasedDisplayName)
            let processed = try await DeletionRequest.find(requestID, on: app.db)
            XCTAssertNotNil(processed?.processedAt)

            try await app.test(.POST, processPath, headers: form(cookie)) { res async in
                XCTAssertTrue(res.body.string.contains("already been processed"))
            }
            try await app.test(.POST, "/admin/data-requests/exports/\(try export.requireID().uuidString)/process", headers: form(cookie)) { res async in
                XCTAssertEqual(res.headers.first(name: "HX-Redirect"), "/admin/data-requests?notice=export-processed")
            }
            let ready = try await DataExportRequest.find(try export.requireID(), on: app.db)
            XCTAssertEqual(ready?.status, .ready)

            try await app.test(.GET, "/admin/data-requests", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertFalse(html.contains("Lena Leaver"))
                XCTAssertFalse(html.contains("Ezra Exporter"))
                XCTAssertTrue(html.contains("No pending deletion requests."))
            }

            let rows = try await auditRows(app.db)
            XCTAssertEqual(rows.map(\.action), [AdminService.Action.deletionProcessed, AdminService.Action.exportProcessed])
            XCTAssertEqual(rows.first?.targetID, leaverID)
            XCTAssertEqual(rows.first?.metadata, ["requestID": requestID.uuidString])
            for row in rows {
                XCTAssertFalse(row.metadata.values.contains { $0.contains("@") || $0.contains("Lena") }, "No personal data in the log.")
            }
        }
    }

    // MARK: - Events, dashboard, billing, audit log

    /// Cancelling an event from the admin site, once (a repeat is
    /// refused), returning to the same search; an off-site return target
    /// is ignored. The audit log page then shows the action.
    func testAdminCancelsAnEventAndTheAuditLogShowsIt() async throws {
        try await withApp { app in
            let admin = try await makeUser(db: app.db, email: "admin@example.com", role: .admin, displayName: "Ada Admin")
            let cookie = try await sessionCookie(for: admin, db: app.db)
            let host = try await makeUser(db: app.db, email: "host@example.com", displayName: "Hana Host")
            let event = try await EventService(db: app.db).createEvent(CreateEventRequest(
                title: "Rooftop Drinks", description: "d", category: .drinks, date: Date().addingTimeInterval(3600),
                cityAddress: "Madrid", cityLat: 40.4, cityLng: -3.7, venueAddress: "Roof", venueLat: 40.4, venueLng: -3.7
            ), hostUserID: try host.requireID())
            let eventID = try event.requireID()

            try await app.test(.GET, "/admin/events?q=rooftop", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Rooftop Drinks"))
                XCTAssertTrue(html.contains("Hana Host"))
                XCTAssertTrue(html.contains("Cancel event"))
            }
            let path = "/admin/events/\(eventID.uuidString)/cancel"
            try await app.test(.POST, path, headers: form(cookie), body: .init(string: "returnTo=%2Fadmin%2Fevents%3Fq%3Drooftop%26page%3D1")) { res async in
                XCTAssertEqual(res.headers.first(name: "HX-Redirect"), "/admin/events?q=rooftop&page=1&notice=cancelled")
            }
            let cancelled = try await Event.find(eventID, on: app.db)
            XCTAssertEqual(cancelled?.isCancelled, true)
            try await app.test(.POST, path, headers: form(cookie), body: .init(string: "returnTo=https%3A%2F%2Fevil.example")) { res async in
                XCTAssertTrue(res.body.string.contains("already cancelled"))
            }
            XCTAssertEqual(AdminWebController.safeReturn("https://evil.example", fallback: "/admin/events"), "/admin/events")
            XCTAssertEqual(AdminWebController.safeReturn("//evil.example/admin/", fallback: "/admin/events"), "/admin/events")
            XCTAssertEqual(AdminWebController.safeReturn("/admin/events?q=a", fallback: "/x"), "/admin/events?q=a")

            let rows = try await auditRows(app.db)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.action, AdminService.Action.eventCancelled)
            XCTAssertEqual(rows.first?.targetID, eventID)

            try await app.test(.GET, "/admin/audit-log", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("event.cancelled"))
                XCTAssertTrue(html.contains("Ada Admin"))
                XCTAssertTrue(html.contains("/events/\(eventID.uuidString)"))
            }
        }
    }

    /// Dashboard and Billing counts leave erased accounts out and split
    /// paid from comped Premium.
    func testDashboardAndBillingCounts() async throws {
        try await withApp { app in
            let admin = try await makeUser(db: app.db, email: "admin@example.com", role: .admin)
            let adminID = try admin.requireID()
            let cookie = try await sessionCookie(for: admin, db: app.db)
            _ = try await makeUser(db: app.db, email: "paid@example.com", plan: .premium)
            let comp = try await makeUser(db: app.db, email: "comp@example.com", displayName: "Cleo Comped")
            try await AdminService(db: app.db).setPlan(.premium, for: try comp.requireID(), by: adminID)
            let gone = try await makeUser(db: app.db, email: "gone@example.com", plan: .premium)
            let account = AccountService(db: app.db)
            try await account.process(try await account.requestDeletion(for: try gone.requireID()))

            try await app.test(.GET, "/admin", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains(#"data-stat="users">3<"#), "Admin, paid, comped; not the erased one.")
                XCTAssertTrue(html.contains(#"data-stat="premium">2<"#))
            }
            try await app.test(.GET, "/admin/billing", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains(#"data-stat="free">1<"#))
                XCTAssertTrue(html.contains(#"data-stat="paid">1<"#))
                XCTAssertTrue(html.contains(#"data-stat="comped">1<"#))
                XCTAssertTrue(html.contains("Cleo Comped"))
            }
        }
    }

    /// Review fixes: an email used by two accounts differing only in case
    /// is refused rather than picking one; a deletion request can't be
    /// processed twice (the second call finds it done and changes
    /// nothing); a comped account that once had a Stripe subscription can
    /// still go back to Free.
    func testAmbiguousEmailsDoubleProcessingAndLapsedStripeComps() async throws {
        try await withApp { app in
            let admin = try await makeUser(db: app.db, email: "admin@example.com", role: .admin)
            let adminID = try admin.requireID()
            let owner = try await makeUser(db: app.db, email: "owner@example.com", plan: .premium)
            let group = try await GroupService(db: app.db).createGroup(CreateGroupRequest(name: "Case Club", description: "d"), ownerID: try owner.requireID())
            _ = try await makeUser(db: app.db, email: "Twin@example.com", plan: .premium)
            _ = try await makeUser(db: app.db, email: "twin@example.com", plan: .premium)
            do {
                _ = try await AdminService(db: app.db).transferOwnership(of: try group.requireID(), toEmail: "twin@example.com", by: adminID)
                XCTFail("Two accounts match; neither should get the group.")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "ambiguous_email")
            }

            let leaver = try await makeUser(db: app.db, email: "twice@example.com")
            let account = AccountService(db: app.db)
            let request = try await account.requestDeletion(for: try leaver.requireID())
            let first = try await account.process(request)
            let second = try await account.process(request)
            XCTAssertTrue(first)
            XCTAssertFalse(second, "Already processed: nothing happens the second time.")
            do {
                try await AdminService(db: app.db).processDeletion(try request.requireID(), by: adminID)
                XCTFail("The admin site can't process it again either.")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "no_change")
            }
            let rows = try await AdminAuditLog.query(on: app.db).count()
            XCTAssertEqual(rows, 0)

            let lapsed = try await makeUser(db: app.db, email: "lapsed@example.com")
            let lapsedID = try lapsed.requireID()
            let sub = try await PlanLimitsService(db: app.db).subscription(for: lapsedID)
            sub.stripeSubscriptionID = "sub_old"
            sub.status = .canceled
            try await sub.save(on: app.db)
            try await AdminService(db: app.db).setPlan(.premium, for: lapsedID, by: adminID)
            try await AdminService(db: app.db).setPlan(.free, for: lapsedID, by: adminID)
            let after = try await PlanLimitsService(db: app.db).subscription(for: lapsedID)
            XCTAssertFalse(after.isActivePremium)
        }
    }

    // MARK: - Theme: dashboard charts, filters, row actions

    /// The dashboard draws its charts from real counts (server-side SVG),
    /// and the range buttons fetch just the chart.
    func testDashboardChartsAndActivityRanges() async throws {
        try await withApp { app in
            let admin = try await makeUser(db: app.db, email: "admin@example.com", role: .admin)
            let cookie = try await sessionCookie(for: admin, db: app.db)
            let host = try await makeUser(db: app.db, email: "chart-host@example.com")
            for title in ["Tapas Night", "Wine Walk"] {
                _ = try await EventService(db: app.db).createEvent(CreateEventRequest(
                    title: title, description: "d", category: .food, date: Date().addingTimeInterval(3 * 24 * 3600),
                    cityAddress: "Madrid", cityLat: 40.4, cityLng: -3.7, venueAddress: "Bar", venueLat: 40.4, venueLng: -3.7
                ), hostUserID: try host.requireID())
            }

            try await app.test(.GET, "/admin", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(html.contains("Sign-ups &amp; events"))
                XCTAssertTrue(html.contains("<polyline"), "The activity line is drawn.")
                XCTAssertTrue(html.contains("2 events created"), "Both events count this week.")
                XCTAssertTrue(html.contains("Food · 2 events"), "The category chart counts them.")
                XCTAssertTrue(html.contains(#"data-stat="events-this-week">2<"#))
            }
            for range in ["4w", "12w", "1y"] {
                try await app.test(.GET, "/admin/activity?range=\(range)", headers: ["Cookie": cookie]) { res async in
                    let html = res.body.string
                    XCTAssertEqual(res.status, .ok)
                    XCTAssertTrue(html.contains(#"id="admin-activity""#))
                    XCTAssertFalse(html.contains("<html"), "Just the chart.")
                    XCTAssertTrue(html.contains(#"aria-pressed="true">\#(range)<"#), "\(range) is shown as selected.")
                }
            }
        }
    }

    /// Chart arithmetic: round axis maxima, a flat sparkline for no data,
    /// ring segments that add up to the whole circle.
    func testChartGeometry() {
        XCTAssertEqual(AdminCharts.niceMax(0), 4)
        XCTAssertEqual(AdminCharts.niceMax(5), 8)
        XCTAssertEqual(AdminCharts.niceMax(38), 40)
        XCTAssertEqual(AdminCharts.niceMax(120), 200)
        XCTAssertEqual(AdminCharts.sparkline([]), "0,24 120,24")
        XCTAssertEqual(AdminCharts.sparkline([0, 2]), "0.0,25.0 120.0,4.0")
        XCTAssertTrue(AdminCharts.donut([(0, "a"), (0, "b")]).isEmpty)
        let ring = AdminCharts.donut([(3, "a"), (1, "b")])
        XCTAssertEqual(ring.count, 2)
        XCTAssertEqual(ring[1].dashOffset, AdminCharts.fixed(-2 * Double.pi * 70 * 0.75))
        XCTAssertEqual(AdminCharts.number(1284), "1,284")
        XCTAssertEqual(AdminWebController.withNotice("/admin/users?filter=suspended&notice=plan", "suspended"),
                       "/admin/users?filter=suspended&notice=suspended")
        XCTAssertEqual(AdminWebController.initials("Alice Nakamura"), "AN")
    }

    /// The Users filters narrow the table (and count each filter), and a
    /// row's Suspend button returns to the same filtered list.
    func testUserFiltersAndRowActionsReturnToTheList() async throws {
        try await withApp { app in
            let admin = try await makeUser(db: app.db, email: "admin@example.com", role: .admin, displayName: "Ada Admin")
            let cookie = try await sessionCookie(for: admin, db: app.db)
            _ = try await makeUser(db: app.db, email: "paid@example.com", plan: .premium, displayName: "Paula Paid")
            let target = try await makeUser(db: app.db, email: "target@example.com", displayName: "Tariq Target")

            try await app.test(.GET, "/admin/users?filter=premium", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Paula Paid"))
                XCTAssertFalse(html.contains("Tariq Target"))
                XCTAssertTrue(html.contains("Suspend"), "Row actions are on the table.")
            }
            try await app.test(.GET, "/admin/users/table?filter=admins", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Ada Admin"))
                XCTAssertFalse(html.contains("Paula Paid"))
                XCTAssertTrue(html.contains(#"name="filter" value="admins""#), "The search box keeps the filter.")
            }

            let returnTo = "/admin/users?filter=suspended&page=1"
            try await app.test(.POST, "/admin/users/\(try target.requireID().uuidString)/suspend", headers: form(cookie),
                               body: .init(string: "returnTo=%2Fadmin%2Fusers%3Ffilter%3Dsuspended%26page%3D1")) { res async in
                XCTAssertEqual(res.headers.first(name: "HX-Redirect"), returnTo + "&notice=suspended")
            }
            try await app.test(.GET, "/admin/users?filter=suspended", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Tariq Target"))
                XCTAssertFalse(html.contains("Paula Paid"))
                XCTAssertTrue(html.contains("Restore account"))
            }

            // A page past the end (its last row was just acted on) shows
            // the last page that exists, not an empty table.
            try await app.test(.GET, "/admin/users?filter=suspended&page=3", headers: ["Cookie": cookie]) { res async in
                XCTAssertTrue(res.body.string.contains("Tariq Target"))
                XCTAssertTrue(res.body.string.contains("Showing 1–1 of 1"))
            }

            // "All" is live accounts only; erased ones have their own filter.
            let account = AccountService(db: app.db)
            try await account.process(try await account.requestDeletion(for: try target.requireID()))
            try await app.test(.GET, "/admin/users", headers: ["Cookie": cookie]) { res async in
                XCTAssertFalse(res.body.string.contains(AccountService.erasedDisplayName))
            }
            try await app.test(.GET, "/admin/users?filter=erased", headers: ["Cookie": cookie]) { res async in
                XCTAssertTrue(res.body.string.contains(AccountService.erasedDisplayName))
            }
        }
    }

    // MARK: - make-admin

    /// `make-admin` promotes an existing account by email (any case),
    /// refuses an unknown one, and won't revoke the last admin.
    func testMakeAdminCommand() async throws {
        try await withApp { app in
            let first = try await makeUser(db: app.db, email: "first@example.com")
            let message = try await MakeAdminCommand.setAdmin(true, email: "FIRST@example.com", db: app.db)
            XCTAssertEqual(message, "first@example.com is now an admin.")
            let promoted = try await User.find(try first.requireID(), on: app.db)
            XCTAssertEqual(promoted?.role, .admin)
            let again = try await MakeAdminCommand.setAdmin(true, email: "first@example.com", db: app.db)
            XCTAssertEqual(again, "first@example.com is already an admin.")

            do {
                _ = try await MakeAdminCommand.setAdmin(false, email: "first@example.com", db: app.db)
                XCTFail("The last admin can't be revoked.")
            } catch {}
            do {
                _ = try await MakeAdminCommand.setAdmin(true, email: "nobody@example.com", db: app.db)
                XCTFail("An unknown email is refused.")
            } catch {}

            let suspendedAdmin = try await makeUser(db: app.db, email: "second@example.com", role: .admin)
            suspendedAdmin.isSuspended = true
            try await suspendedAdmin.save(on: app.db)
            do {
                _ = try await MakeAdminCommand.setAdmin(false, email: "first@example.com", db: app.db)
                XCTFail("A suspended admin doesn't count: first is still the only active one.")
            } catch {}
            suspendedAdmin.isSuspended = false
            try await suspendedAdmin.save(on: app.db)
            let revoked = try await MakeAdminCommand.setAdmin(false, email: "first@example.com", db: app.db)
            XCTAssertEqual(revoked, "first@example.com is no longer an admin.")
        }
    }
}
