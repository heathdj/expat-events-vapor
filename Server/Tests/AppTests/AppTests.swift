@testable import App
import ExpatEventsAPI
import XCTVapor
import Fluent

/// Integration tests against a real Postgres instance (matching `.env.example`
/// / `docker-compose.yml`) — Fluent's Postgres driver is what M1 and every
/// milestone after it actually runs against, so these don't use an
/// in-memory substitute. Run `docker compose up -d db` first (see README).
final class AppTests: XCTestCase {
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

    /// M1 acceptance criterion #4: health-check route returns 200 confirming
    /// DB connectivity.
    func testHealthCheckReturns200() async throws {
        try await withApp { app in
            try await app.testable().test(.GET, "health") { res in
                XCTAssertEqual(res.status, .ok)
            }
        }
    }

    /// M1 acceptance criterion #3: seeding twice doesn't duplicate rows.
    func testSeedCommandIsIdempotent() async throws {
        try await withApp { app in
            let command = SeedCommand()
            var context = CommandContext(console: app.console, input: CommandInput(arguments: ["seed"]))
            // Vapor's real command-line runner sets `context.application`
            // before invoking a command; constructing `CommandContext`
            // directly (as a test must, to run a command outside the CLI)
            // skips that, so `SeedCommand.run`'s `context.application...`
            // access hits Vapor's own `fatalError("Application not set on
            // context")`. Set it explicitly here.
            context.application = app
            try command.run(using: context, signature: SeedCommand.Signature())
            let countAfterFirstRun = try await User.query(on: app.db).count()

            try command.run(using: context, signature: SeedCommand.Signature())
            let countAfterSecondRun = try await User.query(on: app.db).count()

            XCTAssertEqual(countAfterFirstRun, countAfterSecondRun)
            XCTAssertGreaterThanOrEqual(countAfterFirstRun, 3)

            let eventCount = try await Event.query(on: app.db).count()
            XCTAssertGreaterThanOrEqual(eventCount, 2)

            let groupCount = try await Group.query(on: app.db).count()
            XCTAssertEqual(groupCount, 1)
        }
    }

