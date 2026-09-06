import Fluent

struct CreateEventAttendee: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(EventAttendee.schema)
            .id()
            .field("event_id", .uuid, .required, .references(Event.schema, "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("joined_at", .datetime)
            .unique(on: "event_id", "user_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(EventAttendee.schema).delete()
    }
}
