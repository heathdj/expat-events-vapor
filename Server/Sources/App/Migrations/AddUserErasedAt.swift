import Fluent

/// M9. Marks a `User` row whose deletion request has been processed: the
/// row itself is kept as a tombstone (its chat messages, hosted events and
/// owned groups all reference it, and the M9 plan requires chat messages
/// to be anonymized rather than deleted), but every identifying field is
/// erased and this timestamp is what the auth layer checks to refuse it.
///
/// Deliberately a plain optional field, not Fluent's `@Timestamp(on:
/// .delete)` soft-delete: soft-deleting would hide the row from every
/// default `User.query`, which breaks eager-loading `ChatMessage.$user` and
/// friends for exactly the rows that are supposed to survive.
struct AddUserErasedAt: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(User.schema)
            .field("erased_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(User.schema)
            .deleteField("erased_at")
            .update()
    }
}
