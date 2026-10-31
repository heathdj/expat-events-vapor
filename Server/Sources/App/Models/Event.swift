import Fluent
import Vapor
import ExpatEventsAPI

/// Extends the current `events` doc (architecture §4). Exactly one of
/// `hostUserID` / `hostGroupID` is set — enforced by a DB CHECK constraint
/// in the migration, not just application logic.
final class Event: Model, Content, @unchecked Sendable {
    static let schema = "events"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "title")
    var title: String

    @Field(key: "description")
    var eventDescription: String

    @Enum(key: "category")
    var category: EventCategory

    @Field(key: "date")
    var date: Date

    @Field(key: "city_address")
    var cityAddress: String

    @Field(key: "city_lat")
    var cityLat: Double

    @Field(key: "city_lng")
    var cityLng: Double

    @Field(key: "venue_address")
    var venueAddress: String

    @Field(key: "venue_lat")
    var venueLat: Double

    @Field(key: "venue_lng")
    var venueLng: Double

    @OptionalParent(key: "host_user_id")
    var hostUser: User?

    @OptionalParent(key: "host_group_id")
    var hostGroup: Group?

    @Enum(key: "visibility")
    var visibility: EventVisibility

    /// nil = plan default (100 for Premium, 5 for Free — `PlanLimitsService`).
    @OptionalField(key: "attendee_limit")
    var attendeeLimit: Int?

    /// Flag only in the MVP — no repeat-instance engine (deferred to Phase 2).
    @Field(key: "is_recurring")
    var isRecurring: Bool

    @Field(key: "is_cancelled")
    var isCancelled: Bool

    /// IANA time zone of the event's location (`AddEventLocationFields`).
    /// When set, `date` is a real instant to be shown in this zone. nil for
    /// events created before location lookup, whose `date` is the host's
    /// wall-clock time stored as UTC (`EventDateTag` shows those in UTC).
    @OptionalField(key: "time_zone")
    var timeZone: String?

    /// The place-search provider's IDs for the chosen city and venue, and
    /// which provider issued them, so a place can be looked up again or
    /// its coordinates refreshed (Google only allows keeping them 30 days).
    @OptionalField(key: "city_place_id")
    var cityPlaceID: String?

    @OptionalField(key: "venue_place_id")
    var venuePlaceID: String?

    @OptionalField(key: "place_provider")
    var placeProvider: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Children(for: \.$event)
    var attendees: [EventAttendee]

    @Children(for: \.$event)
    var chatMessages: [ChatMessage]

    init() {}

    init(
        id: UUID? = nil,
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
        hostUserID: User.IDValue? = nil,
        hostGroupID: Group.IDValue? = nil,
        visibility: EventVisibility = .public,
        attendeeLimit: Int? = nil,
        isRecurring: Bool = false,
        isCancelled: Bool = false,
        timeZone: String? = nil,
        cityPlaceID: String? = nil,
        venuePlaceID: String? = nil,
        placeProvider: String? = nil
    ) {
        self.id = id
        self.title = title
        self.eventDescription = description
        self.category = category
        self.date = date
        self.cityAddress = cityAddress
        self.cityLat = cityLat
        self.cityLng = cityLng
        self.venueAddress = venueAddress
        self.venueLat = venueLat
        self.venueLng = venueLng
        self.$hostUser.id = hostUserID
        self.$hostGroup.id = hostGroupID
        self.visibility = visibility
        self.attendeeLimit = attendeeLimit
        self.isRecurring = isRecurring
        self.isCancelled = isCancelled
        self.timeZone = timeZone
        self.cityPlaceID = cityPlaceID
        self.venuePlaceID = venuePlaceID
        self.placeProvider = placeProvider
    }
}
