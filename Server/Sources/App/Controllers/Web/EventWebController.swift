import Fluent
import Vapor
import ExpatEventsAPI

/// The server-rendered public site's event pages (architecture §6, M4).
///
/// Join/leave/cancel respond two ways depending on the request: an
/// htmx-originated one (identified by the `HX-Request` header, set
/// automatically by every htmx-driven form — see
/// `partials/event-fragment.leaf`) gets back just the updated
/// action-bar/attendee-list fragment, swapped in place with no reload
/// (M4 acceptance criterion #6); anything else (a JS-disabled browser
/// posting the plain `<form>`, which keeps its `action`/`method` as a
/// fallback) gets the previous full-page redirect. The Alpine/Tailwind/
/// Flowbite visual layer beyond that is still the explicit follow-up
/// noted in MILESTONES.md. The authorization and plan-limit rules below
/// (shared with `EventAPIController` via `EventService`) are fully
/// enforced either way.
struct EventWebController: RouteCollection {
    struct EventsPageContext: Encodable {
        let title = "Events"
        let events: [EventSummaryDTO]
        let filter: EventFilterQuery
        let isSignedIn: Bool
        /// The next page's URL, with the current filters kept, when there
        /// is one -- what the "Load more events" button fetches. nil on
        /// the last page.
        let nextPageURL: String?
    }

    /// One page of event cards plus the next "Load more" button: what an
    /// htmx "Load more" request gets back (`partials/event-cards.leaf`).
    struct EventCardsContext: Encodable {
        let events: [EventSummaryDTO]
        let nextPageURL: String?
    }

    struct EventDetailPageContext: Encodable {
        let title: String
        let event: EventDTO
        let isSignedIn: Bool
        let canManage: Bool
        /// M5: this is the *only* place chat history gets rendered — the
        /// chat WebSocket (ChatWebController.handle) deliberately does not
        /// replay history on connect (an earlier version did; removed after
        /// a human server-checkpoint found it duplicated every message on
        /// every reload, since a fresh socket opens on every full page
        /// load and this history was already rendered into that same
        /// page). This field alone is what satisfies M5 acceptance
        /// criterion #6 ("reload... still shows full history").
        let chatHistory: [ChatMessageDTO]
    }

    /// Same shape as `EventDetailPageContext` minus the page-level `title`
    /// — this is what `partials/event-fragment.leaf` actually reads,
    /// whether it's rendered inline (via `#extend`, sharing the full
    /// page's context) or standalone (an htmx fragment response below).
    struct EventFragmentContext: Encodable {
        let event: EventDTO
        let isSignedIn: Bool
        let canManage: Bool
    }

    /// One `<option>`/radio in the create form. `isSelected` is
    /// precomputed so the template never compares values itself (this
    /// codebase's no-Leaf-equality convention).
    struct FormOption: Encodable {
        let value: String
        let label: String
        let isSelected: Bool
    }

    /// The create-event form, blank or re-filled with what was typed when
    /// the server rejected it (`errorMessage` says why).
    struct EventFormContext: Encodable {
        let title = "Host an event"
        let isSignedIn = true
        let categories: [FormOption]
        /// "Myself" first, then every group the user owns or moderates.
        /// Only shown when there's at least one group.
        let hostOptions: [FormOption]
        let hasGroupHostOptions: Bool
        let isPrivate: Bool
        let isPremium: Bool
        let eventTitle: String
        let eventDescription: String
        let date: String
        let cityAddress: String
        let venueAddress: String
        let attendeeLimit: String
        let errorMessage: String?
    }

    struct ErrorPageContext: Encodable {
        let title = "Error"
        let message: String
    }

    func boot(routes: RoutesBuilder) throws {
        // Signed-out visitors can browse events, so these two stay outside
        // guardMiddleware() — but they still need the session authenticator
        // run in front of them, or req.auth.get(User.self) never gets
        // populated from a valid session cookie and isSignedIn is hard-wired
        // false on every page load, even for someone who just signed in.
        // (Found via a real click-through: the nav never flipped to
        // "Sign out" because of exactly this.)
        let optionallyAuthenticated = routes.grouped(User.activeSessionAuthenticator())
        optionallyAuthenticated.get("events", use: dashboard)
        optionallyAuthenticated.get("events", ":eventID", use: detail)

        let authenticated = routes.grouped(User.activeSessionAuthenticator(), User.guardMiddleware(), NotSuspendedMiddleware())
        authenticated.get("events", "new", use: newForm)
        authenticated.post("events", use: create)
        authenticated.post("events", ":eventID", "cancel", use: cancel)
        authenticated.post("events", ":eventID", "join", use: join)
        authenticated.post("events", ":eventID", "leave", use: leave)
    }

