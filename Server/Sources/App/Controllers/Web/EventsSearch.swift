import Foundation
import Vapor
import ExpatEventsAPI

/// Everything the `/events` filter panel can ask for (Search & filters PR),
/// parsed leniently from the query string: a blank or unknown value is
/// simply "not filtered", never a 400, since the form sends every field.
/// It becomes an `EventFilterQuery` for `EventService`, and goes back into
/// URLs (Load more, the address bar) with only the values actually set.
struct EventsSearch: Equatable {
    /// The "When" choices. Upcoming (from now on) is the default.
    enum DatePreset: String, CaseIterable {
        case upcoming = ""
        case today
        case weekend
        case week
        case month
        case custom

        var label: String {
            switch self {
            case .upcoming: "Upcoming"
            case .today: "Today"
            case .weekend: "This weekend"
            case .week: "Next 7 days"
            case .month: "This month"
            case .custom: "Pick dates"
            }
        }
    }

    /// The raw form, every field text (the page sends blanks).
    struct Form: Content {
        var tab: String?
        var category: String?
        var q: String?
        var when: String?
        var from: String?
        var to: String?
        var group: String?
        var near: String?
        var nearLat: String?
        var nearLng: String?
        var radius: String?
        var unit: String?
        var tz: String?
        var page: String?
        // Older links and the API's names, still honoured.
        var city: String?
        var venue: String?
        var hostUserID: String?
        var hostGroupID: String?
        var onOrAfterDate: String?
    }

    var tab: EventWebController.ListTab = .all
    var category: EventCategory?
    var text: String?
    var when: DatePreset = .upcoming
    /// `yyyy-MM-dd`, as the date fields send them; only used for `.custom`.
    var from: String?
    var to: String?
    var groupID: UUID?
    var nearLabel: String?
    var nearLatitude: Double?
    var nearLongitude: Double?
    /// In `unit`.
    var radius: Double?
    var unit: DistanceUnit = .km
    /// The viewer's time zone (sent by the page), for Today, This weekend
    /// and picked dates. UTC when unknown.
    var timeZoneIdentifier: String?
    var page: Int = 1
    var city: String?
    var venue: String?
    var hostUserID: UUID?
    var onOrAfterDate: Date?

    var timeZone: TimeZone {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")!
    }

    /// Whether a "near" point was picked (label and coordinates).
    var hasNear: Bool { nearLatitude != nil && nearLongitude != nil }

    var radiusKm: Double {
        min(max((radius ?? unit.defaultRadius) * unit.kilometres, 1), EventService.maxRadiusKm)
    }

    /// Filters beyond the tab (for the empty-state wording, "Clear
    /// filters" and the phone's Filters badge).
    var activeFilterCount: Int {
        [category != nil, text != nil, when != .upcoming, groupID != nil, hasNear,
         city != nil, venue != nil, hostUserID != nil, onOrAfterDate != nil].filter { $0 }.count
    }

    static func parse(_ form: Form, isSignedIn: Bool, preferredUnit: DistanceUnit) -> EventsSearch {
        var search = EventsSearch()
        if isSignedIn { search.tab = nonEmpty(form.tab).flatMap(EventWebController.ListTab.init(rawValue:)) ?? .all }
        search.category = nonEmpty(form.category).flatMap(EventCategory.init(rawValue:))
        search.text = nonEmpty(form.q).map { String($0.prefix(EventService.maxSearchLength)) }
        search.when = nonEmpty(form.when).flatMap(DatePreset.init(rawValue:)) ?? .upcoming
        if search.when == .custom {
            search.from = nonEmpty(form.from).flatMap { validDay($0) }
            search.to = nonEmpty(form.to).flatMap { validDay($0) }
        }
        search.groupID = (nonEmpty(form.group) ?? nonEmpty(form.hostGroupID)).flatMap(UUID.init(uuidString:))
        if let lat = nonEmpty(form.nearLat).flatMap(Double.init), let lng = nonEmpty(form.nearLng).flatMap(Double.init),
           lat.isFinite, lng.isFinite, (-90...90).contains(lat), (-180...180).contains(lng) {
            search.nearLatitude = lat
            search.nearLongitude = lng
            search.nearLabel = nonEmpty(form.near).map { String($0.prefix(PlacesWebController.maxQueryLength)) }
        }
        // The radius is read in the unit it was sent in, then shown in the
        // viewer's own unit (nearest choice).
        let sentUnit = nonEmpty(form.unit).flatMap(DistanceUnit.init(rawValue:)) ?? preferredUnit
        search.unit = preferredUnit
        if let radius = nonEmpty(form.radius).flatMap(Double.init), radius.isFinite, radius > 0 {
            let km = radius * sentUnit.kilometres
            search.radius = preferredUnit.radiusOptions.min { abs($0 * preferredUnit.kilometres - km) < abs($1 * preferredUnit.kilometres - km) }
        }
        search.timeZoneIdentifier = nonEmpty(form.tz).flatMap { TimeZone(identifier: $0) != nil ? $0 : nil }
        search.page = min(max(nonEmpty(form.page).flatMap { Int($0) } ?? 1, 1), EventService.maxPage)
        search.city = nonEmpty(form.city)
        search.venue = nonEmpty(form.venue)
        search.hostUserID = nonEmpty(form.hostUserID).flatMap(UUID.init(uuidString:))
        search.onOrAfterDate = EventService.saneDate(nonEmpty(form.onOrAfterDate).flatMap(Double.init).map(Date.init(timeIntervalSince1970:)))
        return search
    }

