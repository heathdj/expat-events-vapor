import Fluent

struct CreateChatMessage: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(ChatMessage.schema)
            .id()
            .field("event_id", .uuid, .required, .references(Event.schema, "id", onDelete: .cascade))
            // Stays required: account erasure (§13, M9) anonymizes the
            // User row's identifying fields in place — it never deletes the
            // row — so a deleted user's chat messages keep a valid, non-null
            // reference and still render (as "Deleted user").
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("parent_id", .uuid, .references(ChatMessage.schema, "id", onDelete: .setNull))
            .field("text", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(ChatMessage.schema).delete()
    }
}