    /// `/events`. A normal request renders the whole page with the first
    /// (or requested) page of events; an htmx request -- the "Load more
    /// events" button -- gets just the next page's cards and the next
    /// button (architecture §6's `GET /events?page=N`).
    @Sendable
    func dashboard(req: Request) async throws -> Response {
        let filter = try req.query.decode(EventFilterQuery.self)
        let requesterID = req.auth.get(User.self).flatMap { try? $0.requireID() }
        let service = EventService(db: req.db)
        let page = try await service.filteredEventsPage(filter, requesterID: requesterID)
        var summaries: [EventSummaryDTO] = []
        for event in page.events {
            summaries.append(try await service.summaryDTO(for: event, requesterID: requesterID))
        }
        let currentPage = EventService.clampedPage(filter)
        let nextPageURL = page.hasMore && currentPage < EventService.maxPage
            ? Self.pageURL(for: filter, page: currentPage + 1)
            : nil

        let response: Response
        if req.headers.first(name: "HX-Request") != nil {
            response = try await req.view.render("partials/event-cards", EventCardsContext(
                events: summaries,
                nextPageURL: nextPageURL
            )).encodeResponse(for: req)
        } else {
            response = try await req.view.render("pages/events", EventsPageContext(
                events: summaries,
                filter: filter,
                isSignedIn: requesterID != nil,
                nextPageURL: nextPageURL
            )).encodeResponse(for: req)
        }
        // Same URL, two different bodies: tell caches (and htmx's own
        // history cache) the response depends on the HX-Request header.
        response.headers.replaceOrAdd(name: .vary, value: "HX-Request")
        return response
    }

    /// `/events?…&page=N` with every filter currently applied kept, so
    /// "Load more" continues the same filtered list.
    static func pageURL(for filter: EventFilterQuery, page: Int) -> String {
        var items: [URLQueryItem] = []
        if let category = filter.category { items.append(.init(name: "category", value: category.rawValue)) }
        if let city = filter.city { items.append(.init(name: "city", value: city)) }
        if let venue = filter.venue { items.append(.init(name: "venue", value: venue)) }
        if let hostUserID = filter.hostUserID { items.append(.init(name: "hostUserID", value: hostUserID.uuidString)) }
        if let hostGroupID = filter.hostGroupID { items.append(.init(name: "hostGroupID", value: hostGroupID.uuidString)) }
        // Query-string dates decode as seconds since 1970 (Vapor's default).
        if let onOrAfterDate = filter.onOrAfterDate {
            items.append(.init(name: "onOrAfterDate", value: String(onOrAfterDate.timeIntervalSince1970)))
        }
        items.append(.init(name: "page", value: String(page)))
        // Encoded by hand rather than with URLComponents.queryItems, which
        // leaves "+" as-is -- and Vapor's query parser reads "+" as a
        // space, so a city like "A+B" would turn into "A B" from page 2 on.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#?/")
        // Explicitly `String`: unannotated, Swift inferred SQLKit's
        // SQLQueryString here (SQLKit adds a joined(separator:) for it),
        // and the URL was built through SQL-interpolation code paths. The
        // compiler flagged it with a deprecation warning.
        let pairs: [String] = items.map { (item: URLQueryItem) -> String in
            let value = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return item.name + "=" + value
        }
        let query: String = pairs.joined(separator: "&")
        return "/events?\(query)"
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
        // Chat visibility is intentionally the exact same assertVisible
        // call already made above for the event itself (M5 criteria #4/#5
        // reuse EventService.assertVisible via ChatService — see its own
        // doc comment) — no separate check needed here.
        let chatMessages = try await ChatService(db: req.db).history(eventID: try event.requireID())
        let chatHistory = try chatMessages.map { try $0.toDTO() }
        return try await req.view.render("pages/event-detail", EventDetailPageContext(
            title: dto.title,
            event: dto,
            isSignedIn: user != nil,
            canManage: canManage,
            chatHistory: chatHistory
        ))
    }

    @Sendable
    func newForm(req: Request) async throws -> View {
        let user = try req.auth.require(User.self)
        return try await renderForm(req: req, user: user, input: nil, errorMessage: nil)
    }

    /// Everything arrives as text and is parsed here, so a bad value
    /// re-renders the form with a message instead of failing the whole
    /// request: `date` is the `datetime-local` value (see
    /// `EventDateParsing`; decoding it straight into a `Date` is what used
    /// to break every real submission), and an empty `hostGroupID` /
    /// `attendeeLimit` means "Myself" / "plan default".
    struct EventFormInput: Content {
        let title: String
        let description: String
        let category: String
        let date: String
        let cityAddress: String
        let cityLat: Double?
        let cityLng: Double?
        let venueAddress: String
        let venueLat: Double?
        let venueLng: Double?
        let visibility: String?
        let hostGroupID: String?
        let attendeeLimit: String?
    }

    @Sendable
    func create(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let input = try req.content.decode(EventFormInput.self)
        do {
            let request = try Self.createRequest(from: input)
            let event = try await EventService(db: req.db).createEvent(request, hostUserID: try user.requireID())
            return req.redirect(to: "/events/\(try event.requireID())")
        } catch let error as APIError {
            req.logger.notice("Event creation rejected: \(error.code) — \(error.message)")
            return try await renderForm(req: req, user: user, input: input, errorMessage: error.message)
                .encodeResponse(status: .badRequest, for: req)
        }
    }

