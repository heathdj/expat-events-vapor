@testable import App
import ExpatEventsAPI
import XCTVapor
import Fluent

/// Theme PR 3: a group's owner and moderators edit its profile and logo;
/// the logo shows on the group's events, with a default group icon when
/// there's none.
final class GroupProfileTests: XCTestCase {
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

    private func makeUser(db: Database, email: String, plan: PlanTier = .free) async throws -> User {
        let user = User(displayName: email, email: email,
                        privacyPolicyVersion: LegalVersions.privacyPolicy, termsVersion: LegalVersions.terms)
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

    private func multipart(_ data: Data) -> (HTTPHeaders, ByteBuffer) {
        let boundary = "GroupBoundary\(UUID().uuidString.prefix(8))"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"logo\"; filename=\"logo.png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return (["Content-Type": "multipart/form-data; boundary=\(boundary)"], ByteBuffer(bytes: body))
    }

    /// An owner (Premium), a moderator, a plain member and an outsider.
    private struct Cast {
        let group: Group
        let owner: User
        let moderator: User
        let ownerCookie: String
        let moderatorCookie: String
        let memberCookie: String
        let outsiderCookie: String
    }

    private func makeCast(_ app: Application) async throws -> Cast {
        let owner = try await makeUser(db: app.db, email: "owner@example.com", plan: .premium)
        let moderator = try await makeUser(db: app.db, email: "moderator@example.com")
        let member = try await makeUser(db: app.db, email: "member@example.com")
        let outsider = try await makeUser(db: app.db, email: "outsider@example.com")
        let groups = GroupService(db: app.db)
        let group = try await groups.createGroup(CreateGroupRequest(name: "Lisbon Hikers", description: "Weekend walks."), ownerID: try owner.requireID())
        try await groups.join(group, userID: try moderator.requireID())
        try await groups.promoteModerator(group, memberUserID: try moderator.requireID(), requesterID: try owner.requireID())
        try await groups.join(group, userID: try member.requireID())
        return Cast(
            group: group,
            owner: owner,
            moderator: moderator,
            ownerCookie: try await sessionCookie(for: owner, db: app.db),
            moderatorCookie: try await sessionCookie(for: moderator, db: app.db),
            memberCookie: try await sessionCookie(for: member, db: app.db),
            outsiderCookie: try await sessionCookie(for: outsider, db: app.db)
        )
    }

    /// Owner and moderators can open the edit page and save; members,
    /// outsiders and visitors can't. The slug stays the same on a rename,
    /// and bad input comes back with a message.
    func testOnlyOwnerAndModeratorsEditTheGroup() async throws {
        try await withApp { app in
            let cast = try await makeCast(app)
            let slug = cast.group.slug
            let groupID = try cast.group.requireID()
            let editPage = "/groups/\(slug)/edit"

            for cookie in [cast.ownerCookie, cast.moderatorCookie] {
                try await app.test(.GET, editPage, headers: ["Cookie": cookie]) { res async in
                    XCTAssertEqual(res.status, .ok)
                    XCTAssertTrue(res.body.string.contains(#"value="Lisbon Hikers""#))
                }
            }
            for cookie in [cast.memberCookie, cast.outsiderCookie] {
                try await app.test(.GET, editPage, headers: ["Cookie": cookie]) { res async in
                    XCTAssertEqual(res.status, .forbidden)
                }
            }
            try await app.test(.GET, editPage) { res async in
                XCTAssertEqual(res.status, .seeOther, "Visitors are sent to sign in.")
            }

            try await app.test(.GET, editPage, headers: ["Cookie": cast.ownerCookie]) { res async in
                XCTAssertTrue(res.body.string.contains(#"id="group-visibility""#), "The owner chooses who can join.")
            }
            try await app.test(.GET, editPage, headers: ["Cookie": cast.moderatorCookie]) { res async in
                XCTAssertFalse(res.body.string.contains(#"id="group-visibility""#))
                XCTAssertTrue(res.body.string.contains("data-visibility-readonly"))
            }

            let form = "name=Lisbon+Trail+Club&description=Longer+walks+now."
            try await app.test(.POST, "/groups/\(groupID.uuidString)/edit",
                               headers: ["Cookie": cast.memberCookie, "Content-Type": "application/x-www-form-urlencoded"],
                               body: .init(string: form)) { res async in
                XCTAssertEqual(res.status, .forbidden)
            }
            try await app.test(.POST, "/groups/\(groupID.uuidString)/edit",
                               headers: ["Cookie": cast.moderatorCookie, "Content-Type": "application/x-www-form-urlencoded"],
                               body: .init(string: form)) { res async in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/groups/\(slug)/edit?saved=details")
            }
            let saved = try await Group.find(groupID, on: app.db)
            XCTAssertEqual(saved?.name, "Lisbon Trail Club")
            XCTAssertEqual(saved?.groupDescription, "Longer walks now.")
            XCTAssertEqual(saved?.slug, slug, "Links to the group keep working.")

            // Only the owner changes who can join.
            try await app.test(.POST, "/groups/\(groupID.uuidString)/edit",
                               headers: ["Cookie": cast.moderatorCookie, "Content-Type": "application/x-www-form-urlencoded"],
                               body: .init(string: form + "&visibility=inviteOnly")) { res async in
                XCTAssertEqual(res.status, .unprocessableEntity)
                XCTAssertTrue(res.body.string.contains("can change who can join"))
            }
            let stillPublic = try await Group.find(groupID, on: app.db)
            XCTAssertEqual(stillPublic?.visibility, .public)
            try await app.test(.POST, "/groups/\(groupID.uuidString)/edit",
                               headers: ["Cookie": cast.ownerCookie, "Content-Type": "application/x-www-form-urlencoded"],
                               body: .init(string: form + "&visibility=bogus")) { res async in
                XCTAssertEqual(res.status, .badRequest)
            }
            try await app.test(.POST, "/groups/\(groupID.uuidString)/edit",
                               headers: ["Cookie": cast.ownerCookie, "Content-Type": "application/x-www-form-urlencoded"],
                               body: .init(string: form + "&visibility=inviteOnly")) { res async in
                XCTAssertEqual(res.status, .seeOther)
            }
            let inviteOnly = try await Group.find(groupID, on: app.db)
            XCTAssertEqual(inviteOnly?.visibility, .inviteOnly)

            try await app.test(.POST, "/groups/\(groupID.uuidString)/edit",
                               headers: ["Cookie": cast.ownerCookie, "Content-Type": "application/x-www-form-urlencoded"],
                               body: .init(string: "name=++&description=Still+here&visibility=public")) { res async in
                XCTAssertEqual(res.status, .unprocessableEntity)
                XCTAssertTrue(res.body.string.contains("between 1 and 80 characters"))
            }
            let unchanged = try await Group.find(groupID, on: app.db)
            XCTAssertEqual(unchanged?.name, "Lisbon Trail Club")

            try await app.test(.GET, "/groups/\(slug)", headers: ["Cookie": cast.moderatorCookie]) { res async in
                XCTAssertTrue(res.body.string.contains("Edit group"))
            }
            try await app.test(.GET, "/groups/\(slug)", headers: ["Cookie": cast.memberCookie]) { res async in
                XCTAssertFalse(res.body.string.contains("Edit group"))
            }

            // A moderator who's been removed is refused.
            try await GroupService(db: app.db).demoteModerator(cast.group, memberUserID: try cast.moderator.requireID(),
                                                               requesterID: try cast.owner.requireID())
            try await app.test(.POST, "/groups/\(groupID.uuidString)/edit",
                               headers: ["Cookie": cast.moderatorCookie, "Content-Type": "application/x-www-form-urlencoded"],
                               body: .init(string: "name=Taken+Over&description=x")) { res async in
                XCTAssertEqual(res.status, .forbidden)
            }

            // Creating a group follows the same rules.
            let longName = String(repeating: "a", count: 81)
            let founder = try await makeUser(db: app.db, email: "founder@example.com", plan: .premium)
            do {
                _ = try await GroupService(db: app.db).createGroup(CreateGroupRequest(name: longName, description: "d"),
                                                                   ownerID: try founder.requireID())
                XCTFail("An 81-character name is refused.")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "invalid_group_name")
            }
        }
    }

    /// A moderator uploads a logo (cleaned like profile photos); it shows on
    /// the group page, its events in the list and the event page; replacing
    /// and removing it delete the old file; members can't upload; without a
    /// logo the default group icon shows.
    func testGroupLogoShowsOnItsEventsAndCanBeReplacedAndRemoved() async throws {
        try await withApp { app in
            let cast = try await makeCast(app)
            let groupID = try cast.group.requireID()
            let event = try await EventService(db: app.db).createEvent(CreateEventRequest(
                title: "Sintra Ridge Walk", description: "d", category: .travel, date: Date().addingTimeInterval(3 * 24 * 3600),
                cityAddress: "Lisbon", cityLat: 38.72, cityLng: -9.14, venueAddress: "Sintra", venueLat: 38.8, venueLng: -9.39,
                hostGroupID: groupID
            ), hostUserID: try cast.owner.requireID())
            let eventID = try event.requireID()
            let member = try await makeUser(db: app.db, email: "host@example.com")
            _ = try await EventService(db: app.db).createEvent(CreateEventRequest(
                title: "Coffee Meetup", description: "d", category: .food, date: Date().addingTimeInterval(2 * 24 * 3600),
                cityAddress: "Lisbon", cityLat: 38.72, cityLng: -9.14, venueAddress: "Cafe", venueLat: 38.72, venueLng: -9.14
            ), hostUserID: try member.requireID())

            try await app.test(.GET, "/events") { res async in
                XCTAssertTrue(res.body.string.contains(#"src="/design/group-placeholder.png" alt="" class="ev-host-img" data-host-logo"#),
                              "No logo yet: the default group icon.")
                XCTAssertTrue(res.body.string.contains(#"src="/design/avatar-placeholder.png" alt="" class="ev-host-img">"#),
                              "A member's own event still shows their avatar.")
            }
            try await app.test(.GET, "/events/\(eventID.uuidString)") { res async in
                XCTAssertTrue(res.body.string.contains(#"src="/design/group-placeholder.png" alt="" class="h-8 w-8 rounded-full object-cover" data-host-logo"#))
            }

            var (headers, body) = multipart(PhotoTests.png(extra: [PhotoTests.pngChunk("tEXt", Array("Author\0Someone".utf8))]))
            headers.add(name: "Cookie", value: cast.memberCookie)
            try await app.test(.POST, "/groups/\(groupID.uuidString)/logo", headers: headers, body: body) { res async in
                XCTAssertEqual(res.status, .forbidden)
            }

            (headers, body) = multipart(PhotoTests.png(extra: [PhotoTests.pngChunk("tEXt", Array("Author\0Someone".utf8))]))
            headers.add(name: "Cookie", value: cast.moderatorCookie)
            try await app.test(.POST, "/groups/\(groupID.uuidString)/logo", headers: headers, body: body) { res async in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/groups/\(cast.group.slug)/edit?saved=logo#logo")
            }
            let withLogo = try await Group.find(groupID, on: app.db)
            let logo = try XCTUnwrap(withLogo?.avatarURL)
            XCTAssertTrue(logo.hasPrefix("/uploads/avatars/"))
            let file = try XCTUnwrap(app.photoStorage.localFile(named: String(logo.dropFirst("/uploads/avatars/".count))))
            let stored = try Data(contentsOf: URL(fileURLWithPath: file))
            XCTAssertNil(stored.range(of: Data("Someone".utf8)), "Stored cleaned, like profile photos.")

            let summary = try await EventService(db: app.db).summaryDTO(for: event, requesterID: nil)
            XCTAssertTrue(summary.isGroupHosted)
            XCTAssertEqual(summary.hostPhotoURL, logo)
            try await app.test(.GET, "/events") { res async in
                XCTAssertTrue(res.body.string.contains(#"src="\#(logo)" alt="" class="ev-host-img" data-host-logo"#))
            }
            try await app.test(.GET, "/events/\(eventID.uuidString)") { res async in
                XCTAssertTrue(res.body.string.contains(#"src="\#(logo)""#), "On the event page too.")
            }
            try await app.test(.GET, "/groups/\(cast.group.slug)") { res async in
                XCTAssertTrue(res.body.string.contains(#"src="\#(logo)""#))
            }

            (headers, body) = multipart(PhotoTests.png(width: 128, height: 128))
            headers.add(name: "Cookie", value: cast.ownerCookie)
            try await app.test(.POST, "/groups/\(groupID.uuidString)/logo", headers: headers, body: body) { res async in
                XCTAssertEqual(res.status, .seeOther)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file), "The replaced logo is deleted.")

            (headers, body) = multipart(Data("not an image".utf8))
            headers.add(name: "Cookie", value: cast.ownerCookie)
            try await app.test(.POST, "/groups/\(groupID.uuidString)/logo", headers: headers, body: body) { res async in
                XCTAssertEqual(res.status, .unprocessableEntity)
                XCTAssertTrue(res.body.string.contains("Upload a JPEG, PNG or WebP image."))
            }

            try await app.test(.POST, "/groups/\(groupID.uuidString)/logo/remove", headers: ["Cookie": cast.memberCookie]) { res async in
                XCTAssertEqual(res.status, .forbidden)
            }
            let beforeRemove = try await Group.find(groupID, on: app.db)
            let replaced = try XCTUnwrap(beforeRemove?.avatarURL)
            try await app.test(.POST, "/groups/\(groupID.uuidString)/logo/remove",
                               headers: ["Cookie": cast.ownerCookie, "HX-Request": "true"]) { res async in
                XCTAssertEqual(res.headers.first(name: "HX-Redirect"), "/groups/\(cast.group.slug)/edit?saved=logo-removed#logo")
            }
            let removed = try await Group.find(groupID, on: app.db)
            XCTAssertNil(removed?.avatarURL)
            let replacedFile = app.photoStorage.localFile(named: String(replaced.dropFirst("/uploads/avatars/".count)))
            XCTAssertFalse(replacedFile.map { FileManager.default.fileExists(atPath: $0) } ?? true, "Removing deletes the file.")
        }
    }

    /// Payloads without `isGroupHosted` (an older server) still decode.
    func testEventSummaryDecodesWithoutIsGroupHosted() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"T","category":"food","date":0,"cityAddress":"Lisbon","hostDisplayName":"H","attendeeCount":1,"visibility":"public","isCancelled":false}"#
        let summary = try JSONDecoder().decode(EventSummaryDTO.self, from: Data(json.utf8))
        XCTAssertFalse(summary.isGroupHosted)
        XCTAssertNil(summary.timeZone)
        let roundTrip = try JSONDecoder().decode(EventSummaryDTO.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(roundTrip, summary)
    }

    /// The default group icon is served alongside the default avatar.
    func testDefaultGroupIconIsServed() async throws {
        try await withApp { app in
            try await app.test(.GET, "/design/group-placeholder.png") { res async in
                XCTAssertEqual(res.status, .ok)
            }
        }
    }
}
