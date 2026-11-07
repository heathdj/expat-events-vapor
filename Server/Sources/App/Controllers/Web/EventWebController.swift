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
    /// `/events`: the filter panel (Search & filters PR) and the first
    /// page of results.
    struct EventsPageContext: Encodable {
        let title = "Events"
        let isSignedIn: Bool
        // Results (the same keys `partials/events-results` reads).
        let cards: [EventCardView]
        let hasNoEvents: Bool
        let empty: EmptyState
        let resultsStatus: String
        let isUpdate = false
        /// The next page's URL, with every filter kept, when there is one
        /// -- what "Load more events" fetches. nil on the last page.
        let nextPageURL: String?
        // The filter panel. Every option's state is precomputed (no Leaf
        // comparisons).
        /// All / Going / Hosting. Only for members (a visitor has nothing
        /// to be going to or hosting).
        let showTabs: Bool
        let tabs: [FilterOption]
        let categories: [CategoryOption]
        let datePresets: [FilterOption]
        let whenValue: String
        let from: String
        let to: String
        let q: String
        let yourGroups: [FilterOption]
        let otherGroups: [FilterOption]
        let hasYourGroups: Bool
        let hasOtherGroups: Bool
        let isAnyGroup: Bool
        /// "Near a city" uses the place search, which is for members only
        /// (every lookup costs money with a real provider).
        let canSearchNear: Bool
        // `partials/near-field` keys.
        let near: String
        let nearLat: String
        let nearLng: String
        let nearSession: String
        let nearSelected: Bool
        let nearJustPicked = false
        let nearError: String? = nil
        let radiusOptions: [FilterOption]
        let unit: String
        let tz: String
        /// Older link filters (city, venue, host, start date) kept as
        /// hidden fields so changing another filter doesn't drop them.
        let hiddenFields: [HiddenField]
        let activeFilterCount: Int
        let hasActiveFilters: Bool
        let clearURL: String
    }

    /// What an htmx filter change gets back (`partials/events-results`).
    struct EventsResultsContext: Encodable {
        /// Sends the status line along out of band, so the one live region
        /// above the results announces the change.
        let isUpdate = true
        let cards: [EventCardView]
        let hasNoEvents: Bool
        let empty: EmptyState
        let resultsStatus: String
        let nextPageURL: String?
    }

    struct FilterOption: Encodable {
        let value: String
        let label: String
        let isChecked: Bool
    }

    struct CategoryOption: Encodable {
        let value: String
        let label: String
        /// nil for "All".
        let imageURL: String?
        let isChecked: Bool
    }

    struct HiddenField: Encodable {
        let name: String
        let value: String
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

    struct CardViewQuery: Content {
        let view: String?
    }

    /// `/events/:id` (Event detail PR, from the canvas's EventDetail
    /// artboard). The fields after `chatHistory` have defaults so older
    /// call sites (and tests) that render the page directly still work.
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
        var hero = DetailHero()
        var people = DetailPeople()
        var place = DetailPlace()
        var chatRows: [ChatRow] = []
        var hasNoMessages = true
        /// The signed-in member's ID, so the page can tell its own chat
        /// messages (the live ones are broadcast to everyone alike).
        var currentUserID = ""
        let isUpdate = false
    }

    /// Same keys as the page minus `title`: what `partials/event-fragment`
    /// (the action bar) reads, inline or as the htmx answer to Join,
    /// Going or Cancel. That answer also carries the attendee list out of
    /// band (`isUpdate`), since the two sit in different columns.
    struct EventFragmentContext: Encodable {
        let event: EventDTO
        let isSignedIn: Bool
        let canManage: Bool
        var people = DetailPeople()
        var isUpdate = true
    }

    /// The photo banner: the category's photo, title, date and place.
    struct DetailHero: Encodable {
        var imageURL = ""
        var categoryLabel = ""
    }

    /// The host line, and the side card's Host and Going sections.
    struct DetailPeople: Encodable {
        var hostURL: String? = nil
        var hostIsGroup = false
        /// The host (a member or a group), always shown in its own section
        /// (user's decision at the checkpoint: "0 people going" with the
        /// host under it read wrongly).
        var host: PersonRow? = nil
        var goingText = ""
        /// Everyone going; a host who is also going is tagged Host.
        var rows: [PersonRow] = []
        var hasGoing = false
    }

    struct PersonRow: Encodable {
        let name: String
        let photoURL: String?
        let profileURL: String
        let isYou: Bool
        let isHost: Bool
        /// "Owner" or "Moderator" of the group hosting the event (user's
        /// request at the Event detail checkpoint).
        var roleLabel: String? = nil
    }

    /// Where it is: the venue (or city) text, the map picture's address
    /// (when there are coordinates) and a link to open it in Google Maps.
    struct DetailPlace: Encodable {
        var label = ""
        var hasMap = false
        var mapURL = ""
        var directionsURL: String? = nil
    }

    /// One chat message on the page. Replies show who they answer;
    /// `threadID` is what a reply to this message points at (replies are
    /// one level deep, so replying to a reply joins its thread).
    struct ChatRow: Encodable {
        let message: ChatMessageDTO
        let isReply: Bool
        let threadID: String
        let replyToName: String?
        let isoTime: String
        let fallbackTime: String
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
        // Members only (review): each picture is billed, and a visitor
        // can't be told apart behind a proxy. Visitors get the free
        // "Open in Google Maps" link instead.
        authenticated.get("events", ":eventID", "map.png", use: mapImage)
    }

    /// `/events`. A normal request renders the whole page; an htmx
    /// request gets just what changed: a filter change (`HX-Target:
    /// ev-results`) the results, and "Load more" the next page's cards and
    /// button (architecture §6's `GET /events?page=N`). Filters arrive as
    /// the panel's form fields (`EventsSearch`); `?tab=going` /
    /// `?tab=hosting` narrow the list to the member's own events
    /// (visitors always get All). Upcoming only, unless dates are picked.
    @Sendable
    func dashboard(req: Request) async throws -> Response {
        let user = req.auth.get(User.self)
        let requesterID = user.flatMap { try? $0.requireID() }
        let form = (try? req.query.decode(EventsSearch.Form.self)) ?? EventsSearch.Form()
        let search = EventsSearch.parse(form, isSignedIn: requesterID != nil, preferredUnit: user?.distanceUnit ?? .km)
        let scope: EventService.ListScope
        switch (search.tab, requesterID) {
        case (.going, let id?): scope = .going(id)
        case (.hosting, let id?): scope = .hosting(id)
        default: scope = .all
        }
        let service = EventService(db: req.db)
        let page = try await service.filteredEventsPage(search.filter(), requesterID: requesterID, scope: scope)
        let cards = try await Self.cardViews(for: page.events, requesterID: requesterID, on: req.db)
        let nextPageURL = page.hasMore && search.page < EventService.maxPage ? search.url(page: search.page + 1) : nil
        let empty = Self.emptyState(for: search)
        let status = Self.resultsStatus(count: cards.count, hasMore: page.hasMore)

        // htmx restoring a page missing from its history cache asks for
        // the whole page, with HX-Request set.
        let isPartial = req.headers.first(name: "HX-Request") != nil
            && req.headers.first(name: "HX-History-Restore-Request") == nil
        let response: Response
        if isPartial, req.headers.first(name: "HX-Target") == "ev-results" {
            response = try await req.view.render("partials/events-results", EventsResultsContext(
                cards: cards, hasNoEvents: cards.isEmpty, empty: empty, resultsStatus: status, nextPageURL: nextPageURL
            )).encodeResponse(for: req)
            // The address bar gets the tidy URL (only what's set), not the
            // form's every field.
            response.headers.replaceOrAdd(name: "HX-Push-Url", value: search.url())
        } else if isPartial {
            response = try await req.view.render("partials/event-cards", EventCardsContext(
                cards: cards,
                nextPageURL: nextPageURL
            )).encodeResponse(for: req)
        } else {
            let groups = try await Self.groupOptions(for: requesterID, selected: search.groupID, on: req.db)
            let chosenRadius = search.radius ?? search.unit.defaultRadius
            response = try await req.view.render("pages/events", EventsPageContext(
                isSignedIn: requesterID != nil,
                cards: cards,
                hasNoEvents: cards.isEmpty,
                empty: empty,
                resultsStatus: status,
                nextPageURL: nextPageURL,
                showTabs: requesterID != nil,
                tabs: ListTab.allCases.map { FilterOption(value: $0.rawValue, label: $0.label, isChecked: $0 == search.tab) },
                categories: Self.categoryOptions(selected: search.category),
                datePresets: EventsSearch.DatePreset.allCases.map {
                    FilterOption(value: $0.rawValue, label: $0.label, isChecked: $0 == search.when)
                },
                whenValue: search.when.rawValue,
                from: search.from ?? "",
                to: search.to ?? "",
                q: search.text ?? "",
                yourGroups: groups.yours,
                otherGroups: groups.others,
                hasYourGroups: !groups.yours.isEmpty,
                hasOtherGroups: !groups.others.isEmpty,
                isAnyGroup: search.groupID == nil,
                canSearchNear: requesterID != nil,
                near: search.nearLabel ?? "",
                nearLat: search.nearLatitude.map { String($0) } ?? "",
                nearLng: search.nearLongitude.map { String($0) } ?? "",
                nearSession: UUID().uuidString,
                nearSelected: search.hasNear,
                radiusOptions: search.unit.radiusOptions.map {
                    FilterOption(value: EventsSearch.number($0), label: "\(EventsSearch.number($0)) \(search.unit.shortLabel)", isChecked: $0 == chosenRadius)
                },
                unit: search.unit.rawValue,
                tz: search.timeZoneIdentifier ?? "",
                hiddenFields: Self.hiddenFields(for: search, isSignedIn: requesterID != nil),
                activeFilterCount: search.activeFilterCount,
                hasActiveFilters: search.activeFilterCount > 0,
                clearURL: Self.clearURL(for: search)
            )).encodeResponse(for: req)
        }
        // Same URL, different bodies: tell caches (and htmx's own history
        // cache) the response depends on these headers.
        response.headers.replaceOrAdd(name: .vary, value: "HX-Request, HX-Target, HX-History-Restore-Request")
        return response
    }

    /// "All" plus all six categories, each with its photo.
    static func categoryOptions(selected: EventCategory?) -> [CategoryOption] {
        [CategoryOption(value: "", label: "All", imageURL: nil, isChecked: selected == nil)]
            + EventCategory.allCases.map { category in
                CategoryOption(value: category.rawValue, label: category.rawValue.capitalized,
                               imageURL: imageURL(for: category), isChecked: selected == category)
            }
    }

    /// The group picker: the member's own groups, then every public group,
    /// by name.
    static func groupOptions(for requesterID: UUID?, selected: UUID?, on db: Database) async throws -> (yours: [FilterOption], others: [FilterOption]) {
        var yours: [Group] = []
        if let requesterID {
            yours = try await GroupMembership.query(on: db)
                .filter(\.$user.$id == requesterID)
                .with(\.$group)
                .all()
                .map(\.group)
        }
        let yourIDs = Set(yours.compactMap(\.id))
        let others = try await GroupService(db: db).publicGroups().filter { group in
            group.id.map { !yourIDs.contains($0) } ?? false
        }
        // Only the member's own groups and public groups are offered: a
        // UUID in the link never reveals an invite-only group's name
        // (review).
        func options(_ groups: [Group]) -> [FilterOption] {
            groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.compactMap { group in
                group.id.map { FilterOption(value: $0.uuidString, label: group.name, isChecked: $0 == selected) }
            }
        }
        return (options(yours), options(others))
    }

    static func hiddenFields(for search: EventsSearch, isSignedIn: Bool) -> [HiddenField] {
        var fields: [HiddenField] = []
        if let city = search.city { fields.append(HiddenField(name: "city", value: city)) }
        if let venue = search.venue { fields.append(HiddenField(name: "venue", value: venue)) }
        if let hostUserID = search.hostUserID { fields.append(HiddenField(name: "hostUserID", value: hostUserID.uuidString)) }
        if let start = search.onOrAfterDate {
            fields.append(HiddenField(name: "onOrAfterDate", value: String(start.timeIntervalSince1970)))
        }
        // A visitor can't use the Near field, but a shared link's city is
        // kept when they change another filter.
        if !isSignedIn, let lat = search.nearLatitude, let lng = search.nearLongitude {
            fields.append(HiddenField(name: "near", value: search.nearLabel ?? ""))
            fields.append(HiddenField(name: "nearLat", value: String(lat)))
            fields.append(HiddenField(name: "nearLng", value: String(lng)))
            fields.append(HiddenField(name: "radius", value: EventsSearch.number(search.radius ?? search.unit.defaultRadius)))
            fields.append(HiddenField(name: "unit", value: search.unit.rawValue))
        }
        return fields
    }

    /// Everything cleared but the tab.
    static func clearURL(for search: EventsSearch) -> String {
        search.tab == .all ? "/events" : "/events?tab=\(search.tab.rawValue)"
    }

    /// Announced to screen readers when the results change.
    static func resultsStatus(count: Int, hasMore: Bool) -> String {
        switch count {
        case 0: "No events found"
        case 1: "1 event"
        default: hasMore ? "Showing the first \(count) events" : "\(count) events"
        }
    }

    static func emptyState(for search: EventsSearch) -> EmptyState {
        if search.activeFilterCount > 0 {
            return EmptyState(message: "No events match these filters.", actionLabel: "Clear filters", actionHref: clearURL(for: search))
        }
        switch search.tab {
        case .going:
            return EmptyState(message: "You haven't joined any upcoming events yet.", actionLabel: "Browse all events", actionHref: "/events")
        case .hosting:
            return EmptyState(message: "You're not hosting any upcoming events yet.", actionLabel: "Create an event", actionHref: "/events/new")
        case .all:
            return EmptyState(message: "No upcoming events yet.", actionLabel: nil, actionHref: nil)
        }
    }

    static func imageURL(for category: EventCategory) -> String {
        "/design/categories/\(category.rawValue).jpg"
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
        // Members only (user's decision at the Event detail checkpoint):
        // visitors get a sign-in box, and the messages aren't loaded.
        var chatHistory: [ChatMessageDTO] = []
        if user != nil {
            let chatMessages = try await ChatService(db: req.db).history(eventID: try event.requireID())
            chatHistory = try chatMessages.map { try $0.toDTO() }
        }
        let rows = Self.chatRows(chatHistory)
        let groupRoles = try await Self.hostGroupRoles(for: event, on: req.db)
        return try await req.view.render("pages/event-detail", EventDetailPageContext(
            title: dto.title,
            event: dto,
            isSignedIn: user != nil,
            canManage: canManage,
            chatHistory: chatHistory,
            hero: DetailHero(imageURL: Self.imageURL(for: event.category), categoryLabel: event.category.rawValue.capitalized),
            people: Self.people(for: event, dto: dto, requesterID: requesterID, groupRoles: groupRoles),
            place: Self.place(for: event, canShowMap: user != nil),
            chatRows: rows,
            hasNoMessages: rows.isEmpty,
            currentUserID: requesterID?.uuidString ?? ""
        ))
    }

    /// `GET /events/:id/map.png`: the map picture for an event's venue (or
    /// city), fetched from the provider with the server's key (user's
    /// decision: the key never reaches the browser). Members only, and
    /// only for events they can see that aren't cancelled; coordinates
    /// come from the event, never the request, so nobody can draw other
    /// maps on our key. Never stored (Google's terms); browsers may keep
    /// it an hour. Each one is billed, so there's a limit per member and
    /// one for the whole site.
    @Sendable
    func mapImage(req: Request) async throws -> Response {
        let requesterID = try req.auth.require(User.self).requireID()
        let event = try await eventOrNotFound(req)
        try await EventService(db: req.db).assertVisible(event, to: requesterID)
        guard !event.isCancelled, let point = Self.mapPoint(for: event) else { throw Abort(.notFound) }
        guard await req.application.mapImageLimiter.allow(requesterID.uuidString),
              await req.application.mapImageSiteLimiter.allow("site") else {
            throw Abort(.tooManyRequests, reason: "Too many map requests. Try again in a minute.")
        }
        let image: StaticMapImage
        do {
            image = try await req.application.staticMaps.image(center: point, width: Self.mapWidth, height: Self.mapHeight)
        } catch {
            req.logger.warning("Map image failed: \(error)")
            throw Abort(.badGateway, reason: "The map isn't available right now.")
        }
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: image.contentType)
        headers.replaceOrAdd(name: .cacheControl, value: "private, max-age=3600")
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        return Response(status: .ok, headers: headers, body: .init(data: image.data))
    }

    static let mapWidth = 640
    static let mapHeight = 280

    /// The venue's coordinates, or the city's when the venue has none;
    /// nil when neither is set (events from before location lookup).
    static func mapPoint(for event: Event) -> GeoCoordinate? {
        let venue = GeoCoordinate(latitude: event.venueLat, longitude: event.venueLng)
        if venue.isSet { return venue }
        let city = GeoCoordinate(latitude: event.cityLat, longitude: event.cityLng)
        return city.isSet ? city : nil
    }

    /// The map picture is offered to members on events that aren't
    /// cancelled; the Google Maps link to anyone, whenever there are
    /// coordinates.
    static func place(for event: Event, canShowMap: Bool) -> DetailPlace {
        let label = event.venueAddress.isEmpty ? event.cityAddress : event.venueAddress
        guard let point = mapPoint(for: event), let id = event.id else {
            return DetailPlace(label: label, hasMap: false, mapURL: "", directionsURL: nil)
        }
        // A plain Google Maps link: no key, opens the app on phones.
        let query = String(format: "%.6f,%.6f", point.latitude, point.longitude)
        return DetailPlace(label: label, hasMap: canShowMap && !event.isCancelled, mapURL: "/events/\(id.uuidString)/map.png",
                           directionsURL: "https://www.google.com/maps/search/?api=1&query=\(query)")
    }

    /// The host, then everyone going (the requester tagged You, a host
    /// who is going tagged Host).
    static func people(for event: Event, dto: EventDTO, requesterID: UUID?,
                       groupRoles: [UUID: GroupRole] = [:]) -> DetailPeople {
        let hostURL: String?
        if let hostUserID = dto.hostUserID {
            hostURL = "/profile/\(hostUserID.uuidString)"
        } else if let loaded = event.$hostGroup.value, let group = loaded {
            hostURL = "/groups/\(group.slug)"
        } else {
            hostURL = nil
        }
        let host = PersonRow(name: dto.hostDisplayName, photoURL: dto.hostPhotoURL, profileURL: hostURL ?? "",
                             isYou: dto.hostUserID != nil && dto.hostUserID == requesterID, isHost: true)
        let rows = dto.attendees.map { attendee in
            PersonRow(name: attendee.displayName, photoURL: attendee.photoURL,
                      profileURL: "/profile/\(attendee.id.uuidString)",
                      isYou: attendee.id == requesterID, isHost: attendee.id == dto.hostUserID,
                      roleLabel: groupRoles[attendee.id].map { $0 == .owner ? "Owner" : "Moderator" })
        }
        let going = rows.count
        return DetailPeople(hostURL: hostURL, hostIsGroup: dto.hostGroupID != nil, host: host,
                            goingText: going == 0 ? "Going" : (going == 1 ? "1 person going" : "\(going) people going"),
                            rows: rows, hasGoing: going > 0)
    }

    /// For a group's event: who among its members is owner or moderator.
    static func hostGroupRoles(for event: Event, on db: Database) async throws -> [UUID: GroupRole] {
        guard let groupID = event.$hostGroup.id else { return [:] }
        let rows = try await GroupMembership.query(on: db)
            .filter(\.$group.$id == groupID)
            .filter(\.$role ~~ [.owner, .moderator])
            .all()
        return Dictionary(rows.map { ($0.$user.id, $0.role) }, uniquingKeysWith: { first, _ in first })
    }

    /// Chat messages for the page, each with the name it replies to.
    static func chatRows(_ messages: [ChatMessageDTO]) -> [ChatRow] {
        let names = Dictionary(messages.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        return messages.map { message in
            chatRow(message, replyToName: message.parentID.flatMap { names[$0] })
        }
    }

    static func chatRow(_ message: ChatMessageDTO, replyToName: String?) -> ChatRow {
        ChatRow(message: message,
                isReply: message.parentID != nil,
                threadID: (message.parentID ?? message.id).uuidString,
                replyToName: replyToName,
                isoTime: chatTimeFormatter.string(from: message.createdAt),
                fallbackTime: chatFallbackFormatter.string(from: message.createdAt))
    }

    /// Machine-readable times; the page shows them in the reader's own
    /// zone (`js/event-chat.js`), with UTC text until it does.
    static let chatTimeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let chatFallbackFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d, HH:mm 'UTC'"
        return formatter
    }()

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
        let reloaded = try await service.find(try event.requireID()) ?? event
        let dto = try await service.fullDTO(for: reloaded, requesterID: requesterID)
        let canManage = (try? await service.assertCanManage(reloaded, requesterID: requesterID)) != nil
        let groupRoles = try await Self.hostGroupRoles(for: reloaded, on: req.db)
        let view = try await req.view.render("partials/event-fragment", EventFragmentContext(
            event: dto,
            isSignedIn: true,
            canManage: canManage,
            people: Self.people(for: reloaded, dto: dto, requesterID: requesterID, groupRoles: groupRoles)
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