    /// Events have no end time, so "upcoming" keeps ones that started up
    /// to three hours ago (a gig that began ten minutes ago is still on).
    static let startedGrace: TimeInterval = 3 * 3600

    /// The date range for `when`, in the viewer's time zone: `start`
    /// inclusive, `end` exclusive (the next day's or month's first
    /// instant, so an event at 23:59:59.5 is still "today"; PR #21 QA).
    /// Upcoming, Next 7 days and This month start from now (less the
    /// grace); Today and the weekend cover whole days; picked dates can
    /// reach into the past.
    func dateRange(now: Date) -> (start: Date?, end: Date?) {
        let fromNow = now.addingTimeInterval(-Self.startedGrace)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfToday = calendar.startOfDay(for: now)
        /// The first instant of the day after `day`.
        func nextDay(_ day: Date) -> Date {
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))!
        }
        switch when {
        case .upcoming:
            return (fromNow, nil)
        case .today:
            return (startOfToday, nextDay(now))
        case .weekend:
            // Saturday and Sunday: this one if it's already the weekend.
            let weekday = calendar.component(.weekday, from: now) // 1 = Sunday ... 7 = Saturday
            let saturday: Date
            switch weekday {
            case 7: saturday = startOfToday
            case 1: saturday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
            default: saturday = calendar.date(byAdding: .day, value: 7 - weekday, to: startOfToday)!
            }
            let sunday = calendar.date(byAdding: .day, value: 1, to: saturday)!
            return (max(saturday, startOfToday), nextDay(sunday))
        case .week:
            return (fromNow, calendar.date(byAdding: .day, value: 7, to: now))
        case .month:
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            return (fromNow, calendar.date(byAdding: .month, value: 1, to: monthStart)!)
        case .custom:
            var first = from.flatMap { Self.day($0, calendar: calendar) }
            var last = to.flatMap { Self.day($0, calendar: calendar) }
            if let f = first, let l = last, f > l {
                (first, last) = (l, f)
            }
            // No start date: from now, like Upcoming.
            return (first ?? fromNow, last.map(nextDay))
        }
    }

    func filter(now: Date = Date()) -> EventFilterQuery {
        let range = dateRange(now: now)
        return EventFilterQuery(
            category: category,
            city: city,
            venue: venue,
            hostUserID: hostUserID,
            hostGroupID: groupID,
            onOrAfterDate: onOrAfterDate ?? range.start,
            beforeDate: range.end,
            search: text,
            nearLatitude: nearLatitude,
            nearLongitude: nearLongitude,
            radiusKm: hasNear ? radiusKm : nil,
            page: page
        )
    }

    /// `/events` with what's set, for Load more and sharing.
    func url(page: Int? = nil) -> String {
        var items: [(String, String)] = []
        if tab != .all { items.append(("tab", tab.rawValue)) }
        if let category { items.append(("category", category.rawValue)) }
        if let text { items.append(("q", text)) }
        if when != .upcoming {
            items.append(("when", when.rawValue))
            if let from { items.append(("from", from)) }
            if let to { items.append(("to", to)) }
            if let timeZoneIdentifier { items.append(("tz", timeZoneIdentifier)) }
        }
        if let groupID { items.append(("group", groupID.uuidString)) }
        if let nearLatitude, let nearLongitude {
            items.append(("near", nearLabel ?? ""))
            items.append(("nearLat", String(nearLatitude)))
            items.append(("nearLng", String(nearLongitude)))
            items.append(("radius", Self.number(radius ?? unit.defaultRadius)))
            items.append(("unit", unit.rawValue))
        }
        if let city { items.append(("city", city)) }
        if let venue { items.append(("venue", venue)) }
        if let hostUserID { items.append(("hostUserID", hostUserID.uuidString)) }
        if let onOrAfterDate { items.append(("onOrAfterDate", String(onOrAfterDate.timeIntervalSince1970))) }
        if let page { items.append(("page", String(page))) }
        return items.isEmpty ? "/events" : PlacesWebController.url("/events", items)
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// A `yyyy-MM-dd` the date fields send, or nil.
    private static func validDay(_ text: String) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return day(text, calendar: calendar) != nil ? text : nil
    }

    private static func day(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1900...2200).contains(parts[0]), (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == parts[2] else { return nil }
        return date
    }
}
