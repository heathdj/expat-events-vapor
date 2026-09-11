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
            try await app.testable().test(.GET, "health") { res async in
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

            let earlyDate = Date().addingTimeInterval(3600)
            let lateDate = Date().addingTimeInterval(30 * 24 * 3600)

            let matching = try await service.createEvent(
                makeEventRequest(title: "Culture in Berlin", category: .culture, date: earlyDate, cityAddress: "Berlin, Germany", venueAddress: "Berlin Opera House"),
                hostUserID: try host.requireID()
            )
            _ = try await service.createEvent(
                makeEventRequest(title: "Drinks in Berlin", category: .drinks, date: earlyDate, cityAddress: "Berlin, Germany", venueAddress: "Berlin Bar"),
                hostUserID: try host.requireID()
            )
            _ = try await service.createEvent(
                makeEventRequest(title: "Culture in Paris", category: .culture, date: lateDate, cityAddress: "Paris, France", venueAddress: "Louvre"),
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

            // Venue filter should match only the event at that venue.
            let byVenue = try await service.filteredEvents(
                EventFilterQuery(venue: "Opera"),
                requesterID: nil
            )
            XCTAssertEqual(byVenue.map { $0.id }, [try matching.requireID()])

            // Date filter (onOrAfterDate) should exclude events strictly before it.
            let byDate = try await service.filteredEvents(
                EventFilterQuery(onOrAfterDate: lateDate.addingTimeInterval(-3600)),
                requesterID: nil
            )
            XCTAssertEqual(byDate.count, 1)
            XCTAssertEqual(byDate.first?.cityAddress, "Paris, France")

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
            let eventDate = Date().addingTimeInterval(7200)
            let request = makeEventRequest(title: "Detail Test Event", date: eventDate, venueAddress: "Some Venue, Some City")
            let event = try await service.createEvent(request, hostUserID: try host.requireID())
            _ = try await service.join(event, userID: try attendee.requireID())

            let dto = try await service.fullDTO(for: event, requesterID: try attendee.requireID())
            XCTAssertEqual(dto.title, "Detail Test Event")
            XCTAssertEqual(dto.description, "Test event")
            XCTAssertEqual(dto.date.timeIntervalSince1970, eventDate.timeIntervalSince1970, accuracy: 0.001)
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
                .filter(\.$user.$id == attendee.requireID())
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

    /// M4 acceptance criterion #6, the part a unit test can actually cover:
    /// confirms `partials/event-fragment.leaf` renders without error and
    /// with the right content. This is exactly the failure mode a plain
    /// `swift build` can't catch — Leaf template errors only surface at
    /// render time. Rendering the join/leave/cancel HTTP routes themselves
    /// end-to-end would need a simulated authenticated session, which
    /// isn't available here (sign-in is OAuth-only — no password/test
    /// login route — and M2's real Apple/Google credentials aren't set up
    /// in this environment either), so this renders the fragment template
    /// directly instead of round-tripping through HTTP.
    func testEventFragmentPartialRenders() async throws {
        try await withApp { app in
            let host = try await makeUser(db: app.db, email: "fragment-host@example.com")
            let attendee = try await makeUser(db: app.db, email: "fragment-attendee@example.com")
            let service = EventService(db: app.db)
            let event = try await service.createEvent(makeEventRequest(title: "Fragment Test Event"), hostUserID: try host.requireID())
            _ = try await service.join(event, userID: try attendee.requireID())

            let dto = try await service.fullDTO(for: event, requesterID: try attendee.requireID())
            let req = Request(application: app, on: app.eventLoopGroup.any())
            let view = try await req.view.render("partials/event-fragment", EventWebController.EventFragmentContext(
                event: dto,
                isSignedIn: true,
                canManage: false
            ))
            let html = String(buffer: view.data)

            XCTAssertTrue(html.contains(#"id="event-fragment""#), "Fragment root element missing.")
            XCTAssertTrue(html.contains("Attendees (1)"), "Attendee count not rendered correctly.")
            XCTAssertTrue(html.contains("/events/\(try event.requireID())/leave"), "Attending user should see a Leave form, not Join.")
            XCTAssertFalse(html.contains("Cancel event"), "canManage: false should hide the cancel button.")

            // Also render the full page that #extends this same partial —
            // event-detail.leaf's own rendering isn't exercised by any
            // other test, and it's exactly this kind of Leaf wiring bug
            // (a literal '#' in an hx-target value getting misparsed as a
            // tag) that only surfaces at render time, never at `swift
            // build`. Caught and fixed one exactly like it in the partial
            // above before this test was added — this half confirms the
            // #extend call site itself is equally clean.
            let pageView = try await req.view.render("pages/event-detail", EventWebController.EventDetailPageContext(
                title: dto.title,
                event: dto,
                isSignedIn: true,
                canManage: false,
                chatHistory: []
            ))
            let pageHTML = String(buffer: pageView.data)
            XCTAssertTrue(pageHTML.contains(#"id="event-fragment""#), "Full page should include the extended fragment.")
            XCTAssertTrue(pageHTML.contains("Fragment Test Event"), "Full page should show the event title.")
        }
    }

    // MARK: - PR #3 independent-review follow-up

    /// Regression test for a finding from PR #3's independent code review:
    /// `EventWebController.respondWithEventUpdate` renders the full event
    /// (title/venue/description/attendee list) directly in the response to
    /// `POST /events/:id/leave` when the request carries the `HX-Request`
    /// header. Before this fix, `EventService.leave` — unlike `join` and
    /// `detail`, which both call `assertVisible` first — never checked
    /// visibility, so a signed-in user who was never a member of a private
    /// group could fetch that group's private event details simply by
    /// guessing/observing the event's UUID and POSTing to `/leave` (a
    /// harmless no-op attendee-row delete either way). This confirms
    /// `EventService.leave` now rejects a non-member/non-attendee the same
    /// way `join` and `detail` already do.
    func testNonMemberCannotLeavePrivateGroupEventOrLeakDetails() async throws {
        try await withApp { app in
            let owner = try await makeUser(db: app.db, email: "leak-owner@example.com", plan: .premium)
            // `EventService.assertVisible` gates on the *event's* own
            // `.private` visibility plus group membership, not the
            // group's own `visibility` field (public/inviteOnly, neither
            // of which is "private") — so the group itself can stay at
            // its default visibility here.
            let group = Group(name: "Private Circle", slug: "private-circle-\(UUID())", description: "Members only", ownerID: try owner.requireID())
            try await group.save(on: app.db)
            let membership = GroupMembership(groupID: try group.requireID(), userID: try owner.requireID(), role: .owner)
            try await membership.save(on: app.db)

            let service = EventService(db: app.db)
            let event = try await service.createEvent(
                CreateEventRequest(
                    title: "Members-only meetup",
                    description: "Sensitive details",
                    category: .culture,
                    date: Date().addingTimeInterval(3600),
                    cityAddress: "Test City", cityLat: 0, cityLng: 0,
                    venueAddress: "Secret Venue", venueLat: 0, venueLng: 0,
                    hostGroupID: try group.requireID(),
                    visibility: .private
                ),
                hostUserID: try owner.requireID()
            )

            // A user who was never a member of the group, and never joined
            // the event, must be rejected — not have the event silently
            // "left" and its details handed back.
            let outsider = try await makeUser(db: app.db, email: "leak-outsider@example.com")
            do {
                _ = try await service.leave(event, userID: try outsider.requireID())
                XCTFail("A non-member/non-attendee should not be able to \"leave\" a private group event they can't see.")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "not_found")
            }

            // An existing attendee must still be able to leave even if they
            // can no longer see the event (e.g. removed from the group) —
            // the fix must not trade the leak for a new way to strand a
            // dangling attendee row.
            let formerMember = try await makeUser(db: app.db, email: "leak-former-member@example.com")
            let formerMembership = GroupMembership(groupID: try group.requireID(), userID: try formerMember.requireID(), role: .member)
            try await formerMembership.save(on: app.db)
            _ = try await service.join(event, userID: try formerMember.requireID())
            try await formerMembership.delete(on: app.db)

            let stillLeaves = try await service.leave(event, userID: try formerMember.requireID())
            XCTAssertEqual(try stillLeaves.requireID(), try event.requireID())
            let remainingAttendance = try await EventAttendee.query(on: app.db)
                .filter(\.$event.$id == event.requireID())
                .filter(\.$user.$id == formerMember.requireID())
                .count()
            XCTAssertEqual(remainingAttendance, 0, "A former member who leaves should have their attendee row removed, not left dangling.")
        }
    }

    // MARK: - M2 verification

    /// PR #2's independent review flagged this as missing: an invalid
    /// provider token must be rejected as `.invalidProviderToken`, never
    /// crash or (worse) silently authenticate. There's no way to forge a
    /// token Google's own verification would accept, so this exercises the
    /// real failure path end-to-end against Google's `tokeninfo` endpoint
    /// rather than mocking it away — a garbage string is exactly what a
    /// malicious or buggy client could send `POST /api/v1/auth/google`.
    /// Requires network access to `oauth2.googleapis.com`.
    func testGoogleIdentityTokenVerifierRejectsInvalidToken() async throws {
        try await withApp { app in
            do {
                _ = try await GoogleIdentityTokenVerifier.verify(
                    idToken: "not-a-real-token",
                    expectedAudience: "irrelevant-audience-for-this-test",
                    client: app.client
                )
                XCTFail("A garbage token should have been rejected, not verified.")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "invalid_provider_token")
            }
        }
    }

    /// Found by a real browser click-through after M2's Google sign-in
    /// verification: the nav never flipped to the signed-in state, even
    /// right after a successful sign-in redirected to /events. Root cause
    /// was that `GET /events` and `GET /events/:id` sat outside
    /// `User.sessionAuthenticator()` entirely (only the write routes had
    /// it), so `req.auth.get(User.self)` was always nil there regardless
    /// of a valid session cookie, and `isSignedIn` was hard-wired false.
    /// This creates a real session the same way `SessionsMiddleware`
    /// does (there's no test login route — sign-in is OAuth-only, see
    /// `testEventFragmentPartialRenders`) and round-trips it through a
    /// real HTTP request, so it actually exercises the route/middleware
    /// wiring rather than just the template.
    func testSignedInSessionFlipsEventsNavToSignedInState() async throws {
        try await withApp { app in
            let user = try await makeUser(db: app.db, email: "nav-session@example.com")

            var data = SessionData()
            data["_UserSession"] = try user.requireID().uuidString
            let sessionKey = SessionID(string: UUID().uuidString)
            try await SessionRecord(key: sessionKey, data: data).create(on: app.db)

            try await app.test(.GET, "/events", headers: ["Cookie": "vapor-session=\(sessionKey.string)"]) { res async in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertTrue(html.contains(#"action="/logout""#), "A signed-in visitor should see the Sign out form in the nav.")
                XCTAssertFalse(html.contains(">Sign in<"), "A signed-in visitor should not still see the Sign in link.")
            }

            // And a request with no cookie at all still gets the signed-out nav.
            try await app.test(.GET, "/events") { res async in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertTrue(html.contains(">Sign in<"), "An anonymous visitor should see the Sign in link.")
                XCTAssertFalse(html.contains(#"action="/logout""#), "An anonymous visitor should not see a Sign out form.")
            }
        }
    }

    /// Independent review of this PR's fix flagged that it silently
    /// restores more than just the nav: before the fix, `GET /events/:id`
    /// always saw `requesterID == nil` too (same root cause), so
    /// `EventService.assertVisible`/`assertCanManage` were being
    /// evaluated as fully anonymous for *every* visitor — meaning a
    /// private group event's own members couldn't view it via the direct
    /// URL, and a host could never see their own "Cancel event" control,
    /// regardless of being signed in. This pins down both now-correct
    /// cases (and the still-correctly-rejected outsider/anonymous cases)
    /// so they don't silently regress again.
    func testSignedInSessionRestoresGroupEventVisibilityAndManageControls() async throws {
        try await withApp { app in
            let owner = try await makeUser(db: app.db, email: "detail-owner@example.com", plan: .premium)
            let member = try await makeUser(db: app.db, email: "detail-member@example.com")
            let outsider = try await makeUser(db: app.db, email: "detail-outsider@example.com")

            let group = Group(name: "Detail Test Group", slug: "detail-test-group-\(UUID())", description: "Members only", ownerID: try owner.requireID())
            try await group.save(on: app.db)
            try await GroupMembership(groupID: try group.requireID(), userID: try owner.requireID(), role: .owner).save(on: app.db)
            try await GroupMembership(groupID: try group.requireID(), userID: try member.requireID(), role: .member).save(on: app.db)

            let service = EventService(db: app.db)
            let event = try await service.createEvent(
                CreateEventRequest(
                    title: "Private Group Detail Event",
                    description: "Sensitive details",
                    category: .culture,
                    date: Date().addingTimeInterval(3600),
                    cityAddress: "Test City", cityLat: 0, cityLng: 0,
                    venueAddress: "Secret Venue", venueLat: 0, venueLng: 0,
                    hostGroupID: try group.requireID(),
                    visibility: .private
                ),
                hostUserID: try owner.requireID()
            )
            let path = "/events/\(try event.requireID())"

            func cookie(for user: User) async throws -> String {
                var data = SessionData()
                data["_UserSession"] = try user.requireID().uuidString
                let key = SessionID(string: UUID().uuidString)
                try await SessionRecord(key: key, data: data).create(on: app.db)
                return "vapor-session=\(key.string)"
            }

            // The owner (host) sees the event and their own manage control.
            try await app.test(.GET, path, headers: ["Cookie": try await cookie(for: owner)]) { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(res.body.string.contains("Cancel event"), "The host should see the manage/cancel control on their own event.")
            }

            // A plain group member sees the event but not manage controls
            // — they're a member, not the owner/moderator.
            try await app.test(.GET, path, headers: ["Cookie": try await cookie(for: member)]) { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(res.body.string.contains("Private Group Detail Event"), "A group member should be able to view their group's private event.")
                XCTAssertFalse(res.body.string.contains("Cancel event"), "A plain member is not the host — no manage control.")
            }

            // A signed-in outsider (real session, just not a group member)
            // still gets rejected — assertVisible throws APIError.notFound
            // either way. NOTE: on this web (non-/api/v1) path, that comes
            // back as a 500, not a 404 — APIError doesn't conform to
            // AbortError, so Vapor's default ErrorMiddleware falls through
            // to its generic-500 case. This is the same pre-existing,
            // already-tracked gap noted in MILESTONES.md's M4 section
            // (APIErrorMiddleware only wraps /api/v1); asserting the real
            // status here (rather than the "should be" 404) so this test
            // stays honest, and so a future fix for that gap has to come
            // back and update this assertion rather than silently pass.
            // What actually matters and IS correctly enforced either way:
            // the response never contains the event's title/venue/details.
            try await app.test(.GET, path, headers: ["Cookie": try await cookie(for: outsider)]) { res async in
                XCTAssertEqual(res.status, .internalServerError, "A signed-in non-member must not see a private group event either (see note above on the status code itself).")
                XCTAssertFalse(res.body.string.contains("Private Group Detail Event"), "A rejected outsider must never see the event's details, whatever the status code.")
            }

            // And a fully anonymous visitor, same rejection, same caveat.
            try await app.test(.GET, path) { res async in
                XCTAssertEqual(res.status, .internalServerError, "An anonymous visitor must not see a private group event either (see note above).")
                XCTAssertFalse(res.body.string.contains("Private Group Detail Event"), "An anonymous visitor must never see the event's details, whatever the status code.")
            }
        }
    }
    // MARK: - M5 verification

    /// M5 acceptance criterion #2: a sent message persists to ChatMessage,
    /// and the DTO conversion carries the sender's current displayName/
    /// photoURL (not a snapshot frozen at send time — matches the
    /// "Deleted user" handling called out in CreateChatMessage's
    /// migration comment).
    func testChatServiceSendPersistsMessageWithSenderDisplayInfo() async throws {
        try await withApp { app in
            let host = try await makeUser(db: app.db, email: "chat-host@example.com")
            let sender = try await makeUser(db: app.db, email: "chat-sender@example.com")
            let service = EventService(db: app.db)
            let event = try await service.createEvent(makeEventRequest(title: "Chat Test Event"), hostUserID: try host.requireID())

            let chat = ChatService(db: app.db)
            let message = try await chat.send(
                SendChatMessageRequest(text: "hello from the test suite"),
                eventID: try event.requireID(),
                userID: try sender.requireID()
            )

            let dto = try message.toDTO()
            XCTAssertEqual(dto.text, "hello from the test suite")
            XCTAssertEqual(dto.userID, try sender.requireID())
            XCTAssertEqual(dto.displayName, sender.displayName)
            XCTAssertNil(dto.parentID)

            let persisted = try await ChatMessage.query(on: app.db)
                .filter(\.$event.$id == event.requireID())
                .count()
            XCTAssertEqual(persisted, 1, "The message must actually be in the database, not just returned.")
        }
    }

    /// M5 acceptance criterion #3: replies store the correct parentID and
    /// render nested — this pins down the "one level only" part of that
    /// criterion, which is easy to silently violate later (a reply to a
    /// reply should be rejected, not silently flattened or allowed to
    /// nest arbitrarily deep).
    func testChatServiceRejectsReplyToAReply() async throws {
        try await withApp { app in
            let host = try await makeUser(db: app.db, email: "chat-thread-host@example.com")
            let a = try await makeUser(db: app.db, email: "chat-thread-a@example.com")
            let b = try await makeUser(db: app.db, email: "chat-thread-b@example.com")
            let service = EventService(db: app.db)
            let event = try await service.createEvent(makeEventRequest(title: "Threading Test Event"), hostUserID: try host.requireID())

            let chat = ChatService(db: app.db)
            let root = try await chat.send(SendChatMessageRequest(text: "root message"), eventID: try event.requireID(), userID: try a.requireID())
            let reply = try await chat.send(
                SendChatMessageRequest(text: "a reply", parentID: try root.requireID()),
                eventID: try event.requireID(),
                userID: try b.requireID()
            )
            XCTAssertEqual(reply.$parent.id, try root.requireID())

            do {
                _ = try await chat.send(
                    SendChatMessageRequest(text: "a reply to a reply", parentID: try reply.requireID()),
                    eventID: try event.requireID(),
                    userID: try a.requireID()
                )
                XCTFail("A reply to a reply should be rejected — only one level of threading is supported.")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "reply_too_deep")
            }
        }
    }

    /// M5 acceptance criteria #4/#5: chat access is exactly as restricted
    /// as the event itself — an unauthenticated (nil requesterID) visitor
    /// and a signed-in non-member of a private group event's hosting group
    /// are both rejected, reusing the same assertVisible a stranger already
    /// gets from EventWebController.detail()/EventService.join(). This is
    /// the service-level authorization check; the actual WebSocket upgrade
    /// rejection (shouldUpgrade throwing) needs a real browser/socket
    /// client to verify end-to-end and is a human server-checkpoint item,
    /// not something XCTVapor can drive directly (there's no WebSocket
    /// test client wired into this suite).
    func testChatServiceRejectsAccessToPrivateGroupEventForNonMembers() async throws {
        try await withApp { app in
            let owner = try await makeUser(db: app.db, email: "chat-access-owner@example.com", plan: .premium)
            let member = try await makeUser(db: app.db, email: "chat-access-member@example.com")
            let outsider = try await makeUser(db: app.db, email: "chat-access-outsider@example.com")

            let group = Group(name: "Chat Access Group", slug: "chat-access-group-\(UUID())", description: "Members only", ownerID: try owner.requireID())
            try await group.save(on: app.db)
            try await GroupMembership(groupID: try group.requireID(), userID: try owner.requireID(), role: .owner).save(on: app.db)
            try await GroupMembership(groupID: try group.requireID(), userID: try member.requireID(), role: .member).save(on: app.db)

            let service = EventService(db: app.db)
            let event = try await service.createEvent(
                CreateEventRequest(
                    title: "Private Chat Event",
                    description: "Members only",
                    category: .culture,
                    date: Date().addingTimeInterval(3600),
                    cityAddress: "Test City", cityLat: 0, cityLng: 0,
                    venueAddress: "Secret Venue", venueLat: 0, venueLng: 0,
                    hostGroupID: try group.requireID(),
                    visibility: .private
                ),
                hostUserID: try owner.requireID()
            )

            let chat = ChatService(db: app.db)

            // A member can access.
            try await chat.assertCanAccessChat(event, requesterID: try member.requireID())

            // A signed-in non-member cannot.
            do {
                try await chat.assertCanAccessChat(event, requesterID: try outsider.requireID())
                XCTFail("A non-member must not be able to access a private group event's chat.")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "not_found")
            }

            // Nor can a fully anonymous visitor.
            do {
                try await chat.assertCanAccessChat(event, requesterID: nil)
                XCTFail("An anonymous visitor must not be able to access a private group event's chat.")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "not_found")
            }
        }
    }

    /// M5 acceptance criteria #2/#6: history comes back oldest-first and
    /// includes replies alongside root messages (the client is what
    /// arranges them into a thread visually; the service just returns the
    /// full ordered set) — this is what both a fresh page load and a
    /// reconnect-after-drop use.
    func testChatServiceHistoryReturnsMessagesOldestFirst() async throws {
        try await withApp { app in
            let host = try await makeUser(db: app.db, email: "chat-history-host@example.com")
            let service = EventService(db: app.db)
            let event = try await service.createEvent(makeEventRequest(title: "History Test Event"), hostUserID: try host.requireID())

            let chat = ChatService(db: app.db)
            let first = try await chat.send(SendChatMessageRequest(text: "first"), eventID: try event.requireID(), userID: try host.requireID())
            let second = try await chat.send(SendChatMessageRequest(text: "second"), eventID: try event.requireID(), userID: try host.requireID())

            let history = try await chat.history(eventID: try event.requireID())
            XCTAssertEqual(history.map(\.text), ["first", "second"])
            XCTAssertEqual(try history.map { try $0.requireID() }, [try first.requireID(), try second.requireID()])
        }
    }

    /// M5's own #for-loop template (pages/event-detail.leaf) and the
    /// live-broadcast partial (partials/chat-message-oob.leaf) both
    /// render this exact markup independently (see that partial's doc
    /// comment on why it's duplicated rather than shared via #extend) —
    /// this renders the *page* separately from the *live* partial and
    /// checks both actually render without a Leaf error, since that's
    /// exactly the kind of bug (a literal '#' misparsed as a tag) that
    /// only surfaces at render time, per M4's testEventFragmentPartialRenders.
    func testChatUIRendersWithAndWithoutHistory() async throws {
        try await withApp { app in
            let host = try await makeUser(db: app.db, email: "chat-ui-host@example.com")
            let sender = try await makeUser(db: app.db, email: "chat-ui-sender@example.com")
            let service = EventService(db: app.db)
            let event = try await service.createEvent(makeEventRequest(title: "Chat UI Test Event"), hostUserID: try host.requireID())

            let chat = ChatService(db: app.db)
            let root = try await chat.send(SendChatMessageRequest(text: "root message"), eventID: try event.requireID(), userID: try sender.requireID())
            _ = try await chat.send(SendChatMessageRequest(text: "a reply", parentID: try root.requireID()), eventID: try event.requireID(), userID: try host.requireID())

            let dto = try await service.fullDTO(for: event, requesterID: try host.requireID())
            let chatMessages = try await chat.history(eventID: try event.requireID())
            let chatHistory = try chatMessages.map { try $0.toDTO() }

            let req = Request(application: app, on: app.eventLoopGroup.any())
            let view = try await req.view.render("pages/event-detail", EventWebController.EventDetailPageContext(
                title: dto.title,
                event: dto,
                isSignedIn: true,
                canManage: true,
                chatHistory: chatHistory
            ))
            let html = String(buffer: view.data)
            XCTAssertTrue(html.contains(#"id="chat-messages""#), "Chat container missing from the page.")
            XCTAssertTrue(html.contains("root message"), "Root message text missing.")
            XCTAssertTrue(html.contains("a reply"), "Reply text missing.")
            XCTAssertTrue(html.contains("ml-6 border-l-2"), "Reply should render with the nested-reply indent class.")
            XCTAssertTrue(html.contains(#"ws-connect="/events/\#(try event.requireID())/chat/ws""#), "Chat socket connect URL missing or wrong.")

            // And the empty-history case (no messages yet) must render
            // cleanly too — an empty #for loop, not a template error.
            let emptyView = try await req.view.render("pages/event-detail", EventWebController.EventDetailPageContext(
                title: dto.title,
                event: dto,
                isSignedIn: false,
                canManage: false,
                chatHistory: []
            ))
            let emptyHTML = String(buffer: emptyView.data)
            XCTAssertTrue(emptyHTML.contains(#"id="chat-messages""#), "Chat container missing from the empty-history page.")
            XCTAssertTrue(emptyHTML.contains("Sign in</a> to join the chat"), "Signed-out visitor should see the sign-in prompt instead of a compose form.")
        }
    }
}
