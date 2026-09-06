import Fluent

struct CreateActivityFeedItem: AsyncMigration {
    func prepare(on database: Database) async throws {
        let type = try await database.enum("activity_feed_item_type").read()

        try await database.schema(ActivityFeedItem.schema)
            .id()
            .field("recipient_user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("actor_user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("type", type, .required)
            .field("event_id", .uuid, .references(Event.schema, "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(ActivityFeedItem.schema).delete()
    }
}
