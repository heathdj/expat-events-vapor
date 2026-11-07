@testable import App
import ExpatEventsAPI
import ExpatEventsGeo
import XCTVapor
import Fluent

/// Event detail PR: the restyled `/events/:id` page, its map picture, the
/// action bar and attendee list swaps, and the chat's markup.
final class EventDetailTests: XCTestCase {
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

    private func makeUser(db: Database, email: String, name: String, plan: PlanTier = .premium) async throws -> User {
        let user = User(displayName: name, email: email,
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

    private func makeEvent(_ app: Application, title: String, host: User, group: Group? = nil,
                           visibility: EventVisibility = .public,
                           venue: (Double, Double) = (38.7223, -9.1393)) async throws -> Event {
        try await EventService(db: app.db).createEvent(CreateEventRequest(
            title: title, description: "Tapas and a language swap.\nAll levels welcome.", category: .food,
            date: Date().addingTimeInterval(3 * 24 * 3600),
            cityAddress: "Lisbon, Portugal", cityLat: 38.7223, cityLng: -9.1393,
            venueAddress: "Cafe A Brasileira, Lisbon", venueLat: venue.0, venueLng: venue.1,
            hostGroupID: try group?.requireID(), visibility: visibility
        ), hostUserID: try host.requireID())
    }

    /// The banner, host, place with its map and link, and who's going.
    func testDetailPageShowsHeroHostPlaceAndPeople() async throws {
        try await withApp { app in
            let host = try await makeUser(db: app.db, email: "host@example.com", name: "Elena Host")
            let guest = try await makeUser(db: app.db, email: "guest@example.com", name: "Marco Guest", plan: .free)
            let event = try await makeEvent(app, title: "Tapas Exchange", host: host)
            let eventID = try event.requireID().uuidString
            _ = try await EventService(db: app.db).join(event, userID: try guest.requireID())

            try await app.test(.GET, "/events/\(eventID)", headers: ["Cookie": try await sessionCookie(for: guest, db: app.db)]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains(#"<a href="/events">Events</a>"#), "Breadcrumb.")
                XCTAssertTrue(html.contains(#"<img src="/design/categories/food.jpg" alt="">"#), "Category photo banner.")
                XCTAssertTrue(html.contains(#"<span class="ed-cat-badge">Food</span>"#))
                XCTAssertTrue(html.contains(#"<a href="/profile/\#(try host.requireID().uuidString)"><b>Elena Host</b></a>"#))
                XCTAssertTrue(html.contains("Tapas and a language swap."))
                XCTAssertTrue(html.contains("data-map-toggle"))
                XCTAssertTrue(html.contains(#"src="/events/\#(eventID)/map.png""#))
                XCTAssertTrue(html.contains("https://www.google.com/maps/search/?api=1&amp;query=38.722300,-9.139300"))
                XCTAssertTrue(html.contains("1 person going"))
                XCTAssertTrue(html.contains(#"<h2 class="ed-side-head" id="ed-host-title">Host</h2>"#), "The host has their own section.")
                XCTAssertTrue(html.contains(#"<a href="/profile/\#(try host.requireID().uuidString)">Elena Host</a>"#))
                XCTAssertTrue(html.contains(#"<span class="ed-tag-you">You</span>"#))
                XCTAssertFalse(html.contains(#"<span class="ed-tag-host">Host</span>"#), "The host isn't going, so isn't tagged in the list.")
                XCTAssertTrue(html.contains(#"id="ed-rsvp" class="btn btn-going""#), "The guest is going.")
                XCTAssertTrue(html.contains(#"data-me="\#(try guest.requireID().uuidString)""#))
                XCTAssertTrue(html.contains(#"<script src="/js/event-chat.js"></script>"#))
            }

            // The chat is for members: a visitor gets a sign-in box, not the
            // messages (user's decision at the checkpoint).
            _ = try await ChatService(db: app.db).send(SendChatMessageRequest(text: "Members only hello"), eventID: try event.requireID(), userID: try guest.requireID())
            try await app.test(.GET, "/events/\(eventID)") { res async in
                let html = res.body.string
                XCTAssertFalse(html.contains("Members only hello"))
                XCTAssertTrue(html.contains("data-chat-signin"))
                XCTAssertFalse(html.contains("data-map-toggle"), "Map pictures are for members.")
                XCTAssertTrue(html.contains("Open in Google Maps"), "Visitors get the free link.")
            }
            try await app.test(.GET, "/events/\(eventID)", headers: ["Cookie": try await sessionCookie(for: host, db: app.db)]) { res async in
                XCTAssertTrue(res.body.string.contains("Members only hello"))
            }

            // No coordinates (an event from before location lookup): no map.
            let old = try await makeEvent(app, title: "Old Meetup", host: host, venue: (0, 0))
            old.cityLat = 0
            old.cityLng = 0
            try await old.save(on: app.db)
            try await app.test(.GET, "/events/\(try old.requireID().uuidString)") { res async in
                let html = res.body.string
                XCTAssertFalse(html.contains("data-map-toggle"))
                XCTAssertTrue(html.contains("Sign in to join"))
                XCTAssertTrue(html.contains("Sign in</a> to see the chat and join in."))
                XCTAssertFalse(html.contains("ws-connect"), "Visitors don't open a chat socket.")
            }
        }
    }

    /// A group's event: the group tag, its logo and a link to the group.
    func testGroupHostedEventLinksTheGroup() async throws {
        try await withApp { app in
            let owner = try await makeUser(db: app.db, email: "owner@example.com", name: "Owner")
            let group = try await GroupService(db: app.db).createGroup(CreateGroupRequest(name: "Lisbon Walkers", description: "Walks."), ownerID: try owner.requireID())
            let event = try await makeEvent(app, title: "Ridge Walk", host: owner, group: group)
            try await app.test(.GET, "/events/\(try event.requireID().uuidString)") { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Hosted by a group"))
                XCTAssertTrue(html.contains(#"<a href="/groups/\#(group.slug)"><b>Lisbon Walkers</b></a>"#))
                XCTAssertTrue(html.contains(#"src="/design/group-placeholder.png" alt="" class="ed-host-img" data-host-logo"#))
                XCTAssertTrue(html.contains("going yet. Be the first!"), "Nobody going: the host is still shown, in its own section.")
                XCTAssertTrue(html.contains(#"<a href="/groups/\#(group.slug)">Lisbon Walkers</a>"#))
            }
        }
    }

    /// On a group's event, its owner and moderators who are going get an
    /// Owner or Moderator pill (user's request at the checkpoint).
    func testGroupRolesShowInTheGoingList() async throws {
        try await withApp { app in
            let owner = try await makeUser(db: app.db, email: "owner@example.com", name: "Olive Owner")
            let moderator = try await makeUser(db: app.db, email: "mod@example.com", name: "Mo Moderator", plan: .free)
            let member = try await makeUser(db: app.db, email: "member@example.com", name: "Mem Member", plan: .free)
            let groups = GroupService(db: app.db)
            let group = try await groups.createGroup(CreateGroupRequest(name: "Lisbon Walkers", description: "Walks."), ownerID: try owner.requireID())
            try await groups.join(group, userID: try moderator.requireID())
            try await groups.promoteModerator(group, memberUserID: try moderator.requireID(), requesterID: try owner.requireID())
            try await groups.join(group, userID: try member.requireID())
            let event = try await makeEvent(app, title: "Ridge Walk", host: owner, group: group)
            let service = EventService(db: app.db)
            for user in [owner, moderator, member] {
                _ = try await service.join(event, userID: try user.requireID())
            }

            try await app.test(.GET, "/events/\(try event.requireID().uuidString)") { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("3 people going"))
                // Each person's own list item.
                let items = html.components(separatedBy: #"<li class="ed-person">"#)
                func item(_ name: String) -> String { items.first { $0.contains(">\(name)</a>") } ?? "" }
                XCTAssertTrue(item("Olive Owner").contains(#"<span class="ed-tag-role">Owner</span>"#))
                XCTAssertTrue(item("Mo Moderator").contains(#"<span class="ed-tag-role">Moderator</span>"#))
                XCTAssertFalse(item("Mem Member").contains("ed-tag-role"), "Plain members get no pill.")
            }

            // A member's own event: no group, so no pills.
            let solo = try await makeEvent(app, title: "Solo Coffee", host: member)
            _ = try await service.join(solo, userID: try owner.requireID())
            try await app.test(.GET, "/events/\(try solo.requireID().uuidString)") { res async in
                XCTAssertFalse(res.body.string.contains("ed-tag-role"))
            }
        }
    }

    /// The map picture: only for people who can see the event, only with
    /// coordinates, never stored, rate-limited.
    func testMapImage() async throws {
        try await withApp { app in
            let host = try await makeUser(db: app.db, email: "host@example.com", name: "Host")
            let event = try await makeEvent(app, title: "Tapas Exchange", host: host)
            let url = "/events/\(try event.requireID().uuidString)/map.png"
            let member = try await makeUser(db: app.db, email: "member@example.com", name: "Member", plan: .free)
            let cookie: HTTPHeaders = ["Cookie": try await sessionCookie(for: member, db: app.db)]

            try await app.test(.GET, url) { res async in
                XCTAssertEqual(res.status, .unauthorized, "Members only: visitors get the free Google Maps link instead.")
            }
            try await app.test(.GET, url, headers: cookie) { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.headers.contentType?.description, "image/png")
                XCTAssertEqual(res.headers.first(name: .cacheControl), "private, max-age=3600")
                XCTAssertEqual(res.headers.first(name: "X-Content-Type-Options"), "nosniff")
                XCTAssertEqual(Data(res.body.readableBytesView), SampleStaticMapProvider.placeholderPNG)
            }

            let noPlace = try await makeEvent(app, title: "Nowhere", host: host, venue: (0, 0))
            noPlace.cityLat = 0
            noPlace.cityLng = 0
            try await noPlace.save(on: app.db)
            try await app.test(.GET, "/events/\(try noPlace.requireID().uuidString)/map.png", headers: cookie) { res async in
                XCTAssertEqual(res.status, .notFound)
            }

            let group = try await GroupService(db: app.db).createGroup(CreateGroupRequest(name: "Secret Supper", description: "Dinners."), ownerID: try host.requireID())
            let secret = try await makeEvent(app, title: "Members Dinner", host: host, group: group, visibility: .private)
            try await app.test(.GET, "/events/\(try secret.requireID().uuidString)/map.png", headers: cookie) { res async in
                XCTAssertEqual(res.status, .notFound, "Not for people who can't see the event.")
            }

            let cancelled = try await makeEvent(app, title: "Called Off", host: host)
            _ = try await EventService(db: app.db).cancelEvent(cancelled, requesterID: try host.requireID())
            try await app.test(.GET, "/events/\(try cancelled.requireID().uuidString)/map.png", headers: cookie) { res async in
                XCTAssertEqual(res.status, .notFound, "No map for a cancelled event.")
            }

            app.mapImageLimiter = KeyedRateLimiter(limit: 2, window: 60)
            for _ in 1...2 {
                try await app.test(.GET, url, headers: cookie) { res async in XCTAssertEqual(res.status, .ok) }
            }
            try await app.test(.GET, url, headers: cookie) { res async in
                XCTAssertEqual(res.status, .tooManyRequests)
            }
            // And a cap for the whole site, whoever asks.
            app.mapImageLimiter = KeyedRateLimiter(limit: 30, window: 60)
            app.mapImageSiteLimiter = KeyedRateLimiter(limit: 0, window: 60)
            try await app.test(.GET, url, headers: cookie) { res async in
                XCTAssertEqual(res.status, .tooManyRequests)
            }
        }
    }

    /// Join and Going on the page update the action bar and, out of
    /// band, the attendee list; a cancelled event offers neither.
    func testJoinUpdatesTheAttendeeListOutOfBand() async throws {
        try await withApp { app in
            let host = try await makeUser(db: app.db, email: "host@example.com", name: "Host")
            let guest = try await makeUser(db: app.db, email: "guest@example.com", name: "Marco Guest", plan: .free)
            let event = try await makeEvent(app, title: "Tapas Exchange", host: host)
            let eventID = try event.requireID().uuidString
            let headers: HTTPHeaders = ["Cookie": try await sessionCookie(for: guest, db: app.db), "HX-Request": "true"]

            try await app.test(.POST, "/events/\(eventID)/join", headers: headers) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains(#"id="event-fragment""#))
                XCTAssertTrue(html.contains(#"id="event-attendees" class="card ed-side" aria-label="Host and people going" hx-swap-oob="true""#))
                XCTAssertTrue(html.contains("1 person going"))
                XCTAssertTrue(html.contains("Marco Guest"))
                XCTAssertTrue(html.contains(#"id="ed-rsvp" class="btn btn-going""#))
            }

            _ = try await EventService(db: app.db).cancelEvent(event, requesterID: try host.requireID())
            try await app.test(.GET, "/events/\(eventID)", headers: ["Cookie": try await sessionCookie(for: host, db: app.db)]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("This event has been cancelled."))
                XCTAssertFalse(html.contains(#"id="ed-rsvp""#), "No Join or Going on a cancelled event.")
                XCTAssertFalse(html.contains(#"action="/events/\#(eventID)/cancel""#), "Can't cancel it twice.")
            }
        }
    }

    /// Chat rows: replies name who they answer and point at their thread;
    /// the live message carries the same fields; messages have limits.
    func testChatRowsRepliesAndLimits() async throws {
        try await withApp { app in
            let host = try await makeUser(db: app.db, email: "host@example.com", name: "Ana Host")
            let guest = try await makeUser(db: app.db, email: "guest@example.com", name: "Bo Guest", plan: .free)
            let event = try await makeEvent(app, title: "Tapas Exchange", host: host)
            let eventID = try event.requireID()
            let chat = ChatService(db: app.db)
            let root = try await chat.send(SendChatMessageRequest(text: "Main gate or lake?"), eventID: eventID, userID: try host.requireID())
            let reply = try await chat.send(SendChatMessageRequest(text: "Main gate!", parentID: try root.requireID()), eventID: eventID, userID: try guest.requireID())

            let rows = EventWebController.chatRows(try [root, reply].map { try $0.toDTO() })
            XCTAssertNil(rows[0].replyToName)
            XCTAssertEqual(rows[0].threadID, try root.requireID().uuidString)
            XCTAssertEqual(rows[1].replyToName, "Ana Host")
            XCTAssertEqual(rows[1].threadID, try root.requireID().uuidString, "Replying to a reply joins its thread.")
            XCTAssertTrue(rows[1].isoTime.hasSuffix("Z"))

            struct LiveContext: Encodable { let message: ChatMessageDTO; let row: EventWebController.ChatRow }
            let req = Request(application: app, on: app.eventLoopGroup.any())
            let view = try await req.view.render("partials/chat-message-oob", LiveContext(message: try reply.toDTO(), row: rows[1]))
            let html = String(buffer: view.data)
            XCTAssertTrue(html.contains(#"<div hx-swap-oob="beforeend:#chat-messages"><div class="chat-message ed-msg is-reply" data-message-id="\#(try reply.requireID())""#),
                          "The attribute is on a wrapper: htmx inserts its contents, the .chat-message.")
            XCTAssertTrue(html.contains(#"aria-label="Reply to Bo Guest""#))
            XCTAssertTrue(html.contains("chat-message ed-msg is-reply"))
            XCTAssertTrue(html.contains("Replying to Ana Host"))
            XCTAssertTrue(html.contains(#"data-user-id="\#(try guest.requireID())""#))
            XCTAssertTrue(html.contains("data-reply"))

            for text in ["   ", String(repeating: "a", count: ChatService.maxMessageLength + 1)] {
                do {
                    _ = try await chat.send(SendChatMessageRequest(text: text), eventID: eventID, userID: try guest.requireID())
                    XCTFail("Refused: \(text.count) characters")
                } catch let error as APIError {
                    XCTAssertEqual(error.code, "invalid_message")
                }
            }
        }
    }
}
