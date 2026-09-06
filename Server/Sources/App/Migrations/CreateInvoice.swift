import Fluent

struct CreateInvoice: AsyncMigration {
    func prepare(on database: Database) async throws {
        let status = try await database.enum("invoice_status").read()

        try await database.schema(Invoice.schema)
            .id()
            .field("subscription_id", .uuid, .required, .references(Subscription.schema, "id", onDelete: .cascade))
            // Nulled (not deleted) on account erasure — anonymized financial history (§13).
            .field("user_id", .uuid, .references(User.schema, "id", onDelete: .setNull))
            .field("amount_cents", .int, .required)
            .field("currency", .string, .required)
            .field("status", status, .required)
            .field("stripe_invoice_id", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "stripe_invoice_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Invoice.schema).delete()
    }
}
