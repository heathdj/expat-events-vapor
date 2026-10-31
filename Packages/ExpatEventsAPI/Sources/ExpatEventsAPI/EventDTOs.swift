import Foundation

/// Lighter shape for list views (architecture doc §5).
public struct EventSummaryDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let category: EventCategory
    public let date: Date
    public let cityAddress: String
    public let hostDisplayName: String
    public let hostPhotoURL: String?
    public let attendeeCount: Int
    public let visibility: EventVisibility
    public let isCancelled: Bool
    /// The event's IANA time zone ("Europe/Lisbon"). `date` is a real
    /// instant; show it in this zone. nil when no zone is known: events
    /// created before location lookup existed (their `date` is the host's
    /// wall-clock time stored as UTC) or created through the API without
    /// coordinates or a zone. Show those in UTC.
    public let timeZone: String?

    public init(
        id: UUID,
        title: String,
        category: EventCategory,
        date: Date,
        cityAddress: String,
        hostDisplayName: String,
        hostPhotoURL: String?,
        attendeeCount: Int,
        visibility: EventVisibility,
        isCancelled: Bool,
        timeZone: String? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.date = date
        self.cityAddress = cityAddress
        self.hostDisplayName = hostDisplayName
        self.hostPhotoURL = hostPhotoURL
        self.attendeeCount = attendeeCount
        self.visibility = visibility
        self.isCancelled = isCancelled
        self.timeZone = timeZone
    }
}

/// Full detail shape for `/events/:id` and `/api/v1/events/:id`.
public struct EventDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let description: String
    public let category: EventCategory
    public let date: Date
    public let cityAddress: String
    public let cityLat: Double
    public let cityLng: Double
    public let venueAddress: String
    public let venueLat: Double
    public let venueLng: Double
    public let hostUserID: UUID?
    public let hostGroupID: UUID?
    public let hostDisplayName: String
    public let hostPhotoURL: String?
    public let visibility: EventVisibility
    public let attendeeLimit: Int?
    public let isRecurring: Bool
    public let isCancelled: Bool
    public let attendees: [AttendeeDTO]
    public let isRequesterAttending: Bool
    /// See `EventSummaryDTO.timeZone`.
    public let timeZone: String?

    public init(
        id: UUID,
        title: String,
        description: String,
        category: EventCategory,
        date: Date,
        cityAddress: String,
        cityLat: Double,
        cityLng: Double,
        venueAddress: String,
        venueLat: Double,
        venueLng: Double,
        hostUserID: UUID?,
        hostGroupID: UUID?,
        hostDisplayName: String,
        hostPhotoURL: String?,
        visibility: EventVisibility,
        attendeeLimit: Int?,
        isRecurring: Bool,
        isCancelled: Bool,
        attendees: [AttendeeDTO],
        isRequesterAttending: Bool,
        timeZone: String? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.category = category
        self.date = date
        self.cityAddress = cityAddress
        self.cityLat = cityLat
        self.cityLng = cityLng
        self.venueAddress = venueAddress
        self.venueLat = venueLat
        self.venueLng = venueLng
        self.hostUserID = hostUserID
        self.hostGroupID = hostGroupID
        self.hostDisplayName = hostDisplayName
        self.hostPhotoURL = hostPhotoURL
        self.visibility = visibility
        self.attendeeLimit = attendeeLimit
        self.isRecurring = isRecurring
        self.isCancelled = isCancelled
        self.attendees = attendees
        self.isRequesterAttending = isRequesterAttending
        self.timeZone = timeZone
    }
}

public struct AttendeeDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let photoURL: String?
    public let joinedAt: Date

    public init(id: UUID, displayName: String, photoURL: String?, joinedAt: Date) {
        self.id = id
        self.displayName = displayName
        self.photoURL = photoURL
        self.joinedAt = joinedAt
    }
}

