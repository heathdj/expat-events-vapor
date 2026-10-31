import Fluent
import Vapor
import ExpatEventsAPI
import ExpatEventsGeo

/// Shared by both the web (Leaf/htmx) and `/api/v1` event controllers
/// (architecture §3: "both built from the same service layer") — M4, plus
/// the group-hosting pieces M6 will extend.
struct EventService {
    let db: Database
    /// Only needed when creating events: works out a time zone from the
    /// venue's (or city's) coordinates when the request doesn't name one.
    var location: LocationService? = nil

    // MARK: - Fetching & visibility

    /// Loads an event with everything needed to build its DTO, or `nil` if
    /// it doesn't exist. Visibility enforcement (private group events
    /// hidden from non-members) happens in `assertVisible`, called
    /// separately so callers can choose 404-vs-403 semantics.
    func find(_ id: UUID) async throws -> Event? {
        try await Event.query(on: db)
            .filter(\.$id == id)
            .with(\.$hostUser)
            .with(\.$hostGroup)
            .first()
    }

    /// M6 acceptance criterion #5: a private group event is invisible to a
    /// non-member via the listing, the direct detail URL, and the JSON API.
    /// Throws `.notFound` rather than `.forbidden` so a non-member can't
    /// even confirm the event exists by probing the ID.
    func assertVisible(_ event: Event, to requesterID: UUID?) async throws {
        guard event.visibility == .private else { return }
        guard let groupID = event.$hostGroup.id else {
            // Private events hosted by an individual (Premium) user are
            // visible to anyone who can reach the URL — only *group*
            // events restrict by membership (architecture §9).
            return
        }
        guard let requesterID else { throw APIError.notFound }
        let isMember = try await GroupMembership.query(on: db)
            .filter(\.$group.$id == groupID)
            .filter(\.$user.$id == requesterID)
            .count() > 0
        guard isMember else { throw APIError.notFound }
    }

    // MARK: - Filtering

    static let pageSize = 20
    /// Highest page number honored. Clamping keeps `(page - 1) * pageSize`
    /// from overflowing: `?page=9223372036854775807` used to crash the
    /// whole server process (found by the event-basics review; the
    /// arithmetic predates that PR).
    static let maxPage = 10_000

    /// The page number a filter actually asks for, clamped to 1...maxPage.
    static func clampedPage(_ filter: EventFilterQuery) -> Int {
        min(max(filter.page ?? 1, 1), maxPage)
    }

    func filteredEvents(_ filter: EventFilterQuery, requesterID: UUID?) async throws -> [Event] {
        try await filteredEventsPage(filter, requesterID: requesterID).events
    }

    /// One page of `filteredEvents`, plus whether another page exists --
    /// what `/events`' "Load more" needs. Fetches one row past the page
    /// to find out, before the visibility filter below, so a page can
    /// hold fewer than `pageSize` visible events and still report more.
    func filteredEventsPage(_ filter: EventFilterQuery, requesterID: UUID?) async throws -> (events: [Event], hasMore: Bool) {
        var query = Event.query(on: db)
            .filter(\.$isCancelled == false)
            .with(\.$hostUser)
            .with(\.$hostGroup)

        if let category = filter.category {
            query = query.filter(\.$category == category)
        }
        if let city = filter.city {
            query = query.filter(\.$cityAddress ~~ city)
        }
        if let venue = filter.venue {
            query = query.filter(\.$venueAddress ~~ venue)
        }
        if let hostUserID = filter.hostUserID {
            query = query.filter(\.$hostUser.$id == hostUserID)
        }
        if let hostGroupID = filter.hostGroupID {
            query = query.filter(\.$hostGroup.$id == hostGroupID)
        }
        if let onOrAfterDate = filter.onOrAfterDate {
            query = query.filter(\.$date >= onOrAfterDate)
        }

        let pageSize = Self.pageSize
        let page = Self.clampedPage(filter)
        // `id` breaks ties between events at the same time, so separate
        // page queries agree on one order and no event repeats or vanishes.
        query = query.sort(\.$date, .ascending).sort(\.$id, .ascending)
            .offset((page - 1) * pageSize).limit(pageSize + 1)

        let fetched = try await query.all()
        let hasMore = fetched.count > pageSize
        let events = Array(fetched.prefix(pageSize))

        // Private group events are excluded from listings entirely for
        // non-members, rather than shown-then-blocked (M6 criterion #5).
        var visible: [Event] = []
        for event in events {
            if (try? await assertVisible(event, to: requesterID)) != nil {
                visible.append(event)
            }
        }
        return (visible, hasMore)
    }

