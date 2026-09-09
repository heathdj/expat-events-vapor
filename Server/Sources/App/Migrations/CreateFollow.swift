import Fluent
import FluentSQL

struct CreateFollow: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Follow.schema)
            .id()
            .field("follower_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("following_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .unique(on: "follower_id", "following_id")
            .create()

        if let sql = database as? SQLDatabase {
            try await sql.raw("""
            ALTER TABLE \(unsafeRaw: Follow.schema)
            ADD CONSTRAINT follow_no_self_follow
            CHECK (follower_id <> following_id)
            """).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema(Follow.schema).delete()
    }
}
