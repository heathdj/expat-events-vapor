import Foundation
import Leaf
import Vapor

/// `#eventDate(event.date, "short")` / `#eventDate(event.date, "long")`.
///
/// Events have no time zone of their own (there's no `timeZone` column,
/// and venue coordinates are still placeholders until the M4 autocomplete
/// follow-up), so an event's `date` is treated as the host's *wall-clock*
/// time: the create form parses what the host typed as UTC
/// (`EventDateParsing`), and this tag formats it back in UTC. Everyone
/// sees the time the host entered, which is what you want for an
/// in-person event ("7 PM at the venue"). Known limitation, tracked in
/// MILESTONES.md, in both directions: an API client sending a real
/// instant with an offset would see it shown as UTC, and an API client
/// showing `EventDTO.date` in the device's own time zone would shift a
/// web-created event (Lisbon 18:30 shows as 2:30 PM in New York);
/// `onOrAfterDate` comparisons are off by the host's UTC offset too. The
/// proper fix is storing each event's time zone.
///
/// A custom tag rather than LeafKit's built-in `#date(...)`, which formats
/// in the server's own locale: this pins `en_US_POSIX` so the output is
/// the same on every machine (and in tests).
///
/// "short" matches the design canvas's event cards ("Sat, Sep 5 · 7:00 PM");
/// "long" its event-detail banner ("Saturday, September 5, 2026 · 6:30 PM").
///
/// A fresh `DateFormatter` per call rather than shared static ones:
/// `DateFormatter` isn't documented thread-safe on Linux (the M13 deploy
/// target), and Leaf renders requests concurrently. The cost is a few
/// microseconds per date on a page.
struct EventDateTag: LeafTag {
    static let shortFormat = "EEE, MMM d · h:mm a"
    static let longFormat = "EEEE, MMMM d, yyyy · h:mm a"

    func render(_ ctx: LeafContext) throws -> LeafData {
        guard (1...2).contains(ctx.parameters.count), let seconds = ctx.parameters[0].double else {
            // Not LeafKit's own LeafError: the Leaf module doesn't
            // re-export it, and LeafKit isn't a declared dependency.
            throw Abort(.internalServerError, reason: "#eventDate(date, \"short\"|\"long\") needs a date")
        }
        let style = ctx.parameters.count == 2 ? ctx.parameters[1].string : "short"
        let date = Date(timeIntervalSince1970: seconds)
        return .string(Self.makeFormatter(style == "long" ? Self.longFormat : Self.shortFormat).string(from: date))
    }

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}

/// Parses the create form's `<input type="datetime-local">` value
/// (`2026-12-05T18:30`, or with seconds) as wall-clock time in UTC --
/// the counterpart of `EventDateTag`. Before this, the form's `date` was
/// decoded as a `Date`, which Vapor's form decoder only accepts as a
/// number of seconds, so every real browser submission failed.
enum EventDateParsing {
    private static let formats = ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss"]

    static func parse(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }
}
