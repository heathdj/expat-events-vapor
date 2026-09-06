import Fluent

struct CreateOAuthIdentity: AsyncMigration {
    func prepare(on database: Database) async throws {
        let provider = try await database.enum("identity_provider").read()

        try await database.schema(OAuthIdentity.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("provider", provider, .required)
            .field("provider_user_id", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "provider", "provider_user_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(OAuthIdentity.schema).delete()
    }
}
