import Fluent

/// Theme PR 2 (profile photos): where a member's photo comes from.
/// `photo_url` (existing) stays the one shown everywhere; these are its
/// inputs. All optional, so existing rows need no backfill: a nil
/// `photo_source` means automatic.
struct AddUserPhotoFields: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(User.schema)
            .field("photo_source", .string)
            .field("google_photo_url", .string)
            .field("uploaded_photo_path", .string)
            .field("gravatar_available", .bool)
            .field("gravatar_checked_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(User.schema)
            .deleteField("photo_source")
            .deleteField("google_photo_url")
            .deleteField("uploaded_photo_path")
            .deleteField("gravatar_available")
            .deleteField("gravatar_checked_at")
            .update()
    }
}
