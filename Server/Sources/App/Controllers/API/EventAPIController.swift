import Fluent
import Vapor
import ExpatEventsAPI

/// `/api/v1/events*` (architecture §7, M4). Shares `EventService` with
/// `EventWebController` so both surfaces enforce identical rules — the
/// plan's own QA guidance (§5) tests every milestone through both.
struct EventAPIController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let events = routes.grouped("api", "v1", "events")
        events.get(use: list)
        events.get(":eventID", use: detail)

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
