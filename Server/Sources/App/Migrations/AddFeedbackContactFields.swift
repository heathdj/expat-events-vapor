import Fluent

/// M9. The legacy app's feedback form (photo-tracker's FeedbackForm.jsx)
/// collected an optional name and a contact email alongside the message,
/// which is what makes anonymous feedback answerable at all. The M1
/// `Feedback` model only had `userID?` + `message`; this brings it to
/// parity. Both optional -- criterion #8 allows fully anonymous feedback.
struct AddFeedbackContactFields: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Feedback.schema)
            .field("name", .string)
            .field("email", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Feedback.schema)
            .deleteField("name")
            .deleteField("email")
            .update()
    }
}
