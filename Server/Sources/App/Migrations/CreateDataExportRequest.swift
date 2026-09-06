import Fluent

struct CreateDataExportRequest: AsyncMigration {
    func prepare(on database: Database) async throws {
        let status = try await database.enum("data_export_status").read()

        try await database.schema(DataExportRequest.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("requested_at", .datetime)
            .field("status", status, .required)
            .field("download_token", .string, .required)
            .field("expires_at", .datetime)
            .unique(on: "download_token")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(DataExportRequest.schema).delete()
    }
}
