import Fluent

struct CreatePasskeyCredential: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(PasskeyCredential.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("credential_id", .string, .required)
            .field("public_key", .string, .required)
            .field("sign_count", .int, .required, .sql(.default(0)))
            .field("device_label", .string, .required)
            .field("created_at", .datetime)
            .field("last_used_at", .datetime)
            .unique(on: "credential_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(PasskeyCredential.schema).delete()
    }
}
