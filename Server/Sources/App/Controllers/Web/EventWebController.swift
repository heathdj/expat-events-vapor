import Fluent
import Vapor
import ExpatEventsAPI
import ExpatEventsGeo

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
        let cards: [EventCardView]
        let filter: EventFilterQuery
        let isSignedIn: Bool
        /// All / Going / Hosting. Only shown to members (a visitor has
        /// nothing to be going to or hosting).
        let tabs: [TabLink]
        let showTabs: Bool
        let categories: [CategoryChip]
        let empty: EmptyState
        let hasNoEvents: Bool
        /// The next page's URL, with the current filters kept, when there
        /// is one -- what the "Load more events" button fetches. nil on
        /// the last page.
        let nextPageURL: String?
    }

    /// One page of event cards plus the next "Load more" button: what an
    /// htmx "Load more" request gets back (`partials/event-cards.leaf`),
    /// and, with a single card and no button, what a Join/Going click on
    /// a card gets back.
    struct EventCardsContext: Encodable {
        let cards: [EventCardView]
        let nextPageURL: String?
    }

    /// Everything one card on `/events` shows (theme Events PR). Built
    /// here rather than added to `EventSummaryDTO`, which the JSON API
    /// shares.
    struct EventCardView: Encodable {
        let event: EventSummaryDTO
        let url: String
        let imageURL: String
        let categoryLabel: String
        let descriptionPreview: String
        /// Up to three attendees' photo URLs (nil shows the default avatar).
        let attendeePhotos: [String?]
        let attendeeText: String
        let isSignedIn: Bool
        let isAttending: Bool
        let isHost: Bool
        /// Why a Join from this card didn't work (e.g. the event is full).
        let errorMessage: String?
    }

    struct TabLink: Encodable {
        let label: String
        let href: String
        let isActive: Bool
    }

    struct CategoryChip: Encodable {
        let label: String
        let href: String
        /// nil for "All".
        let imageURL: String?
        let isActive: Bool
    }

    struct EmptyState: Encodable {
        let message: String
        let actionLabel: String?
        let actionHref: String?
    }

    /// The tab a list shows (`?tab=`). Anything unknown is All.
    enum ListTab: String, CaseIterable {
        case all, going, hosting

        var label: String {
            switch self {
            case .all: "All"
            case .going: "Going"
            case .hosting: "Hosting"
            }
        }
    }

    struct TabQuery: Content {
        let tab: String?
    }

    struct CardViewQuery: Content {
        let view: String?
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
        let attendeeLimit: String
        let errorMessage: String?
        // The city and venue fields' keys, the same ones
        // `PlaceFieldContext.CityLeaf`/`VenueLeaf` give the field partials
        // when they're re-rendered on their own.
        let cityAddress: String
        let cityLat: String
        let cityLng: String
        let cityPlaceID: String
        let citySession: String
        let citySelected: Bool
        let cityError: String? = nil
        let venueAddress: String
        let venueLat: String
        let venueLng: String
        let venuePlaceID: String
        let venueSession: String
        let venueSelected: Bool
        let venueError: String? = nil
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
    /// button (architecture §6's `GET /events?page=N`). `?tab=going` /
    /// `?tab=hosting` narrow it to the member's own events (visitors
    /// always get All).
    @Sendable
    func dashboard(req: Request) async throws -> Response {
        let filter = try req.query.decode(EventFilterQuery.self)
        let requesterID = req.auth.get(User.self).flatMap { try? $0.requireID() }
        let tab: ListTab = requesterID == nil
            ? .all
            : ((try? req.query.decode(TabQuery.self))?.tab.flatMap(ListTab.init(rawValue:)) ?? .all)
        let scope: EventService.ListScope
        switch (tab, requesterID) {
        case (.going, let id?): scope = .going(id)
        case (.hosting, let id?): scope = .hosting(id)
        default: scope = .all
        }
        let service = EventService(db: req.db)
        let page = try await service.filteredEventsPage(filter, requesterID: requesterID, scope: scope)
        let cards = try await Self.cardViews(for: page.events, requesterID: requesterID, on: req.db)
        let currentPage = EventService.clampedPage(filter)
        let nextPageURL = page.hasMore && currentPage < EventService.maxPage
            ? Self.pageURL(for: filter, page: currentPage + 1, tab: tab)
            : nil

        let response: Response
        if req.headers.first(name: "HX-Request") != nil {
            response = try await req.view.render("partials/event-cards", EventCardsContext(
                cards: cards,
                nextPageURL: nextPageURL
            )).encodeResponse(for: req)
        } else {
            response = try await req.view.render("pages/events", EventsPageContext(
                cards: cards,
                filter: filter,
                isSignedIn: requesterID != nil,
                tabs: ListTab.allCases.map { option in
                    TabLink(label: option.label, href: Self.listURL(for: filter, tab: option), isActive: option == tab)
                },
                showTabs: requesterID != nil,
                categories: Self.categoryChips(for: filter, tab: tab),
                empty: Self.emptyState(for: tab, filter: filter),
                hasNoEvents: cards.isEmpty,
                nextPageURL: nextPageURL
            )).encodeResponse(for: req)
        }
        // Same URL, two different bodies: tell caches (and htmx's own
        // history cache) the response depends on the HX-Request header.
        response.headers.replaceOrAdd(name: .vary, value: "HX-Request")
        return response
    }

    /// "All" plus one chip per category (all six, with the category's
    /// photo), each keeping the other filters and the tab.
    static func categoryChips(for filter: EventFilterQuery, tab: ListTab) -> [CategoryChip] {
        let all = CategoryChip(label: "All", href: listURL(for: filter.with(category: nil), tab: tab),
                               imageURL: nil, isActive: filter.category == nil)
        return [all] + EventCategory.allCases.map { category in
            CategoryChip(label: category.rawValue.capitalized,
                         href: listURL(for: filter.with(category: category), tab: tab),
                         imageURL: imageURL(for: category),
                         isActive: filter.category == category)
        }
    }

    static func imageURL(for category: EventCategory) -> String {
        "/design/categories/\(category.rawValue).jpg"
    }

    static func emptyState(for tab: ListTab, filter: EventFilterQuery) -> EmptyState {
        switch tab {
        case .going:
            EmptyState(message: "You haven't joined any events here yet.", actionLabel: "Browse all events",
                       actionHref: listURL(for: filter, tab: .all))
        case .hosting:
            EmptyState(message: "You're not hosting any events here yet.", actionLabel: "Create an event", actionHref: "/events/new")
        case .all:
            EmptyState(message: "No events match these filters yet.", actionLabel: nil, actionHref: nil)
        }
    }

    /// The card view for each event, in order: the summary, a short
    /// description, up to three attendee photos, and the requester's
    /// attendance and hosting.
    static func cardViews(for events: [Event], requesterID: UUID?, on db: Database) async throws -> [EventCardView] {
        let service = EventService(db: db)
        let ids = try events.map { try $0.requireID() }
        // One query for every card's attendees (events are capped at a
        // few hundred), from which each card takes its count, first three
        // photos and the requester's attendance (review: this replaced
        // three queries per card).
        var attendeesByEvent: [UUID: [EventAttendee]] = [:]
        if !ids.isEmpty {
            let rows = try await EventAttendee.query(on: db)
                .filter(\.$event.$id ~~ ids)
                .with(\.$user)
                .sort(\.$joinedAt, .ascending)
                .all()
            attendeesByEvent = Dictionary(grouping: rows, by: { $0.$event.id })
        }
        var managedGroupIDs: Set<UUID> = []
        if let requesterID, !ids.isEmpty {
            managedGroupIDs = Set(try await GroupMembership.query(on: db)
                .filter(\.$user.$id == requesterID)
                .filter(\.$role ~~ [.owner, .moderator])
                .all()
                .map { $0.$group.id })
        }
        var cards: [EventCardView] = []
        for event in events {
            let id = try event.requireID()
            let attendees = attendeesByEvent[id] ?? []
            let summary = try await service.summaryDTO(for: event, requesterID: requesterID, attendeeCount: attendees.count)
            let isHost = requesterID.map { requester in
                event.$hostUser.id == requester || event.$hostGroup.id.map { managedGroupIDs.contains($0) } == true
            } ?? false
            cards.append(EventCardView(
                event: summary,
                url: "/events/\(id.uuidString)",
                imageURL: imageURL(for: event.category),
                categoryLabel: event.category.rawValue.capitalized,
                descriptionPreview: descriptionPreview(event.eventDescription),
                attendeePhotos: attendees.prefix(3).map { $0.user.photoURL },
                attendeeText: attendees.isEmpty ? "Be the first to join" : "\(attendees.count) going",
                isSignedIn: requesterID != nil,
                isAttending: requesterID.map { requester in attendees.contains { $0.$user.id == requester } } ?? false,
                isHost: isHost,
                errorMessage: nil
            ))
        }
        return cards
    }

    /// The description, cut at a word near 220 characters (the card also
    /// clamps it to two lines).
    static func descriptionPreview(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let limit = 220
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// `/events?…&page=N` with every filter currently applied kept, so
    /// "Load more" continues the same filtered list.
    static func pageURL(for filter: EventFilterQuery, page: Int, tab: ListTab = .all) -> String {
        listURL(for: filter, tab: tab, page: page)
    }

    /// `/events` with this filter and tab (and page, if given).
    static func listURL(for filter: EventFilterQuery, tab: ListTab, page: Int? = nil) -> String {
        var items: [URLQueryItem] = []
        if tab != .all { items.append(.init(name: "tab", value: tab.rawValue)) }
        if let category = filter.category { items.append(.init(name: "category", value: category.rawValue)) }
        if let city = filter.city { items.append(.init(name: "city", value: city)) }
        if let venue = filter.venue { items.append(.init(name: "venue", value: venue)) }
        if let hostUserID = filter.hostUserID { items.append(.init(name: "hostUserID", value: hostUserID.uuidString)) }
        if let hostGroupID = filter.hostGroupID { items.append(.init(name: "hostGroupID", value: hostGroupID.uuidString)) }
        // Query-string dates decode as seconds since 1970 (Vapor's default).
        if let onOrAfterDate = filter.onOrAfterDate {
            items.append(.init(name: "onOrAfterDate", value: String(onOrAfterDate.timeIntervalSince1970)))
        }
        if let page { items.append(.init(name: "page", value: String(page))) }
        guard !items.isEmpty else { return "/events" }
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
        // Coordinates and place IDs arrive as text: the field partials'
        // hidden inputs are emptied when the user edits a picked place, and
        // an empty string can't be decoded as a Double.
        let cityLat: String?
        let cityLng: String?
        let cityPlaceID: String?
        let venueAddress: String
        let venueLat: String?
        let venueLng: String?
        let venuePlaceID: String?
        let visibility: String?
        let hostGroupID: String?
        let attendeeLimit: String?
    }

    @Sendable
    func create(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let input = try req.content.decode(EventFormInput.self)
        do {
            let request = try Self.createRequest(from: input, location: req.application.location)
            let event = try await EventService(db: req.db, location: req.application.location).createEvent(request, hostUserID: try user.requireID())
            return req.redirect(to: "/events/\(try event.requireID())")
        } catch let error as APIError {
            req.logger.notice("Event creation rejected: \(error.code) — \(error.message)")
            return try await renderForm(req: req, user: user, input: input, errorMessage: error.message)
                .encodeResponse(status: .badRequest, for: req)
        }
    }

    /// Turns the form into a create request. The city must be one picked
    /// from the suggestions (that's where the event's coordinates and time
    /// zone come from); the venue may be free text. The date is read as
    /// local time at the venue, or the city if no venue was picked.
    static func createRequest(from input: EventFormInput, location: LocationService) throws -> CreateEventRequest {
        guard let category = EventCategory(rawValue: input.category) else {
            throw APIError(code: "invalid_category", message: "Choose a category.")
        }
        guard let city = GeoCoordinate.validated(latitude: input.cityLat, longitude: input.cityLng) else {
            throw APIError(code: "city_not_chosen", message: "Choose your city from the suggestions.")
        }
        // A venue picked for a different city (picked first, then the city
        // was changed) is ignored rather than allowed to set the event's
        // time zone and pin: the hidden fields can be stale, so the server
        // checks the two are plausibly together.
        var venue = GeoCoordinate.validated(latitude: input.venueLat, longitude: input.venueLng)
        if let picked = venue, picked.distanceKilometers(to: city) > Self.maxVenueDistanceKilometers {
            venue = nil
        }
        let timeZone = venue.flatMap(location.timeZoneIdentifier(for:)) ?? location.timeZoneIdentifier(for: city)
        guard let date = EventDateParsing.parse(input.date, timeZone: timeZone.flatMap(TimeZone.init(identifier:))) else {
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
            cityLat: city.latitude,
            cityLng: city.longitude,
            venueAddress: input.venueAddress,
            venueLat: venue?.latitude ?? 0,
            venueLng: venue?.longitude ?? 0,
            hostGroupID: hostGroupID,
            visibility: visibility,
            attendeeLimit: attendeeLimit,
            timeZone: timeZone,
            cityPlaceID: input.cityPlaceID,
            venuePlaceID: venue == nil ? nil : input.venuePlaceID,
            placeProvider: location.provider.name
        )
    }

    /// How far a picked venue may be from the picked city before it's
    /// treated as stale and ignored (metro areas plus a margin).
    static let maxVenueDistanceKilometers = 150.0

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
        // Re-filled after a rejection: keep what was typed and picked. Each
        // render starts fresh autocomplete sessions.
        let city = PlaceFieldContext(
            address: input?.cityAddress ?? "", latitude: input?.cityLat ?? "", longitude: input?.cityLng ?? "",
            placeID: input?.cityPlaceID ?? "", session: UUID().uuidString
        )
        let venue = PlaceFieldContext(
            address: input?.venueAddress ?? "", latitude: input?.venueLat ?? "", longitude: input?.venueLng ?? "",
            placeID: input?.venuePlaceID ?? "", session: UUID().uuidString
        )
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
            attendeeLimit: input?.attendeeLimit ?? "",
            errorMessage: errorMessage,
            cityAddress: city.address,
            cityLat: city.latitude,
            cityLng: city.longitude,
            cityPlaceID: city.placeID,
            citySession: city.session,
            citySelected: city.isSelected,
            venueAddress: venue.address,
            venueLat: venue.latitude,
            venueLng: venue.longitude,
            venuePlaceID: venue.placeID,
            venueSession: venue.session,
            venueSelected: venue.isSelected
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
        if isCardRequest(req) {
            do {
                let updated = try await EventService(db: req.db).join(event, userID: try user.requireID())
                return try await respondWithCard(req: req, event: updated, errorMessage: nil)
            } catch let error as APIError where error.code != APIError.notFound.code {
                // e.g. the event is full: the card says so instead of
                // silently not changing (htmx doesn't swap error responses).
                return try await respondWithCard(req: req, event: event, errorMessage: error.message)
            }
        }
        let updated = try await EventService(db: req.db).join(event, userID: try user.requireID())
        return try await respondWithEventUpdate(req: req, event: updated)
    }

    @Sendable
    func leave(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let event = try await eventOrNotFound(req)
        let updated = try await EventService(db: req.db).leave(event, userID: try user.requireID())
        if isCardRequest(req) {
            return try await respondWithCard(req: req, event: updated, errorMessage: nil)
        }
        return try await respondWithEventUpdate(req: req, event: updated)
    }

    /// A Join/Going click on an `/events` card (`?view=card`, over htmx)
    /// gets that one card back to swap in place.
    private func isCardRequest(_ req: Request) -> Bool {
        req.headers.first(name: "HX-Request") != nil
            && (try? req.query.decode(CardViewQuery.self))?.view == "card"
    }

    private func respondWithCard(req: Request, event: Event, errorMessage: String?) async throws -> Response {
        let requesterID = try req.auth.require(User.self).requireID()
        let service = EventService(db: req.db)
        guard let reloaded = try await service.find(try event.requireID()) else { throw Abort(.notFound) }
        // Someone who left an event they can no longer see (removed from
        // its private group) gets an empty answer, which removes the card
        // rather than showing them the event again (review).
        guard (try? await service.assertVisible(reloaded, to: requesterID)) != nil else {
            return Response(status: .ok)
        }
        var cards = try await Self.cardViews(for: [reloaded], requesterID: requesterID, on: req.db)
        if let errorMessage, let card = cards.first {
            cards = [card.withError(errorMessage)]
        }
        return try await req.view.render("partials/event-cards", EventCardsContext(cards: cards, nextPageURL: nil))
            .encodeResponse(for: req)
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

extension EventWebController.EventCardView {
    func withError(_ message: String) -> Self {
        Self(event: event, url: url, imageURL: imageURL, categoryLabel: categoryLabel,
             descriptionPreview: descriptionPreview, attendeePhotos: attendeePhotos, attendeeText: attendeeText,
             isSignedIn: isSignedIn, isAttending: isAttending, isHost: isHost, errorMessage: message)
    }
}

extension EventFilterQuery {
    /// The same filter with another category (nil for all), from page 1.
    func with(category: EventCategory?) -> EventFilterQuery {
        EventFilterQuery(category: category, city: city, venue: venue, hostUserID: hostUserID,
                         hostGroupID: hostGroupID, onOrAfterDate: onOrAfterDate, page: nil)
    }
}
