import Fluent

struct CreateDeletionRequest: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(DeletionRequest.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("requested_at", .datetime)
            .field("processed_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(DeletionRequest.schema).delete()
    }
}
