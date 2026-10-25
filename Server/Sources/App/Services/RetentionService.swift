import Fluent
import Vapor

/// M9 acceptance criterion #5: past and cancelled events older than 30
/// days are deleted, along with their chat, for every host regardless of
/// plan (Free, Premium, or a group).
///
/// "Older than 30 days" is measured from the event's own `date`: `Event`
/// has no `cancelledAt` column, so a cancelled event is kept until 30
/// days after the date it was scheduled for, exactly like a past one.
/// A cancelled event scheduled for the future is not touched yet.
///
/// Deleting the `Event` row is enough: `chat_messages`, `event_attendees`
/// and `activity_feed_items` all reference it `ON DELETE CASCADE`.
struct RetentionService {
    let db: Database

    static let retentionDays = 30

    @discardableResult
    func run(now: Date = Date()) async throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 24 * 60 * 60)
        let expired = try await Event.query(on: db)
            .filter(\.$date < cutoff)
            .all()
        for event in expired {
            try await event.delete(on: db)
        }
        return expired.count
    }
}