    static func createRequest(from input: EventFormInput) throws -> CreateEventRequest {
        guard let category = EventCategory(rawValue: input.category) else {
            throw APIError(code: "invalid_category", message: "Choose a category.")
        }
        guard let date = EventDateParsing.parse(input.date) else {
            throw APIError(code: "invalid_date", message: "Enter the event's date and time.")
        }
        let hostGroupIDText = input.hostGroupID?.trimmingCharacters(in: .whitespaces) ?? ""
        var hostGroupID: UUID?
        if !hostGroupIDText.isEmpty {
            guard let id = UUID(uuidString: hostGroupIDText) else {
                throw APIError(code: "invalid_host", message: "Choose who's hosting.")
            }
            hostGroupID = id
        }
        let limitText = input.attendeeLimit?.trimmingCharacters(in: .whitespaces) ?? ""
        var attendeeLimit: Int?
        if !limitText.isEmpty {
            guard let limit = Int(limitText) else {
                throw APIError(code: "invalid_attendee_limit", message: "The attendee limit must be a whole number.")
            }
            attendeeLimit = limit
        }
        let visibility = input.visibility.flatMap(EventVisibility.init(rawValue:)) ?? .public
        return CreateEventRequest(
            title: input.title,
            description: input.description,
            category: category,
            date: date,
            cityAddress: input.cityAddress,
            cityLat: input.cityLat ?? 0,
            cityLng: input.cityLng ?? 0,
            venueAddress: input.venueAddress,
            venueLat: input.venueLat ?? 0,
            venueLng: input.venueLng ?? 0,
            hostGroupID: hostGroupID,
            visibility: visibility,
            attendeeLimit: attendeeLimit
        )
    }

    private func renderForm(req: Request, user: User, input: EventFormInput?, errorMessage: String?) async throws -> View {
        let userID = try user.requireID()
        let groups = try await GroupService(db: req.db).manageableGroups(for: userID)
        let isPremium = try await PlanLimitsService(db: req.db).subscription(for: userID).isActivePremium
        let selectedCategory = input?.category ?? EventCategory.allCases.first?.rawValue ?? ""
        let selectedHost = input?.hostGroupID ?? ""
        var hostOptions = [FormOption(value: "", label: "Myself", isSelected: selectedHost.isEmpty)]
        for group in groups {
            let id = try group.requireID().uuidString
            hostOptions.append(FormOption(value: id, label: group.name, isSelected: id.caseInsensitiveCompare(selectedHost) == .orderedSame))
        }
        return try await req.view.render("pages/event-form", EventFormContext(
            categories: EventCategory.allCases.map {
                FormOption(value: $0.rawValue, label: $0.rawValue.capitalized, isSelected: $0.rawValue == selectedCategory)
            },
            hostOptions: hostOptions,
            hasGroupHostOptions: !groups.isEmpty,
            isPrivate: input?.visibility == EventVisibility.private.rawValue,
            isPremium: isPremium,
            eventTitle: input?.title ?? "",
            eventDescription: input?.description ?? "",
            date: input?.date ?? "",
            cityAddress: input?.cityAddress ?? "",
            venueAddress: input?.venueAddress ?? "",
            attendeeLimit: input?.attendeeLimit ?? "",
            errorMessage: errorMessage
        ))
    }

    @Sendable
    func cancel(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let event = try await eventOrNotFound(req)
        let updated = try await EventService(db: req.db).cancelEvent(event, requesterID: try user.requireID())
        return try await respondWithEventUpdate(req: req, event: updated)
    }

    @Sendable
    func join(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let event = try await eventOrNotFound(req)
        let updated = try await EventService(db: req.db).join(event, userID: try user.requireID())
        return try await respondWithEventUpdate(req: req, event: updated)
    }

    @Sendable
    func leave(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let event = try await eventOrNotFound(req)
        let updated = try await EventService(db: req.db).leave(event, userID: try user.requireID())
        return try await respondWithEventUpdate(req: req, event: updated)
    }

    /// M4 acceptance criterion #6. `req.auth.require` above already
    /// guarantees a signed-in user by the time any of the three callers
    /// reach here, so `isSignedIn` is always `true` in the fragment.
    private func respondWithEventUpdate(req: Request, event: Event) async throws -> Response {
        guard req.headers.first(name: "HX-Request") != nil else {
            return req.redirect(to: "/events/\(try event.requireID())")
        }
        let user = try req.auth.require(User.self)
        let requesterID = try user.requireID()
        let service = EventService(db: req.db)
        let dto = try await service.fullDTO(for: event, requesterID: requesterID)
        let canManage = (try? await service.assertCanManage(event, requesterID: requesterID)) != nil
        let view = try await req.view.render("partials/event-fragment", EventFragmentContext(
            event: dto,
            isSignedIn: true,
            canManage: canManage
        ))
        return try await view.encodeResponse(for: req)
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
