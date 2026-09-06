import Fluent

struct CreateSubscription: AsyncMigration {
    func prepare(on database: Database) async throws {
        let plan = try await database.enum("plan_tier").read()
        let billingCycle = try await database.enum("billing_cycle").read()
        let status = try await database.enum("subscription_status").read()

        try await database.schema(Subscription.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("plan", plan, .required)
            .field("billing_cycle", billingCycle)
            .field("status", status, .required)
            .field("stripe_customer_id", .string)
            .field("stripe_subscription_id", .string)
            .field("current_period_end", .datetime)
            .field("cancel_at_period_end", .bool, .required, .sql(.default(false)))
            .field("granted_by_admin", .bool, .required, .sql(.default(false)))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Subscription.schema).delete()
    }
}
