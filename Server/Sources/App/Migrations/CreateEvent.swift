import Fluent
import FluentSQL

struct CreateEvent: AsyncMigration {
    func prepare(on database: Database) async throws {
        let category = try await database.enum("event_category").read()
        let visibility = try await database.enum("event_visibility").read()

        try await database.schema(Event.schema)
            .id()
            .field("title", .string, .required)
            .field("description", .string, .required)
            .field("category", category, .required)
            .field("date", .datetime, .required)
            .field("city_address", .string, .required)
            .field("city_lat", .double, .required)
            .field("city_lng", .double, .required)
            .field("venue_address", .string, .required)
            .field("venue_lat", .double, .required)
            .field("venue_lng", .double, .required)
            .field("host_user_id", .uuid, .references(User.schema, "id", onDelete: .setNull))
            .field("host_group_id", .uuid, .references(Group.schema, "id", onDelete: .setNull))
            .field("visibility", visibility, .required)
            .field("attendee_limit", .int)
            .field("is_recurring", .bool, .required, .sql(.default(false)))
            .field("is_cancelled", .bool, .required, .sql(.default(false)))
            .field("created_at", .datetime)
            .create()

        // Exactly one of hostUserID/hostGroupID is set (architecture §4) —
        // enforced at the database level, not just application logic.
        if let sql = database as? SQLDatabase {
            try await sql.raw("""
            ALTER TABLE \(unsafeRaw: Event.schema)
            ADD CONSTRAINT event_exactly_one_host
            CHECK (num_nonnulls(host_user_id, host_group_id) = 1)
            """).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema(Event.schema).delete()
    }
}
