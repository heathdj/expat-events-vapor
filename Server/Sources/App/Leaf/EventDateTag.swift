import Foundation
import Leaf
import Vapor

/// `#eventDate(event.date, "short", event.timeZone)`, or `"long"`.
///
/// With a time zone (every event created since location lookup), `date` is
/// a real instant and is shown as local time at the event: 18:30 in Madrid
/// reads "6:30 PM" for everyone, wherever they are. Without one (events
/// created before), `date` is the host's wall-clock time stored as UTC, so
/// it's shown in UTC, which gives back exactly what the host typed.
///
/// A custom tag rather than LeafKit's built-in `#date(...)`, which formats
/// in the server's own locale: this pins `en_US_POSIX` so the output is the
/// same on every machine (and in tests). A fresh `DateFormatter` per call:
/// `DateFormatter` isn't documented thread-safe on Linux (the deploy
/// target), and Leaf renders requests concurrently.
///
/// "short" matches the design canvas's event cards ("Sat, Sep 5 · 7:00 PM");
/// "long" its event-detail banner ("Saturday, September 5, 2026 · 6:30 PM").
struct EventDateTag: LeafTag {
    static let shortFormat = "EEE, MMM d · h:mm a"
    static let longFormat = "EEEE, MMMM d, yyyy · h:mm a"

    func render(_ ctx: LeafContext) throws -> LeafData {
        guard (1...3).contains(ctx.parameters.count), let seconds = ctx.parameters[0].double else {
            // Not LeafKit's own LeafError: the Leaf module doesn't
            // re-export it, and LeafKit isn't a declared dependency.
            throw Abort(.internalServerError, reason: "#eventDate(date, \"short\"|\"long\", timeZone) needs a date")
        }
        let style = ctx.parameters.count >= 2 ? ctx.parameters[1].string : "short"
        let zone = ctx.parameters.count == 3 ? ctx.parameters[2].string.flatMap(TimeZone.init(identifier:)) : nil
        let formatter = Self.makeFormatter(style == "long" ? Self.longFormat : Self.shortFormat, timeZone: zone)
        return .string(formatter.string(from: Date(timeIntervalSince1970: seconds)))
    }

    static func makeFormatter(_ format: String, timeZone: TimeZone?) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone ?? TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}

/// Parses the create form's `<input type="datetime-local">` value
/// (`2026-12-05T18:30`, or with seconds) as local time in the event's time
/// zone, the counterpart of `EventDateTag`. With no time zone (no location
/// chosen) it's read as UTC, matching how such events are displayed. Before
/// the event-basics fix the form's `date` was decoded as a `Date`, which
/// Vapor's form decoder only accepts as a number, so every real browser
/// submission failed.
///
/// The text is first read as plain date components (in UTC, where every
/// time exists), then turned into an instant with `Calendar` in the event's
/// zone. That matters on daylight-saving days: `DateFormatter` rejects a
/// local time the clocks skip (02:30 in Madrid on the last Sunday of
/// March), while `Calendar` resolves it to a real instant instead of
/// failing the form (found by the location PR's review).
enum EventDateParsing {
    private static let formats = ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss"]

    static func parse(_ value: String, timeZone: TimeZone? = nil) -> Date? {
        let utc = TimeZone(identifier: "UTC") ?? .current
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = utc
            formatter.dateFormat = format
            guard let asUTC = formatter.date(from: trimmed) else { continue }

            var utcCalendar = Calendar(identifier: .gregorian)
            utcCalendar.timeZone = utc
            let components = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: asUTC)
            var localCalendar = Calendar(identifier: .gregorian)
            localCalendar.timeZone = timeZone ?? utc
            return localCalendar.date(from: components)
        }
        return nil
    }
}
