import Fluent
import Vapor
import ExpatEventsAPI

/// Shared by both the web (Leaf/htmx) and `/api/v1` event controllers
/// (architecture §3: "both built from the same service layer") — M4, plus
/// the group-hosting pieces M6 will extend.
struct EventService {
    let db: Database

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

    func filteredEvents(_ filter: EventFilterQuery, requesterID: UUID?) async throws -> [Event] {
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

        let pageSize = 20
        let page = max(filter.page ?? 1, 1)
        query = query.sort(\.$date, .ascending).offset((page - 1) * pageSize).limit(pageSize)

        let events = try await query.all()

        // Private group events are excluded from listings entirely for
        // non-members, rather than shown-then-blocked (M6 criterion #5).
        var visible: [Event] = []
        for event in events {
            if (try? await assertVisible(event, to: requesterID)) != nil {
                visible.append(event)
            }
        }
        return visible
    }

    // MARK: - Mutations

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
            isRecurring: request.isRecurring
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
            isCancelled: event.isCancelled
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
            isRequesterAttending: isAttending
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
