import Fluent

struct CreateGroup: AsyncMigration {
    func prepare(on database: Database) async throws {
        let visibility = try await database.enum("group_visibility").read()

        try await database.schema(Group.schema)
            .id()
            .field("name", .string, .required)
            .field("slug", .string, .required)
            .field("description", .string, .required)
            .field("avatar_url", .string)
            .field("cover_url", .string)
            .field("visibility", visibility, .required)
            .field("owner_id", .uuid, .required, .references(User.schema, "id", onDelete: .restrict))
            .field("created_at", .datetime)
            .unique(on: "slug")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Group.schema).delete()
    }
}
