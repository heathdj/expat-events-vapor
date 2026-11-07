@testable import App
import ExpatEventsAPI
import XCTVapor
import Fluent

/// Theme Events PR: the restyled `/events` page. All / Going / Hosting
/// tabs, category chips, the new cards and joining from a card.
final class EventsPageTests: XCTestCase {
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

    private func makeEvent(_ app: Application, title: String, host: User, category: EventCategory = .food,
                           description: String = "A relaxed evening.", groupID: UUID? = nil,
                           attendeeLimit: Int? = nil, daysAhead: Double = 3) async throws -> Event {
        try await EventService(db: app.db).createEvent(CreateEventRequest(
            title: title, description: description, category: category,
            date: Date().addingTimeInterval(daysAhead * 24 * 3600),
            cityAddress: "Lisbon, Portugal", cityLat: 38.72, cityLng: -9.14,
            venueAddress: "Cafe A Brasileira", venueLat: 38.71, venueLng: -9.14,
            hostGroupID: groupID, visibility: visibility, attendeeLimit: attendeeLimit
        ), hostUserID: try host.requireID())
    }

    /// Going lists what a member joined; Hosting what they host, including
    /// events of a group they moderate. Visitors get no tabs and always
    /// see everything.
    func testTabsShowGoingAndHostingEvents() async throws {
        try await withApp { app in
            let alice = try await makeUser(db: app.db, email: "alice@example.com", name: "Alice")
            let bob = try await makeUser(db: app.db, email: "bob@example.com", name: "Bob")
            let carol = try await makeUser(db: app.db, email: "carol@example.com", name: "Carol")
            let groups = GroupService(db: app.db)
            let group = try await groups.createGroup(CreateGroupRequest(name: "Lisbon Walkers", description: "Walks."), ownerID: try carol.requireID())
            try await groups.join(group, userID: try alice.requireID())
            try await groups.promoteModerator(group, memberUserID: try alice.requireID(), requesterID: try carol.requireID())

            _ = try await makeEvent(app, title: "Alice Picnic", host: alice)
            let quiz = try await makeEvent(app, title: "Bob Quiz Night", host: bob, daysAhead: 4)
            _ = try await makeEvent(app, title: "Club Walk", host: carol, category: .travel, groupID: try group.requireID(), daysAhead: 5)
            _ = try await EventService(db: app.db).join(quiz, userID: try alice.requireID())
            let aliceCookie = try await sessionCookie(for: alice, db: app.db)

            try await app.test(.GET, "/events?tab=going", headers: ["Cookie": aliceCookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Bob Quiz Night"))
                XCTAssertFalse(html.contains("Alice Picnic"))
                XCTAssertFalse(html.contains("Club Walk"))
                XCTAssertTrue(html.contains(#"<a href="/events?tab=going" class="ev-tab is-active" aria-current="page">Going</a>"#))
                XCTAssertTrue(html.contains("/leave?view=card"), "A joined event's card offers Going (leave).")
            }
            try await app.test(.GET, "/events?tab=hosting", headers: ["Cookie": aliceCookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Alice Picnic"))
                XCTAssertTrue(html.contains("Club Walk"), "Events of a group she moderates count as hosting.")
                XCTAssertFalse(html.contains("Bob Quiz Night"))
                XCTAssertEqual(html.components(separatedBy: "You host this").count - 1, 2)
            }
            try await app.test(.GET, "/events", headers: ["Cookie": aliceCookie]) { res async in
                let html = res.body.string
                XCTAssertEqual(html.components(separatedBy: "data-event-card").count - 1, 3)
                XCTAssertTrue(html.contains(#"<a href="/events" class="ev-tab is-active" aria-current="page">All</a>"#))
            }
            try await app.test(.GET, "/events?tab=going", headers: ["Cookie": try await sessionCookie(for: bob, db: app.db)]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("data-events-empty"))
                XCTAssertTrue(html.contains("joined any events here yet"))
            }
            try await app.test(.GET, "/events?tab=going") { res async in
                let html = res.body.string
                XCTAssertFalse(html.contains("ev-tabs"), "Visitors get no tabs.")
                XCTAssertEqual(html.components(separatedBy: "data-event-card").count - 1, 3, "and see every event.")
                XCTAssertTrue(html.contains("Sign in to join"))
            }
        }
    }

    /// "All" plus all six categories with their photos; each chip keeps
    /// the tab, and the current one is marked.
    func testCategoryChipsKeepTheTabAndShowPhotos() async throws {
        try await withApp { app in
            let alice = try await makeUser(db: app.db, email: "alice@example.com", name: "Alice")
            _ = try await makeEvent(app, title: "Tapas Exchange", host: alice, category: .food)
            _ = try await makeEvent(app, title: "Jazz Night", host: alice, category: .music)
            let cookie = try await sessionCookie(for: alice, db: app.db)

            try await app.test(.GET, "/events?tab=hosting&category=food", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                let chips = html.components(separatedBy: #"class="ev-chip""#).count - 1
                    + html.components(separatedBy: #"class="ev-chip is-active""#).count - 1
                XCTAssertEqual(chips, 7)
                for category in EventCategory.allCases {
                    XCTAssertTrue(html.contains("/design/categories/\(category.rawValue).jpg"), "\(category) chip has its photo.")
                }
                XCTAssertTrue(html.contains(#"<a href="/events?tab=hosting&amp;category=food" class="ev-chip is-active" aria-current="page">"#))
                XCTAssertTrue(html.contains(#"<a href="/events?tab=hosting&amp;category=film" class="ev-chip">"#))
                XCTAssertTrue(html.contains(#"<a href="/events?tab=hosting" class="ev-chip">"#), "All keeps the tab.")
                XCTAssertTrue(html.contains("Tapas Exchange"))
                XCTAssertFalse(html.contains("Jazz Night"))
                XCTAssertTrue(html.contains(#"href="/events?tab=going&amp;category=food""#), "Tabs keep the category (& escaped in the attribute).")
            }
        }
    }

    /// A card has the category photo, a short description, the group tag
    /// for group events, attendee photos and the count.
    func testCardsShowPhotoDescriptionAndAttendees() async throws {
        try await withApp { app in
            let host = try await makeUser(db: app.db, email: "host@example.com", name: "Hosty")
            let guest1 = try await makeUser(db: app.db, email: "g1@example.com", name: "G1", plan: .free)
            let guest2 = try await makeUser(db: app.db, email: "g2@example.com", name: "G2", plan: .free)
            let long = String(repeating: "Swap languages over tapas. ", count: 20)
            let event = try await makeEvent(app, title: "Tapas Exchange", host: host, description: long)
            _ = try await makeEvent(app, title: "Quiet Coffee", host: host, category: .culture, daysAhead: 6)
            _ = try await EventService(db: app.db).join(event, userID: try guest1.requireID())
            _ = try await EventService(db: app.db).join(event, userID: try guest2.requireID())

            try await app.test(.GET, "/events") { res async in
                let html = res.body.string
                XCTAssertEqual(html.components(separatedBy: "/design/categories/food.jpg").count - 1, 2, "The Food chip and the card's photo.")
                XCTAssertTrue(html.contains(#"<span class="ev-cat-badge">Food</span>"#))
                XCTAssertTrue(html.contains("Swap languages over tapas."))
                XCTAssertTrue(html.contains("…"), "Long descriptions are shortened.")
                XCTAssertTrue(html.contains("2 going"))
                XCTAssertTrue(html.contains("Be the first to join"))
                XCTAssertFalse(html.contains("Group event"))
            }
        }
        XCTAssertEqual(EventWebController.descriptionPreview("Short one."), "Short one.")
        XCTAssertEqual(EventWebController.descriptionPreview("Line one\nline two"), "Line one line two")
        let preview = EventWebController.descriptionPreview(String(repeating: "word ", count: 100))
        XCTAssertTrue(preview.hasSuffix("word…"))
        XCTAssertLessThanOrEqual(preview.count, 221)
    }

    /// Join and Going on a card swap that card in place; a full event
    /// says so on the card; the event page's own buttons are unchanged.
    func testJoinAndLeaveFromACard() async throws {
        try await withApp { app in
            let host = try await makeUser(db: app.db, email: "host@example.com", name: "Hosty")
            let guest = try await makeUser(db: app.db, email: "guest@example.com", name: "Guesty", plan: .free)
            let other = try await makeUser(db: app.db, email: "other@example.com", name: "Other", plan: .free)
            let event = try await makeEvent(app, title: "Tapas Exchange", host: host)
            let full = try await makeEvent(app, title: "Tiny Dinner", host: host, attendeeLimit: 1, daysAhead: 4)
            _ = try await EventService(db: app.db).join(full, userID: try other.requireID())
            let eventID = try event.requireID()
            let guestID = try guest.requireID()
            let headers: HTTPHeaders = ["Cookie": try await sessionCookie(for: guest, db: app.db), "HX-Request": "true"]

            try await app.test(.POST, "/events/\(eventID.uuidString)/join?view=card", headers: headers) { res async in
                let html = res.body.string
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(html.components(separatedBy: "data-event-card").count - 1, 1)
                XCTAssertTrue(html.contains("/leave?view=card"))
                XCTAssertTrue(html.contains("1 going"))
                XCTAssertFalse(html.contains("<html"))
                XCTAssertFalse(html.contains("load-more"))
            }
            let joined = try await EventAttendee.query(on: app.db).filter(\.$event.$id == eventID).filter(\.$user.$id == guestID).count()
            XCTAssertEqual(joined, 1)

            try await app.test(.POST, "/events/\(eventID.uuidString)/leave?view=card", headers: headers) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("/join?view=card"))
                XCTAssertTrue(html.contains("Be the first to join"))
            }

            try await app.test(.POST, "/events/\(try full.requireID().uuidString)/join?view=card", headers: headers) { res async in
                let html = res.body.string
                XCTAssertEqual(res.status, .ok, "htmx only swaps a 2xx, so the card comes back with the message.")
                XCTAssertTrue(html.contains("data-card-error"))
                XCTAssertTrue(html.contains("This event is full"))
                XCTAssertTrue(html.contains("/join?view=card"))
            }
            let fullCount = try await EventAttendee.query(on: app.db).filter(\.$event.$id == (try full.requireID())).count()
            XCTAssertEqual(fullCount, 1)

            try await app.test(.POST, "/events/\(eventID.uuidString)/join", headers: headers) { res async in
                XCTAssertTrue(res.body.string.contains(#"id="event-fragment""#), "The event page's buttons still get the page fragment.")
            }
        }
    }

    /// Card requests follow the same rules as the event page: a
    /// non-member can't join or leave a private group event through a
    /// card (404, no card); someone who has lost access gets an empty
    /// answer that removes the card; a cancelled event's card says so
    /// instead of offering Join.
    func testCardRequestsRespectVisibilityAndCancellation() async throws {
        try await withApp { app in
            let owner = try await makeUser(db: app.db, email: "owner@example.com", name: "Owner")
            let guest = try await makeUser(db: app.db, email: "guest@example.com", name: "Guesty", plan: .free)
            let groups = GroupService(db: app.db)
            let group = try await groups.createGroup(CreateGroupRequest(name: "Secret Supper Club", description: "Dinners."), ownerID: try owner.requireID())
            let secret = try await makeEvent(app, title: "Members Dinner", host: owner, groupID: try group.requireID(), visibility: .private)
            let secretID = try secret.requireID().uuidString
            let headers: HTTPHeaders = ["Cookie": try await sessionCookie(for: guest, db: app.db), "HX-Request": "true"]

            for action in ["join", "leave"] {
                try await app.test(.POST, "/events/\(secretID)/\(action)?view=card", headers: headers) { res async in
                    XCTAssertEqual(res.status, .notFound, "\(action) on a private group event")
                    XCTAssertFalse(res.body.string.contains("Members Dinner"))
                }
            }

            // A member joins, then leaves the group: leaving the event
            // removes the card instead of showing it again.
            try await groups.join(group, userID: try guest.requireID())
            _ = try await EventService(db: app.db).join(secret, userID: try guest.requireID())
            try await groups.leave(group, userID: try guest.requireID())
            try await app.test(.POST, "/events/\(secretID)/leave?view=card", headers: headers) { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.body.readableBytes, 0)
            }

            let dinner = try await makeEvent(app, title: "Open Dinner", host: owner, daysAhead: 4)
            _ = try await EventService(db: app.db).cancelEvent(dinner, requesterID: try owner.requireID())
            try await app.test(.POST, "/events/\(try dinner.requireID().uuidString)/join?view=card", headers: headers) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("data-card-error"))
                XCTAssertTrue(html.contains("This event has been cancelled."))
                XCTAssertTrue(html.contains(#"<span class="ev-cancelled">Cancelled</span>"#))
                XCTAssertFalse(html.contains("/join?view=card"), "No Join on a cancelled event.")
            }
        }
    }

    /// Load more on a tab fetches that tab's next page.
    func testLoadMoreOnATab() async throws {
        try await withApp { app in
            let alice = try await makeUser(db: app.db, email: "alice@example.com", name: "Alice")
            let bob = try await makeUser(db: app.db, email: "bob@example.com", name: "Bob")
            for index in 1...(EventService.pageSize + 1) {
                _ = try await makeEvent(app, title: "Alice Event \(index)", host: alice, daysAhead: Double(index))
            }
            _ = try await makeEvent(app, title: "Bob Event", host: bob)
            let cookie = try await sessionCookie(for: alice, db: app.db)

            try await app.test(.GET, "/events?tab=hosting", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertEqual(html.components(separatedBy: "data-event-card").count - 1, EventService.pageSize)
                XCTAssertTrue(html.contains(#"hx-get="/events?tab=hosting&amp;page=2""#))
            }
            try await app.test(.GET, "/events?tab=hosting&page=2", headers: ["Cookie": cookie, "HX-Request": "true"]) { res async in
                let html = res.body.string
                XCTAssertEqual(html.components(separatedBy: "data-event-card").count - 1, 1)
                XCTAssertTrue(html.contains("Alice Event 21"))
                XCTAssertFalse(html.contains("Bob Event"))
            }
        }
    }

    /// "Load more" keeps the tab.
    func testLoadMoreKeepsTheTab() {
        let url = EventWebController.pageURL(for: EventFilterQuery(category: .music), page: 2, tab: .going)
        XCTAssertEqual(url, "/events?tab=going&category=music&page=2")
        XCTAssertEqual(EventWebController.listURL(for: EventFilterQuery(), tab: .all), "/events")
    }
}
