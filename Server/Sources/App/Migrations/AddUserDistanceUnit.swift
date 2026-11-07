import Fluent

/// Search & filters PR: a member's distance unit ("km" or "mi"). Optional,
/// so existing rows need no backfill: nil means kilometres.
struct AddUserDistanceUnit: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(User.schema)
            .field("distance_unit", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(User.schema)
            .deleteField("distance_unit")
            .update()
    }
}