    // MARK: - Mutations

    /// The request's own time zone if it names a real one; otherwise the
    /// venue's, then the city's, from their coordinates; otherwise nil (no
    /// coordinates, e.g. an API client that didn't send any).
    func resolvedTimeZone(for request: CreateEventRequest) throws -> String? {
        if let requested = Self.nonEmpty(request.timeZone) {
            guard TimeZone(identifier: requested) != nil else {
                throw APIError(code: "invalid_time_zone", message: "\(requested) isn't a known time zone.")
            }
            return requested
        }
        guard let location else { return nil }
        return location.timeZoneIdentifier(for: GeoCoordinate(latitude: request.venueLat, longitude: request.venueLng))
            ?? location.timeZoneIdentifier(for: GeoCoordinate(latitude: request.cityLat, longitude: request.cityLng))
    }

    /// Place-search providers the app knows. Anything else an API client
    /// sends is dropped rather than stored, since a future refresh job will
    /// trust (provider, place ID) pairs.
    static let knownPlaceProviders: Set<String> = ["google", "apple", "sample"]

    private static func knownProvider(_ value: String?) -> String? {
        guard let name = nonEmpty(value)?.lowercased(), knownPlaceProviders.contains(name) else { return nil }
        return name
    }

    /// Place IDs are opaque provider strings; cap them so a client can't
    /// store arbitrary blobs.
    private static func placeID(_ value: String?) -> String? {
        guard let id = nonEmpty(value), id.count <= 512 else { return nil }
        return id
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func createEvent(_ request: CreateEventRequest, hostUserID: UUID) async throws -> Event {
        let limits = PlanLimitsService(db: db)
        var hostGroupID: Group.IDValue?

        if let requestedGroupID = request.hostGroupID {
            // M6: only that group's owner/moderator may create events under it.
            guard let membership = try await GroupMembership.query(on: db)
                .filter(\.$group.$id == requestedGroupID)
                .filter(\.$user.$id == hostUserID)
                .first(), membership.role == .owner || membership.role == .moderator
            else {
                throw APIError.forbidden
            }
            hostGroupID = requestedGroupID
        } else {
            try await limits.assertCanCreateEvent(hostUserID: hostUserID)
        }

        try await limits.assertCanSetVisibility(request.visibility, hostUserID: hostGroupID == nil ? hostUserID : nil)
        if let attendeeLimit = request.attendeeLimit {
            try await limits.assertCanSetAttendeeLimit(attendeeLimit, hostUserID: hostGroupID == nil ? hostUserID : nil)
        }
        let timeZone = try resolvedTimeZone(for: request)

        let event = Event(
            title: request.title,
            description: request.description,
            category: request.category,
            date: request.date,
            cityAddress: request.cityAddress,
            cityLat: request.cityLat,
            cityLng: request.cityLng,
            venueAddress: request.venueAddress,
            venueLat: request.venueLat,
            venueLng: request.venueLng,
            hostUserID: hostGroupID == nil ? hostUserID : nil,
            hostGroupID: hostGroupID,
            visibility: request.visibility,
            attendeeLimit: request.attendeeLimit,
            isRecurring: request.isRecurring,
            timeZone: timeZone,
            cityPlaceID: Self.placeID(request.cityPlaceID),
            venuePlaceID: Self.placeID(request.venuePlaceID),
            placeProvider: Self.knownProvider(request.placeProvider)
        )
        try await event.save(on: db)
        return event
    }

    /// M4 acceptance criterion #8 / M6 criterion #4: only the hosting user
    /// (or, for group events, an owner/moderator of the hosting group) may
    /// edit or cancel — enforced here so both the web and API surfaces get
    /// it for free.
    func assertCanManage(_ event: Event, requesterID: UUID) async throws {
        if let hostUserID = event.$hostUser.id, hostUserID == requesterID {
            return
        }
        if let hostGroupID = event.$hostGroup.id {
            let membership = try await GroupMembership.query(on: db)
                .filter(\.$group.$id == hostGroupID)
                .filter(\.$user.$id == requesterID)
                .first()
            if let membership, membership.role == .owner || membership.role == .moderator {
                return
            }
        }
        throw APIError.forbidden
    }

    func updateEvent(_ event: Event, with request: UpdateEventRequest, requesterID: UUID) async throws -> Event {
        try await assertCanManage(event, requesterID: requesterID)

        if let visibility = request.visibility {
            try await PlanLimitsService(db: db).assertCanSetVisibility(visibility, hostUserID: event.$hostUser.id)
            event.visibility = visibility
        }
        if let title = request.title { event.title = title }
        if let description = request.description { event.eventDescription = description }
        if let category = request.category { event.category = category }
        if let date = request.date { event.date = date }
        if let cityAddress = request.cityAddress { event.cityAddress = cityAddress }
        if let cityLat = request.cityLat { event.cityLat = cityLat }
        if let cityLng = request.cityLng { event.cityLng = cityLng }
        if let venueAddress = request.venueAddress { event.venueAddress = venueAddress }
        if let venueLat = request.venueLat { event.venueLat = venueLat }
        if let venueLng = request.venueLng { event.venueLng = venueLng }

        // Moving the event means its old place IDs and time zone no longer
        // describe it (found by the location PR's review): the IDs are
        // dropped (a refresh job would otherwise move it back), and the
        // time zone is worked out again from the new coordinates. A legacy
        // event (no time zone) only gets one if this update also sets the
        // date: its stored date is the host's wall-clock time as UTC, which
        // would shift if a zone were attached to it without a new instant.
        let cityMoved = request.cityLat != nil || request.cityLng != nil
        let venueMoved = request.venueLat != nil || request.venueLng != nil
        if cityMoved { event.cityPlaceID = nil }
        if venueMoved { event.venuePlaceID = nil }
        if event.cityPlaceID == nil && event.venuePlaceID == nil { event.placeProvider = nil }
        if (cityMoved || venueMoved), let location, event.timeZone != nil || request.date != nil {
            event.timeZone = location.timeZoneIdentifier(for: GeoCoordinate(latitude: event.venueLat, longitude: event.venueLng))
                ?? location.timeZoneIdentifier(for: GeoCoordinate(latitude: event.cityLat, longitude: event.cityLng))
                ?? event.timeZone
        }

        try await event.save(on: db)
        return event
    }

    /// M4 acceptance criterion #7: cancelling sets `isCancelled = true`;
    /// the row and attendee history survive (no delete).
    func cancelEvent(_ event: Event, requesterID: UUID) async throws -> Event {
        try await assertCanManage(event, requesterID: requesterID)
        event.isCancelled = true
        try await event.save(on: db)
        return event
    }

    /// Joining/leaving also fans out an `ActivityFeedItem` to the acting
    /// user's followers in the same request (architecture §10) — there's
    /// no Firestore-style trigger function in Vapor, so this is where that
    /// equivalent logic lives.
    func join(_ event: Event, userID: UUID) async throws -> Event {
        try await assertVisible(event, to: userID)
        guard !event.isCancelled else { throw APIError(code: "event_cancelled", message: "This event has been cancelled.") }

        let alreadyJoined = try await EventAttendee.query(on: db)
            .filter(\.$event.$id == event.requireID())
            .filter(\.$user.$id == userID)
            .count() > 0
        if alreadyJoined { return event }

        try await PlanLimitsService(db: db).assertCanJoin(event: event)

        let attendee = EventAttendee(eventID: try event.requireID(), userID: userID)
        try await attendee.save(on: db)

        try await fanOutActivity(type: .joinedEvent, actorUserID: userID, eventID: try event.requireID())

        return event
    }

    /// Unlike `join`, this doesn't unconditionally `assertVisible` first:
    /// an existing attendee who has since lost visibility (e.g. removed
    /// from the hosting group) must still be able to leave, rather than
    /// being stuck with a dangling attendee row they can no longer reach.
    /// A non-attendee, though, gets the same `notFound` a stranger would
    /// from `join`/`detail` — this is what closes the information leak an
    /// independent review of PR #3 found: `EventWebController`'s htmx
    /// fragment response renders the full event (title/venue/description/
    /// attendee list) straight from this call's result, so an
    /// unauthorized caller could previously fish for private group-event
    /// details via `POST /events/:id/leave` even though `join`/`detail`
    /// both correctly rejected them.
    func leave(_ event: Event, userID: UUID) async throws -> Event {
        let isAttending = try await EventAttendee.query(on: db)
            .filter(\.$event.$id == event.requireID())
            .filter(\.$user.$id == userID)
            .count() > 0
        if !isAttending {
            try await assertVisible(event, to: userID)
        }

        try await EventAttendee.query(on: db)
            .filter(\.$event.$id == event.requireID())
            .filter(\.$user.$id == userID)
            .delete()

        try await fanOutActivity(type: .leftEvent, actorUserID: userID, eventID: try event.requireID())

        return event
    }

    private func fanOutActivity(type: ActivityFeedItemType, actorUserID: UUID, eventID: UUID) async throws {
        let followers = try await Follow.query(on: db)
            .filter(\.$following.$id == actorUserID)
            .all()
        for follow in followers {
            let item = ActivityFeedItem(
                recipientUserID: follow.$follower.id,
                actorUserID: actorUserID,
                type: type,
                eventID: eventID
            )
            try await item.save(on: db)
        }
    }

    // MARK: - DTO conversion

    func summaryDTO(for event: Event, requesterID: UUID?) async throws -> EventSummaryDTO {
        let (hostName, hostPhoto) = try await hostDisplay(for: event)
        let count = try await EventAttendee.query(on: db).filter(\.$event.$id == event.requireID()).count()
        return EventSummaryDTO(
            id: try event.requireID(),
            title: event.title,
            category: event.category,
            date: event.date,
            cityAddress: event.cityAddress,
            hostDisplayName: hostName,
            hostPhotoURL: hostPhoto,
            attendeeCount: count,
            visibility: event.visibility,
            isCancelled: event.isCancelled,
            timeZone: event.timeZone
        )
    }

    func fullDTO(for event: Event, requesterID: UUID?) async throws -> EventDTO {
        let (hostName, hostPhoto) = try await hostDisplay(for: event)
        let attendeeRows = try await EventAttendee.query(on: db)
            .filter(\.$event.$id == event.requireID())
            .with(\.$user)
            .sort(\.$joinedAt, .ascending)
            .all()
        let attendees = try attendeeRows.map { row in
            AttendeeDTO(
                id: try row.user.requireID(),
                displayName: row.user.displayName,
                photoURL: row.user.photoURL,
                joinedAt: row.joinedAt ?? Date()
            )
        }
        let isAttending = requesterID.map { id in attendees.contains { $0.id == id } } ?? false

        return EventDTO(
            id: try event.requireID(),
            title: event.title,
            description: event.eventDescription,
            category: event.category,
            date: event.date,
            cityAddress: event.cityAddress,
            cityLat: event.cityLat,
            cityLng: event.cityLng,
            venueAddress: event.venueAddress,
            venueLat: event.venueLat,
            venueLng: event.venueLng,
            hostUserID: event.$hostUser.id,
            hostGroupID: event.$hostGroup.id,
            hostDisplayName: hostName,
            hostPhotoURL: hostPhoto,
            visibility: event.visibility,
            attendeeLimit: event.attendeeLimit,
            isRecurring: event.isRecurring,
            isCancelled: event.isCancelled,
            attendees: attendees,
            isRequesterAttending: isAttending,
            timeZone: event.timeZone
        )
    }

    private func hostDisplay(for event: Event) async throws -> (String, String?) {
        if let hostUserID = event.$hostUser.id, let hostUser = try await User.find(hostUserID, on: db) {
            return (hostUser.displayName, hostUser.photoURL)
        }
        if let hostGroupID = event.$hostGroup.id, let hostGroup = try await Group.find(hostGroupID, on: db) {
            return (hostGroup.name, hostGroup.avatarURL)
        }
        return ("Unknown host", nil)
    }
}
