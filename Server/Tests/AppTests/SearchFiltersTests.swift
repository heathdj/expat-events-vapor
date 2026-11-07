@testable import App
import ExpatEventsAPI
import XCTVapor
import Fluent

/// Search & filters PR: the `/events` filter panel. Upcoming by default,
/// date presets and picked dates, text search, a group, "near a city"
/// with the member's distance unit, and the htmx results swap.
final class SearchFiltersTests: XCTestCase {
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

    private func makeUser(db: Database, email: String, plan: PlanTier = .premium) async throws -> User {
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

    /// A row straight in the table (any date, any coordinates), hosted by
    /// `host`, `group`, or a new member.
    @discardableResult
    private func makeEvent(_ db: Database, _ title: String, description: String = "An evening out.",
                           in days: Double = 3, city: (Double, Double) = (38.7223, -9.1393),
                           venue: (Double, Double)? = nil, host: User? = nil, group: Group? = nil) async throws -> Event {
        let venuePoint = venue ?? city
        // Every event needs a host (a member or a group; the table checks).
        var hostUser = host
        if hostUser == nil, group == nil {
            hostUser = try await makeUser(db: db, email: "host-\(UUID().uuidString.prefix(8))@example.com", plan: .free)
        }
        let event = Event(title: title, description: description, category: .culture,
                          date: Date().addingTimeInterval(days * 24 * 3600),
                          cityAddress: "City", cityLat: city.0, cityLng: city.1,
                          venueAddress: "Venue", venueLat: venuePoint.0, venueLng: venuePoint.1,
                          hostUserID: group == nil ? try hostUser?.requireID() : nil,
                          hostGroupID: try group?.requireID())
        try await event.save(on: db)
        return event
    }

    private static func day(_ offsetDays: Double) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date().addingTimeInterval(offsetDays * 24 * 3600))
    }

    /// The list starts from now; picked dates can reach back; Next 7 days
    /// stops a week out.
    func testUpcomingByDefaultAndPickedDatesReachThePast() async throws {
        try await withApp { app in
            try await makeEvent(app.db, "Past Picnic", in: -3)
            try await makeEvent(app.db, "Started Gig", in: -1.0 / 24)       // began an hour ago
            try await makeEvent(app.db, "Earlier Brunch", in: -5.0 / 24)    // five hours ago
            try await makeEvent(app.db, "Soon Supper", in: 2)
            try await makeEvent(app.db, "Later Lecture", in: 20)

            try await app.test(.GET, "/events") { res async in
                let html = res.body.string
                XCTAssertFalse(html.contains("Past Picnic"))
                XCTAssertTrue(html.contains("Started Gig"), "Events that began within three hours still show.")
                XCTAssertFalse(html.contains("Earlier Brunch"))
                XCTAssertTrue(html.contains("Soon Supper"))
                XCTAssertTrue(html.contains("Later Lecture"))
                XCTAssertTrue(html.contains(#"<input type="radio" name="when" value="" x-model="when" checked>"#), "Upcoming is chosen.")
            }
            try await app.test(.GET, "/events?when=custom&from=\(Self.day(-5))&to=\(Self.day(-1))") { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Past Picnic"))
                XCTAssertFalse(html.contains("Soon Supper"))
                XCTAssertTrue(html.contains(#"name="from" value="\#(Self.day(-5))""#), "Picked dates stay in the form.")
            }
            try await app.test(.GET, "/events?when=week") { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Soon Supper"))
                XCTAssertFalse(html.contains("Later Lecture"))
            }
            try await app.test(.GET, "/events?when=nonsense&from=garbage") { res async in
                XCTAssertEqual(res.status, .ok, "Odd values are ignored, not errors.")
                XCTAssertTrue(res.body.string.contains("Soon Supper"))
            }
        }
    }

    /// Each preset's range in the viewer's time zone (Lisbon, UTC+1 in
    /// July). 10 July 2030 is a Wednesday.
    func testDatePresetRanges() throws {
        let iso = ISO8601DateFormatter()
        func date(_ text: String) -> Date { iso.date(from: text)! }
        func range(_ when: EventsSearch.DatePreset, now: String, from: String? = nil, to: String? = nil) -> (Date?, Date?) {
            var search = EventsSearch()
            search.when = when
            search.from = from
            search.to = to
            search.timeZoneIdentifier = "Europe/Lisbon"
            let result = search.dateRange(now: date(now))
            return (result.start, result.end)
        }
        let wednesday = "2030-07-10T15:00:00Z"

        XCTAssertEqual(range(.upcoming, now: wednesday).0, date("2030-07-10T12:00:00Z"), "Now, less three hours' grace.")
        XCTAssertNil(range(.upcoming, now: wednesday).1)

        let today = range(.today, now: wednesday)
        XCTAssertEqual(today.0, date("2030-07-09T23:00:00Z"))
        XCTAssertEqual(today.1, date("2030-07-10T23:00:00Z"), "Ends at the next midnight, exclusive.")

        let weekend = range(.weekend, now: wednesday)
        XCTAssertEqual(weekend.0, date("2030-07-12T23:00:00Z"), "Saturday, Lisbon time.")
        XCTAssertEqual(weekend.1, date("2030-07-14T23:00:00Z"), "Up to Monday's midnight.")
        let onSunday = range(.weekend, now: "2030-07-14T10:00:00Z")
        XCTAssertEqual(onSunday.0, date("2030-07-13T23:00:00Z"), "On Sunday it's the rest of today.")
        XCTAssertEqual(onSunday.1, date("2030-07-14T23:00:00Z"))
        let onSaturday = range(.weekend, now: "2030-07-13T10:00:00Z")
        XCTAssertEqual(onSaturday.0, date("2030-07-12T23:00:00Z"))

        let week = range(.week, now: wednesday)
        XCTAssertEqual(week.0, date("2030-07-10T12:00:00Z"))
        XCTAssertEqual(week.1, date("2030-07-17T15:00:00Z"))

        let month = range(.month, now: wednesday)
        XCTAssertEqual(month.1, date("2030-07-31T23:00:00Z"), "Up to 1 August, Lisbon time.")

        let swapped = range(.custom, now: wednesday, from: "2030-07-20", to: "2030-07-18")
        XCTAssertEqual(swapped.0, date("2030-07-17T23:00:00Z"), "From after To: swapped.")
        XCTAssertEqual(swapped.1, date("2030-07-20T23:00:00Z"))
        let onlyTo = range(.custom, now: wednesday, to: "2030-07-18")
        XCTAssertEqual(onlyTo.0, date("2030-07-10T12:00:00Z"), "No From: from now (with the grace).")
    }

    /// Words match the title or description, any case; % and _ are
    /// literal. The JSON API takes the same `search`.
    func testTextSearch() async throws {
        try await withApp { app in
            let jazz = try await makeEvent(app.db, "Jazz Night", description: "A live trio.")
            try await makeEvent(app.db, "Record Swap", description: "Bring your JAZZ records.")
            try await makeEvent(app.db, "Tapas Evening", description: "100% fun.")

            try await app.test(.GET, "/events?q=jazz") { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Jazz Night"))
                XCTAssertTrue(html.contains("Record Swap"))
                XCTAssertFalse(html.contains("Tapas Evening"))
                XCTAssertTrue(html.contains(#"name="q" value="jazz""#))
            }
            try await app.test(.GET, "/events?q=100%25") { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Tapas Evening"))
                XCTAssertFalse(html.contains("Jazz Night"))
            }
            try await app.test(.GET, "/events?q=_") { res async in
                XCTAssertTrue(res.body.string.contains("No events match these filters."))
                XCTAssertTrue(res.body.string.contains("Clear filters"))
            }
            try await app.test(.GET, "/events?q=night+jazz") { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Jazz Night"), "Each word may appear anywhere.")
                XCTAssertFalse(html.contains("Record Swap"))
            }
            try await app.test(.GET, "/events?q=%5C") { res async in
                XCTAssertEqual(res.status, .ok, "A backslash is just a character.")
            }
            // Going and a search together.
            let member = try await makeUser(db: app.db, email: "goer@example.com", plan: .free)
            _ = try await EventService(db: app.db).join(jazz, userID: try member.requireID())
            try await app.test(.GET, "/events?tab=going&q=jazz", headers: ["Cookie": try await sessionCookie(for: member, db: app.db)]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Jazz Night"))
                XCTAssertFalse(html.contains("Record Swap"), "Not joined.")
            }
            try await app.test(.GET, "/api/v1/events?search=JAZZ") { res async in
                let events = try? res.content.decode([EventSummaryDTO].self)
                XCTAssertEqual(events?.count, 2)
            }
        }
    }

    /// A group shows only its events; the picker lists your groups, then
    /// public ones (never someone else's invite-only group).
    func testGroupFilterAndPicker() async throws {
        try await withApp { app in
            let owner = try await makeUser(db: app.db, email: "owner@example.com")
            let owner2 = try await makeUser(db: app.db, email: "owner2@example.com")
            let member = try await makeUser(db: app.db, email: "member@example.com", plan: .free)
            let groups = GroupService(db: app.db)
            let walkers = try await groups.createGroup(CreateGroupRequest(name: "Lisbon Walkers", description: "Walks."), ownerID: try owner.requireID())
            let secret = try await groups.createGroup(CreateGroupRequest(name: "Quiet Readers", description: "Books.", visibility: .inviteOnly), ownerID: try owner2.requireID())
            try await makeEvent(app.db, "Ridge Walk", group: walkers)
            try await makeEvent(app.db, "Book Night", group: secret)
            try await makeEvent(app.db, "Solo Coffee", host: owner)
            let walkersID = try walkers.requireID().uuidString

            try await app.test(.GET, "/events?group=\(walkersID)") { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Ridge Walk"))
                XCTAssertFalse(html.contains("Book Night"))
                XCTAssertFalse(html.contains("Solo Coffee"))
                XCTAssertTrue(html.contains(#"<option value="\#(walkersID)" selected>Lisbon Walkers</option>"#))
                XCTAssertFalse(html.contains("Quiet Readers"), "Invite-only groups aren't offered to outsiders.")
            }
            try await app.test(.GET, "/events?group=\(try secret.requireID().uuidString)") { res async in
                XCTAssertFalse(res.body.string.contains(">Quiet Readers</option>"), "A UUID in the link doesn't reveal an invite-only group's name in the picker.")
            }
            try await app.test(.GET, "/events?hostGroupID=\(walkersID)") { res async in
                XCTAssertFalse(res.body.string.contains("Solo Coffee"), "Older links still work.")
            }

            // A member of the invite-only group sees it under Your groups.
            try await GroupMembership(groupID: try secret.requireID(), userID: try member.requireID(), role: .member).save(on: app.db)
            try await app.test(.GET, "/events", headers: ["Cookie": try await sessionCookie(for: member, db: app.db)]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains(#"<optgroup label="Your groups">"#))
                XCTAssertTrue(html.contains("Quiet Readers"))
            }
        }
    }

    /// Near a point: by the venue's coordinates, or the city's when the
    /// venue has none; within the radius; in the viewer's unit.
    func testNearACity() async throws {
        try await withApp { app in
            let lisbon = (38.7223, -9.1393)
            try await makeEvent(app.db, "Alfama Fado", venue: lisbon)
            try await makeEvent(app.db, "Sintra Palace Tour", venue: (38.8029, -9.3817)) // about 23 km
            try await makeEvent(app.db, "Porto Wine Walk", city: (41.1579, -8.6291))     // about 274 km
            try await makeEvent(app.db, "Old Lisbon Meetup", venue: (0, 0))               // city coordinates only
            try await makeEvent(app.db, "Porto Venue Lisbon City", venue: (41.1579, -8.6291))
            let base = "/events?near=Lisbon&nearLat=38.7223&nearLng=-9.1393"

            try await app.test(.GET, base + "&radius=25&unit=km") { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Alfama Fado"))
                XCTAssertTrue(html.contains("Sintra Palace Tour"))
                XCTAssertTrue(html.contains("Old Lisbon Meetup"), "No venue coordinates: the city's are used.")
                XCTAssertFalse(html.contains("Porto Wine Walk"))
                XCTAssertFalse(html.contains("Porto Venue Lisbon City"), "The venue's coordinates win over the city's.")
            }
            try await app.test(.GET, base + "&radius=10&unit=km") { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Alfama Fado"))
                XCTAssertFalse(html.contains("Sintra Palace Tour"))
            }

            // A member who uses miles: 15 mi (24 km) reaches Sintra.
            let miler = try await makeUser(db: app.db, email: "miles@example.com", plan: .free)
            miler.distanceUnit = .mi
            try await miler.save(on: app.db)
            let cookie = try await sessionCookie(for: miler, db: app.db)
            try await app.test(.GET, base + "&radius=15&unit=mi", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Sintra Palace Tour"))
                XCTAssertTrue(html.contains(#"<option value="15" selected>15 mi</option>"#))
                XCTAssertTrue(html.contains(#"name="nearLat" value="38.7223""#))
                XCTAssertTrue(html.contains("ev-near-clear"), "A picked city can be cleared.")
            }
            // Someone using km opening that link gets the nearest km choice.
            let kmUser = try await makeUser(db: app.db, email: "km@example.com", plan: .free)
            try await app.test(.GET, base + "&radius=15&unit=mi", headers: ["Cookie": try await sessionCookie(for: kmUser, db: app.db)]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains(#"<option value="25" selected>25 km</option>"#))
                XCTAssertTrue(html.contains("Sintra Palace Tour"))
            }
            // Visitors can't search places, so they're offered sign-in.
            try await app.test(.GET, "/events") { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Sign in to search near a city"))
                XCTAssertFalse(html.contains(#"id="ev-radius""#))
            }
        }
    }

    /// A filter change gets just the results (with the status line out of
    /// band) and the tidy address; Load more keeps the filters; a history
    /// restore gets the whole page.
    func testFilterChangesSwapResultsAndKeepFilters() async throws {
        try await withApp { app in
            for index in 1...(EventService.pageSize + 1) {
                try await makeEvent(app.db, "Jazz Session \(index)", in: Double(index))
            }
            try await makeEvent(app.db, "Quiet Coffee")
            let formURL = "/events?tz=Europe%2FLisbon&q=jazz&tab=all&when=&from=&to=&category=&near=&nearLat=&nearLng=&radius=25&unit=km&group="

            try await app.test(.GET, formURL, headers: ["HX-Request": "true", "HX-Target": "ev-results"]) { res async in
                let html = res.body.string
                XCTAssertEqual(res.status, .ok)
                XCTAssertFalse(html.contains("<html"))
                XCTAssertTrue(html.contains(#"id="ev-results-status""#))
                XCTAssertTrue(html.contains(#"hx-swap-oob="innerHTML""#), "The status text is updated inside the live region.")
                XCTAssertTrue(html.contains("Showing the first 20 events"))
                XCTAssertFalse(html.contains("Quiet Coffee"))
                XCTAssertEqual(res.headers.first(name: "HX-Push-Url"), "/events?q=jazz")
                XCTAssertTrue(html.contains(#"hx-get="/events?q=jazz&amp;page=2""#), "Load more keeps the search.")
            }
            try await app.test(.GET, "/events?q=jazz&page=2", headers: ["HX-Request": "true", "HX-Target": "load-more"]) { res async in
                let html = res.body.string
                XCTAssertEqual(html.components(separatedBy: "data-event-card").count - 1, 1)
                XCTAssertTrue(html.contains("Jazz Session 21"))
            }
            try await app.test(.GET, "/events?q=jazz", headers: ["HX-Request": "true", "HX-History-Restore-Request": "true"]) { res async in
                XCTAssertTrue(res.body.string.contains("<html"), "A history restore gets the whole page.")
            }
        }
    }

    /// A day's range ends at the next midnight, exclusive, so an event at
    /// 23:59:59.5 is still today; one at midnight is tomorrow (PR #21 QA).
    func testTodayIncludesTheLastSecond() async throws {
        try await withApp { app in
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let midnight = utc.date(byAdding: .day, value: 1, to: utc.startOfDay(for: Date()))!
            let host = try await makeUser(db: app.db, email: "late@example.com", plan: .free)
            for (title, date) in [("Late Owl Party", midnight.addingTimeInterval(-0.5)), ("Tomorrow Breakfast", midnight)] {
                let event = Event(title: title, description: "d", category: .culture, date: date,
                                  cityAddress: "City", cityLat: 38.72, cityLng: -9.14,
                                  venueAddress: "Venue", venueLat: 38.72, venueLng: -9.14,
                                  hostUserID: try host.requireID())
                try await event.save(on: app.db)
            }
            try await app.test(.GET, "/events?when=today&tz=UTC") { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Late Owl Party"))
                XCTAssertFalse(html.contains("Tomorrow Breakfast"))
            }
        }
    }

    /// Dates the database can't store are ignored instead of crashing the
    /// server (review blocker), on the page and in the API.
    func testOutOfRangeDatesAreIgnored() async throws {
        try await withApp { app in
            try await makeEvent(app.db, "Soon Supper", in: 2)
            for url in ["/events?onOrAfterDate=1e13", "/events?onOrAfterDate=nan", "/events?onOrAfterDate=-1e300",
                        "/api/v1/events?onOrBeforeDate=1e13", "/api/v1/events?onOrAfterDate=-1e13"] {
                try await app.test(.GET, url) { res async in
                    XCTAssertEqual(res.status, .ok, url)
                }
            }
            try await app.test(.GET, "/events?onOrAfterDate=1e13") { res async in
                XCTAssertTrue(res.body.string.contains("Soon Supper"), "Ignored, so the default applies.")
            }
        }
        XCTAssertNil(EventService.saneDate(Date(timeIntervalSince1970: 1e13)))
        XCTAssertNil(EventService.saneDate(Date(timeIntervalSince1970: .nan)))
        XCTAssertNotNil(EventService.saneDate(Date()))
    }

    /// The unit is saved on /account, shown there, used on /events and
    /// included in the data export.
    func testDistanceUnitPreference() async throws {
        try await withApp { app in
            let user = try await makeUser(db: app.db, email: "prefs@example.com", plan: .free)
            let cookie = try await sessionCookie(for: user, db: app.db)
            let form: HTTPHeaders = ["Cookie": cookie, "Content-Type": "application/x-www-form-urlencoded"]

            try await app.test(.GET, "/account", headers: ["Cookie": cookie]) { res async in
                XCTAssertTrue(res.body.string.contains(#"name="distanceUnit" value="km" checked>"#), "Kilometres by default.")
            }
            try await app.test(.POST, "/account/preferences", headers: form, body: .init(string: "distanceUnit=furlongs")) { res async in
                XCTAssertEqual(res.status, .badRequest)
            }
            try await app.test(.POST, "/account/preferences", headers: form, body: .init(string: "distanceUnit=mi")) { res async in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/account?prefs=saved#preferences")
            }
            let saved = try await User.find(try user.requireID(), on: app.db)
            XCTAssertEqual(saved?.distanceUnit, .mi)
            try await app.test(.GET, "/account?prefs=saved", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains(#"name="distanceUnit" value="mi" checked>"#))
                XCTAssertTrue(html.contains("Preferences saved."))
            }
            try await app.test(.GET, "/events", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains(#"<option value="15" selected>15 mi</option>"#), "Miles, 15 by default.")
                XCTAssertTrue(html.contains(#"name="unit" value="mi""#))
            }
            try await app.test(.POST, "/account/export", headers: ["Cookie": cookie]) { res async in
                XCTAssertTrue(res.body.string.contains(#""distanceUnit" : "mi""#))
            }
        }
    }

    /// The "Near" field's place search: suggestions target the near field
    /// and picking one returns it with coordinates, telling the form to
    /// refresh.
    func testNearFieldPlaceSearch() async throws {
        try await withApp { app in
            let user = try await makeUser(db: app.db, email: "near@example.com", plan: .free)
            let cookie = try await sessionCookie(for: user, db: app.db)
            try await app.test(.GET, "/places/suggest?kind=city&field=near&near=lis&session=s1", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Lisbon"))
                XCTAssertTrue(html.contains("#near-field"))
                XCTAssertTrue(html.contains("field=near"))
            }
            try await app.test(.GET, "/places/select?kind=city&field=near&id=sample-city-lisbon&name=Lisbon&session=s1", headers: ["Cookie": cookie]) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains(#"id="near-field""#))
                XCTAssertTrue(html.contains(#"name="nearLat" value="38.7223""#))
                XCTAssertTrue(html.contains(#"x-init="$dispatch('near-picked')""#), "Tells the filter form to refresh.")
                XCTAssertTrue(html.contains("if (had) f.dispatchEvent(new CustomEvent('near-picked'"), "Editing a picked city refreshes too.")
            }
        }
    }
}