    /// Known-risk area #1 in the plan: plan-limit boundaries are the likely
    /// bug class (4 vs. 5 vs. 6) — test the exact boundary for event hosting.
    func testFreeUserCanHostExactlyFiveActiveEvents() async throws {
        try await withApp { app in
            let user = User(
                displayName: "Boundary Tester",
                email: "boundary@example.com",
                privacyPolicyVersion: LegalVersions.privacyPolicy,
                termsVersion: LegalVersions.terms
            )
            try await user.save(on: app.db)
            let subscription = Subscription(userID: try user.requireID(), plan: .free, status: .active)
            try await subscription.save(on: app.db)

            let service = EventService(db: app.db)
            let baseRequest = { (title: String) in
                CreateEventRequest(
                    title: title,
                    description: "Test event",
                    category: .culture,
                    date: Date().addingTimeInterval(3600),
                    cityAddress: "Test City",
                    cityLat: 0, cityLng: 0,
                    venueAddress: "Test Venue",
                    venueLat: 0, venueLng: 0
                )
            }

            for index in 1...5 {
                _ = try await service.createEvent(baseRequest("Event \(index)"), hostUserID: try user.requireID())
            }

            do {
                _ = try await service.createEvent(baseRequest("Event 6 — should fail"), hostUserID: try user.requireID())
                XCTFail("The 6th active event should have been rejected by the plan limit.")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "plan_limit_exceeded")
            }
        }
    }

    // MARK: - M4 test helpers

    private func makeUser(db: Database, email: String, plan: PlanTier = .free) async throws -> User {
        let user = User(
            displayName: email,
            email: email,
            privacyPolicyVersion: LegalVersions.privacyPolicy,
            termsVersion: LegalVersions.terms
        )
        try await user.save(on: db)
        let subscription = Subscription(userID: try user.requireID(), plan: plan, status: .active)
        try await subscription.save(on: db)
        return user
    }

    private func makeEventRequest(
        title: String = "Test Event",
        category: EventCategory = .culture,
        date: Date = Date().addingTimeInterval(3600),
        cityAddress: String = "Test City",
        venueAddress: String = "Test Venue",
        visibility: EventVisibility = .public
    ) -> CreateEventRequest {
        CreateEventRequest(
            title: title,
            description: "Test event",
            category: category,
            date: date,
            cityAddress: cityAddress,
            cityLat: 0, cityLng: 0,
            venueAddress: venueAddress,
            venueLat: 0, venueLng: 0,
            visibility: visibility
        )
    }

    /// M4 acceptance criterion #2: a Free-tier event accepts up to 5
    /// attendees; the 6th join attempt is rejected with a plan-limit error.
    func testFreeTierEventAcceptsExactlyFiveAttendees() async throws {
        try await withApp { app in
            let host = try await makeUser(db: app.db, email: "host@example.com")
            let service = EventService(db: app.db)
            let event = try await service.createEvent(makeEventRequest(title: "Popular Event"), hostUserID: try host.requireID())

            for index in 1...5 {
                let attendee = try await makeUser(db: app.db, email: "attendee\(index)@example.com")
                _ = try await service.join(event, userID: try attendee.requireID())
            }

            let sixthAttendee = try await makeUser(db: app.db, email: "attendee6@example.com")
            do {
                _ = try await service.join(event, userID: try sixthAttendee.requireID())
                XCTFail("The 6th attendee should have been rejected by the plan limit.")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "plan_limit_exceeded")
            }

            let finalCount = try await EventAttendee.query(on: app.db).filter(\.$event.$id == event.requireID()).count()
            XCTAssertEqual(finalCount, 5)
        }
    }

    /// M4 acceptance criterion #3: a Free user cannot set an event to
    /// `private`, even by calling the service directly (bypassing the UI).
    func testFreeUserCannotCreatePrivateEvent() async throws {
        try await withApp { app in
            let host = try await makeUser(db: app.db, email: "free-private@example.com")
            let service = EventService(db: app.db)
            do {
                _ = try await service.createEvent(
                    makeEventRequest(title: "Should be rejected", visibility: .private),
                    hostUserID: try host.requireID()
                )
                XCTFail("A Free user's private event should have been rejected.")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "plan_limit_exceeded")
            }
        }
    }

    /// M4 acceptance criterion #3 (positive case): a Premium user CAN create
    /// a private event — confirms the rejection above is plan-gated, not a
    /// blanket ban on the feature.
    func testPremiumUserCanCreatePrivateEvent() async throws {
        try await withApp { app in
            let host = try await makeUser(db: app.db, email: "premium-private@example.com", plan: .premium)
            let service = EventService(db: app.db)
            let event = try await service.createEvent(
                makeEventRequest(title: "Premium private event", visibility: .private),
                hostUserID: try host.requireID()
            )
            XCTAssertEqual(event.visibility, .private)
        }
    }

    /// M4 acceptance criterion #4: `/events` filters by category, city,
    /// venue, host, and date correctly against both matching and
    /// non-matching rows.
    func testEventFilteringMatchesAndExcludesCorrectly() async throws {
        try await withApp { app in
            let host = try await makeUser(db: app.db, email: "filter-host@example.com")
            let otherHost = try await makeUser(db: app.db, email: "filter-other-host@example.com")
            let service = EventService(db: app.db)

            let matching = try await service.createEvent(
                makeEventRequest(title: "Culture in Berlin", category: .culture, cityAddress: "Berlin, Germany"),
                hostUserID: try host.requireID()
            )
            _ = try await service.createEvent(
                makeEventRequest(title: "Drinks in Berlin", category: .drinks, cityAddress: "Berlin, Germany"),
                hostUserID: try host.requireID()
            )
            _ = try await service.createEvent(
                makeEventRequest(title: "Culture in Paris", category: .culture, cityAddress: "Paris, France"),
                hostUserID: try otherHost.requireID()
            )

            // Category + city filter together should match only the one event.
            let filtered = try await service.filteredEvents(
                EventFilterQuery(category: .culture, city: "Berlin"),
                requesterID: nil
            )
            XCTAssertEqual(filtered.map { $0.id }, [try matching.requireID()])

            // Host filter should isolate that host's events only.
            let byHost = try await service.filteredEvents(
                EventFilterQuery(hostUserID: try otherHost.requireID()),
                requesterID: nil
            )
            XCTAssertEqual(byHost.count, 1)
            XCTAssertEqual(byHost.first?.cityAddress, "Paris, France")

            // A category with no matches should return nothing.
            let none = try await service.filteredEvents(
                EventFilterQuery(category: .film),
                requesterID: nil
            )
            XCTAssertTrue(none.isEmpty)
        }
    }

    /// M4 acceptance criterion #5: the event detail DTO carries the correct
    /// title, host, date, venue, description, and attendee list.
    func testEventDetailDTOHasCorrectFields() async throws {
        try await withApp { app in
            let host = try await makeUser(db: app.db, email: "detail-host@example.com")
            let attendee = try await makeUser(db: app.db, email: "detail-attendee@example.com")
            let service = EventService(db: app.db)
            let event = try await service.createEvent(
                makeEventRequest(title: "Detail Test Event", venueAddress: "Some Venue, Some City"),
                hostUserID: try host.requireID()
            )
            _ = try await service.join(event, userID: try attendee.requireID())

            let dto = try await service.fullDTO(for: event, requesterID: try attendee.requireID())
            XCTAssertEqual(dto.title, "Detail Test Event")
            XCTAssertEqual(dto.venueAddress, "Some Venue, Some City")
            XCTAssertEqual(dto.hostDisplayName, host.displayName)
            XCTAssertEqual(dto.attendees.count, 1)
            XCTAssertEqual(dto.attendees.first?.id, try attendee.requireID())
            XCTAssertTrue(dto.isRequesterAttending)
        }
    }

    /// M4 acceptance criterion #7: cancelling sets `isCancelled = true`; the
    /// row and attendee history survive (no delete).
    func testCancelEventSurvivesWithAttendeeHistory() async throws {
        try await withApp { app in
            let host = try await makeUser(db: app.db, email: "cancel-host@example.com")
            let attendee = try await makeUser(db: app.db, email: "cancel-attendee@example.com")
            let service = EventService(db: app.db)
            let event = try await service.createEvent(makeEventRequest(title: "To be cancelled"), hostUserID: try host.requireID())
            _ = try await service.join(event, userID: try attendee.requireID())

            let cancelled = try await service.cancelEvent(event, requesterID: try host.requireID())
            XCTAssertTrue(cancelled.isCancelled)

            let stillExists = try await Event.find(event.requireID(), on: app.db)
            XCTAssertNotNil(stillExists, "The event row must survive cancellation, not be deleted.")

            let attendeeStillThere = try await EventAttendee.query(on: app.db)
                .filter(\.$event.$id == event.requireID())
                .filter(\.$user.$id == try attendee.requireID())
                .count()
            XCTAssertEqual(attendeeStillThere, 1, "Attendee history must survive cancellation.")
        }
    }

    /// M4 acceptance criterion #8: a non-host cannot edit or cancel someone
    /// else's event — 403 (`APIError.forbidden`) on a direct attempt.
    func testNonHostCannotCancelSomeoneElsesEvent() async throws {
        try await withApp { app in
            let host = try await makeUser(db: app.db, email: "real-host@example.com")
            let intruder = try await makeUser(db: app.db, email: "intruder@example.com")
            let service = EventService(db: app.db)
            let event = try await service.createEvent(makeEventRequest(title: "Someone else's event"), hostUserID: try host.requireID())

            do {
                _ = try await service.cancelEvent(event, requesterID: try intruder.requireID())
                XCTFail("A non-host should not be able to cancel this event.")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "forbidden")
            }

            let stillActive = try await Event.find(event.requireID(), on: app.db)
            XCTAssertEqual(stillActive?.isCancelled, false)
        }
    }
}
