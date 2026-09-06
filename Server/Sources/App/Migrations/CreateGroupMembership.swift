import Fluent

struct CreateGroupMembership: AsyncMigration {
    func prepare(on database: Database) async throws {
        let role = try await database.enum("group_role").read()

        try await database.schema(GroupMembership.schema)
            .id()
            .field("group_id", .uuid, .required, .references(Group.schema, "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("role", role, .required)
            .field("joined_at", .datetime)
            .unique(on: "group_id", "user_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(GroupMembership.schema).delete()
    }
}
