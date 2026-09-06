@testable import App
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
            try await app.testing().test(.GET, "health") { res in
                XCTAssertEqual(res.status, .ok)
            }
        }
    }

    /// M1 acceptance criterion #3: seeding twice doesn't duplicate rows.
    func testSeedCommandIsIdempotent() async throws {
        try await withApp { app in
            let command = SeedCommand()
            let context = CommandContext(console: app.console, input: CommandInput(arguments: ["seed"]))
            try await command.run(using: context, signature: SeedCommand.Signature())
            let countAfterFirstRun = try await User.query(on: app.db).count()

            try await command.run(using: context, signature: SeedCommand.Signature())
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
}
