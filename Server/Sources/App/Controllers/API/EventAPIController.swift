import Fluent
import Vapor
import ExpatEventsAPI

/// `/api/v1/events*` (architecture §7, M4). Shares `EventService` with
/// `EventWebController` so both surfaces enforce identical rules — the
/// plan's own QA guidance (§5) tests every milestone through both.
struct EventAPIController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let events = routes.grouped("api", "v1", "events")

        // Found while writing M6's tests for its own acceptance criterion
        // #5 ("check the listing, the direct URL, AND the JSON API"): these
        // two GET routes previously had no authenticator on them at all --
        // not even an optional one -- so `req.auth.get(User.self)` was
        // *always* nil here regardless of whether a caller sent a valid
        // Bearer token, the same class of bug M2's real click-through
        // checkpoint found on the web side (a route sitting outside the
        // authenticator entirely, not just outside a guard). The practical
        // effect was never a security leak (the wrong direction is "an
        // actual member gets treated as anonymous and denied," not "a
        // stranger gets treated as a member"), but it did mean a private
        // group event's own member could never see it via this API path
        // even with a valid token -- exactly the case criterion #5 asks to
        // be checked. `UserBearerAuthenticator` alone (no `.guardMiddleware()`)
        // is the same "optionally authenticated" shape
        // `EventWebController`'s own `optionallyAuthenticated` group uses
        // for its GET routes: it only acts when an `Authorization: Bearer`
        // header is actually present, and never throws on its own even on
        // a bad token (see its own doc comment) -- so applying it here
        // costs anonymous callers nothing.
        let optionallyAuthenticated = events.grouped(UserBearerAuthenticator())
        optionallyAuthenticated.get(use: list)
        optionallyAuthenticated.get(":eventID", use: detail)

        let authenticated = events.grouped(UserBearerAuthenticator(), User.guardMiddleware(), NotSuspendedMiddleware())
        authenticated.post(use: create)
        authenticated.patch(":eventID", use: update)
        authenticated.post(":eventID", "cancel", use: cancel)
        authenticated.post(":eventID", "join", use: join)
        authenticated.post(":eventID", "leave", use: leave)
    }

    @Sendable
    func list(req: Request) async throws -> [EventSummaryDTO] {
        let filter = try req.query.decode(EventFilterQuery.self)
        let requesterID = req.auth.get(User.self).flatMap { try? $0.requireID() }
        let service = EventService(db: req.db)
        let events = try await service.filteredEvents(filter, requesterID: requesterID)
        var summaries: [EventSummaryDTO] = []
        for event in events {
            summaries.append(try await service.summaryDTO(for: event, requesterID: requesterID))
        }
        return summaries
    }

    @Sendable
    func detail(req: Request) async throws -> EventDTO {
        let event = try await eventOrNotFound(req)
        let requesterID = req.auth.get(User.self).flatMap { try? $0.requireID() }
        let service = EventService(db: req.db)
        try await service.assertVisible(event, to: requesterID)
        return try await service.fullDTO(for: event, requesterID: requesterID)
    }

    @Sendable
    func create(req: Request) async throws -> EventDTO {
        let user = try req.auth.require(User.self)
        let body = try req.content.decode(CreateEventRequest.self)
        let service = EventService(db: req.db)
        let event = try await service.createEvent(body, hostUserID: try user.requireID())
        return try await service.fullDTO(for: event, requesterID: try user.requireID())
    }

    @Sendable
    func update(req: Request) async throws -> EventDTO {
        let user = try req.auth.require(User.self)
        let event = try await eventOrNotFound(req)
        let body = try req.content.decode(UpdateEventRequest.self)
        let service = EventService(db: req.db)
        let updated = try await service.updateEvent(event, with: body, requesterID: try user.requireID())
        return try await service.fullDTO(for: updated, requesterID: try user.requireID())
    }

    @Sendable
    func cancel(req: Request) async throws -> EventDTO {
        let user = try req.auth.require(User.self)
        let event = try await eventOrNotFound(req)
        let service = EventService(db: req.db)
        let cancelled = try await service.cancelEvent(event, requesterID: try user.requireID())
        return try await service.fullDTO(for: cancelled, requesterID: try user.requireID())
    }

    @Sendable
    func join(req: Request) async throws -> EventDTO {
        let user = try req.auth.require(User.self)
        let event = try await eventOrNotFound(req)
        let service = EventService(db: req.db)
        let joined = try await service.join(event, userID: try user.requireID())
        return try await service.fullDTO(for: joined, requesterID: try user.requireID())
    }

    @Sendable
    func leave(req: Request) async throws -> EventDTO {
        let user = try req.auth.require(User.self)
        let event = try await eventOrNotFound(req)
        let service = EventService(db: req.db)
        let left = try await service.leave(event, userID: try user.requireID())
        return try await service.fullDTO(for: left, requesterID: try user.requireID())
    }

    private func eventOrNotFound(_ req: Request) async throws -> Event {
        guard let idString = req.parameters.get("eventID"), let id = UUID(uuidString: idString),
              let event = try await EventService(db: req.db).find(id)
        else {
            throw Abort(.notFound)
        }
        return event
    }
}
