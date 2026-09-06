import Fluent

struct CreateFeedback: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Feedback.schema)
            .id()
            .field("user_id", .uuid, .references(User.schema, "id", onDelete: .setNull))
            .field("message", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Feedback.schema).delete()
    }
}
