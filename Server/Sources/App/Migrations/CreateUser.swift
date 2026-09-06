import Fluent

struct CreateUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        let role = try await database.enum("user_role").read()

        try await database.schema(User.schema)
            .id()
            .field("display_name", .string, .required)
            .field("email", .string, .required)
            .field("photo_url", .string)
            .field("role", role, .required)
            .field("is_suspended", .bool, .required, .sql(.default(false)))
            .field("privacy_policy_version", .string, .required)
            .field("terms_version", .string, .required)
            .field("consented_at", .datetime, .required)
            .field("created_at", .datetime)
            .unique(on: "email")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(User.schema).delete()
    }
}
