import Fluent

/// Location lookup: each event's time zone plus the place-search
/// provider's IDs for its city and venue (see `Event`'s doc comments).
/// All optional, so existing rows are untouched: they keep showing their
/// date as the host typed it, in UTC.
struct AddEventLocationFields: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Event.schema)
            .field("time_zone", .string)
            .field("city_place_id", .string)
            .field("venue_place_id", .string)
            .field("place_provider", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Event.schema)
            .deleteField("time_zone")
            .deleteField("city_place_id")
            .deleteField("venue_place_id")
            .deleteField("place_provider")
            .update()
    }
}