public struct CreateEventRequest: Codable, Sendable, Equatable {
    public let title: String
    public let description: String
    public let category: EventCategory
    public let date: Date
    public let cityAddress: String
    public let cityLat: Double
    public let cityLng: Double
    public let venueAddress: String
    public let venueLat: Double
    public let venueLng: Double
    /// Set when creating a group-hosted event; the server verifies the
    /// requester is that group's owner or a moderator (M6).
    public let hostGroupID: UUID?
    public let visibility: EventVisibility
    public let isRecurring: Bool
    /// nil = the plan default (5 for a Free host, 100 otherwise). When
    /// set, must be at least 1 and no more than that same plan cap; the
    /// server rejects anything else.
    public let attendeeLimit: Int?
    /// IANA time zone of the event's location. Optional: when omitted, the
    /// server works it out from the venue's (or city's) coordinates. Either
    /// way `date` must be the real instant (e.g. 18:30 in Lisbon is
    /// `18:30Z` in winter, `17:30Z` in summer).
    public let timeZone: String?
    /// The provider's place IDs for the chosen city and venue, kept so a
    /// place can be looked up again (and refreshed, for providers that
    /// limit how long coordinates may be stored).
    public let cityPlaceID: String?
    public let venuePlaceID: String?
    /// Which provider those IDs belong to ("google", "apple", "sample").
    public let placeProvider: String?

    public init(
        title: String,
        description: String,
        category: EventCategory,
        date: Date,
        cityAddress: String,
        cityLat: Double,
        cityLng: Double,
        venueAddress: String,
        venueLat: Double,
        venueLng: Double,
        hostGroupID: UUID? = nil,
        visibility: EventVisibility = .public,
        isRecurring: Bool = false,
        attendeeLimit: Int? = nil,
        timeZone: String? = nil,
        cityPlaceID: String? = nil,
        venuePlaceID: String? = nil,
        placeProvider: String? = nil
    ) {
        self.title = title
        self.description = description
        self.category = category
        self.date = date
        self.cityAddress = cityAddress
        self.cityLat = cityLat
        self.cityLng = cityLng
        self.venueAddress = venueAddress
        self.venueLat = venueLat
        self.venueLng = venueLng
        self.hostGroupID = hostGroupID
        self.visibility = visibility
        self.isRecurring = isRecurring
        self.attendeeLimit = attendeeLimit
        self.timeZone = timeZone
        self.cityPlaceID = cityPlaceID
        self.venuePlaceID = venuePlaceID
        self.placeProvider = placeProvider
    }
}

public struct UpdateEventRequest: Codable, Sendable, Equatable {
    public let title: String?
    public let description: String?
    public let category: EventCategory?
    public let date: Date?
    public let cityAddress: String?
    public let cityLat: Double?
    public let cityLng: Double?
    public let venueAddress: String?
    public let venueLat: Double?
    public let venueLng: Double?
    public let visibility: EventVisibility?

    public init(
        title: String? = nil,
        description: String? = nil,
        category: EventCategory? = nil,
        date: Date? = nil,
        cityAddress: String? = nil,
        cityLat: Double? = nil,
        cityLng: Double? = nil,
        venueAddress: String? = nil,
        venueLat: Double? = nil,
        venueLng: Double? = nil,
        visibility: EventVisibility? = nil
    ) {
        self.title = title
        self.description = description
        self.category = category
        self.date = date
        self.cityAddress = cityAddress
        self.cityLat = cityLat
        self.cityLng = cityLng
        self.venueAddress = venueAddress
        self.venueLat = venueLat
        self.venueLng = venueLng
        self.visibility = visibility
    }
}

/// Query params accepted by `GET /api/v1/events` and the web `/events/filter`
/// endpoint (architecture doc §6): category, city, venue, host, and date.
public struct EventFilterQuery: Codable, Sendable, Equatable {
    public let category: EventCategory?
    public let city: String?
    public let venue: String?
    public let hostUserID: UUID?
    public let hostGroupID: UUID?
    public let onOrAfterDate: Date?
    public let page: Int?

    public init(
        category: EventCategory? = nil,
        city: String? = nil,
        venue: String? = nil,
        hostUserID: UUID? = nil,
        hostGroupID: UUID? = nil,
        onOrAfterDate: Date? = nil,
        page: Int? = nil
    ) {
        self.category = category
        self.city = city
        self.venue = venue
        self.hostUserID = hostUserID
        self.hostGroupID = hostGroupID
        self.onOrAfterDate = onOrAfterDate
        self.page = page
    }
}
