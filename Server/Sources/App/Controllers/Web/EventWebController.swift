import Fluent
import Vapor
import ExpatEventsAPI

/// The server-rendered public site's event pages (architecture §6, M4).
///
/// NOTE on scope: this renders full pages for every action, including
/// join/leave. The architecture doc's htmx design swaps just the
/// action-bar/attendee-count fragment in place (§6's endpoint map) for a
/// no-reload UX — that fragment-vs-full-page wiring, plus the Alpine/
/// Tailwind/Flowbite visual layer, is the explicit follow-up noted in
/// MILESTONES.md. The authorization and plan-limit rules below (shared
/// with `EventAPIController` via `EventService`) are fully enforced
/// either way.
struct EventWebController: RouteCollection {
    struct EventsPageContext: Encodable {
        let title = "Events"
        let events: [EventSummaryDTO]
        let filter: EventFilterQuery
        let isSignedIn: Bool
    }

    struct EventDetailPageContext: Encodable {
        let title: String
        let event: EventDTO
        let isSignedIn: Bool
        let canManage: Bool
    }

    struct NewEventPageContext: Encodable {
        let title = "Host an event"
        let categories: [String] = EventCategory.allCases.map(\.rawValue)
    }

    struct ErrorPageContext: Encodable {
        let title = "Error"
        let message: String
    }

    func boot(routes: RoutesBuilder) throws {
        routes.get("events", use: dashboard)
        routes.get("events", ":eventID", use: detail)

        let authenticated = routes.grouped(User.sessionAuthenticator(), User.guardMiddleware(), NotSuspendedMiddleware())
        authenticated.get("events", "new", use: newForm)
        authenticated.post("events", use: create)
        authenticated.post("events", ":eventID", "cancel", use: cancel)
        authenticated.post("events", ":eventID", "join", use: join)
        authenticated.post("events", ":eventID", "leave", use: leave)
    }

    @Sendable
    func dashboard(req: Request) async throws -> View {
        let filter = try req.query.decode(EventFilterQuery.self)
        let requesterID = req.auth.get(User.self).flatMap { try? $0.requireID() }
        let service = EventService(db: req.db)
        let events = try await service.filteredEvents(filter, requesterID: requesterID)
        var summaries: [EventSummaryDTO] = []
        for event in events {
            summaries.append(try await service.summaryDTO(for: event, requesterID: requesterID))
        }
        return try await req.view.render("pages/events", EventsPageContext(
            events: summaries,
            filter: filter,
            isSignedIn: requesterID != nil
        ))
    }

    @Sendable
    func detail(req: Request) async throws -> View {
        let user = req.auth.get(User.self)
        let requesterID = try? user?.requireID()
        let event = try await eventOrNotFound(req)
        let service = EventService(db: req.db)
        try await service.assertVisible(event, to: requesterID)
        let dto = try await service.fullDTO(for: event, requesterID: requesterID)
        let canManage = (try? await service.assertCanManage(event, requesterID: requesterID ?? UUID())) != nil
        return try await req.view.render("pages/event-detail", EventDetailPageContext(
            title: dto.title,
            event: dto,
            isSignedIn: user != nil,
            canManage: canManage
        ))
    }

    @Sendable
    func newForm(req: Request) async throws -> View {
        try await req.view.render("pages/event-form", NewEventPageContext())
    }

    struct EventFormInput: Content {
        let title: String
        let description: String
        let category: EventCategory
        let date: Date
        let cityAddress: String
        let cityLat: Double
        let cityLng: Double
        let venueAddress: String
        let venueLat: Double
        let venueLng: Double
        let visibility: EventVisibility?
    }

    @Sendable
    func create(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let input = try req.content.decode(EventFormInput.self)
        let request = CreateEventRequest(
            title: input.title,
            description: input.description,
            category: input.category,
            date: input.date,
            cityAddress: input.cityAddress,
            cityLat: input.cityLat,
            cityLng: input.cityLng,
            venueAddress: input.venueAddress,
            venueLat: input.venueLat,
            venueLng: input.venueLng,
            visibility: input.visibility ?? .public
        )
        let service = EventService(db: req.db)
        do {
            let event = try await service.createEvent(request, hostUserID: try user.requireID())
            return req.redirect(to: "/events/\(try event.requireID())")
        } catch let error as APIError {
            let view = try await req.view.render("pages/event-form", NewEventPageContext())
            return try await view.encodeResponse(status: .badRequest, for: req)
        }
    }

    @Sendable
    func cancel(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let event = try await eventOrNotFound(req)
        _ = try await EventService(db: req.db).cancelEvent(event, requesterID: try user.requireID())
        return req.redirect(to: "/events/\(try event.requireID())")
    }

    @Sendable
    func join(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let event = try await eventOrNotFound(req)
        _ = try await EventService(db: req.db).join(event, userID: try user.requireID())
        return req.redirect(to: "/events/\(try event.requireID())")
    }

    @Sendable
    func leave(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let event = try await eventOrNotFound(req)
        _ = try await EventService(db: req.db).leave(event, userID: try user.requireID())
        return req.redirect(to: "/events/\(try event.requireID())")
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
