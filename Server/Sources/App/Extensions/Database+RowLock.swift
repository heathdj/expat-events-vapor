import Fluent
import FluentSQL
import Vapor

extension Database {
    /// Locks one row (`SELECT ... FOR UPDATE`) until the surrounding
    /// transaction ends, so two requests acting on the same row at once
    /// take turns instead of both passing a "has this already happened?"
    /// check (found by M10's independent review: two "Erase account now"
    /// clicks, or a click racing `process-deletions`). Only meaningful
    /// inside `transaction`. Re-read the row after locking it.
    func lockRow(_ schema: String, id: UUID) async throws {
        guard let sql = self as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "Row locks require a SQL database.")
        }
        try await sql.raw("SELECT id FROM \(unsafeRaw: schema) WHERE id = \(bind: id) FOR UPDATE").run()
    }

    /// Deletes every web session signed in as `userID`. Vapor's
    /// ModelSessionAuthenticatable stores the user's ID under
    /// "_UserSession" in each session's JSON data. Used by account erasure
    /// (M9) and suspension (M10), so a restored account doesn't find its
    /// old sessions working again.
    func deleteWebSessions(for userID: UUID) async throws {
        guard let sql = self as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "Session purge requires a SQL database.")
        }
        try await sql.raw("""
        DELETE FROM \(unsafeRaw: SessionRecord.schema)
        WHERE data->>'_UserSession' = \(bind: userID.uuidString)
        """).run()
    }
}
