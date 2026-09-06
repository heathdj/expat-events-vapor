import Fluent

struct CreateAdminAuditLog: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(AdminAuditLog.schema)
            .id()
            .field("admin_user_id", .uuid, .required, .references(User.schema, "id", onDelete: .restrict))
            .field("action", .string, .required)
            .field("target_type", .string, .required)
            .field("target_id", .uuid, .required)
            .field("metadata", .dictionary(of: .string), .required, .sql(.default("{}")))
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(AdminAuditLog.schema).delete()
    }
}
