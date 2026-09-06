import Fluent
import ExpatEventsAPI

/// Creates a native Postgres enum type for every enum in the shared
/// `ExpatEventsAPI` package, so the database itself enforces valid values
/// (M1 acceptance criterion #2: "enum constraints from the architecture doc"),
/// not just Swift's type system. One migration per type, run before any
/// model migration that references it.
///
/// Each migration mirrors `EnumBuilder`'s pattern: `.create()` in `prepare`,
/// `.read()` + `.delete()` in `revert` (Fluent requires reading the type back
/// out before it can be dropped).
struct CreateUserRoleEnum: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.enum("user_role")
            .case(UserRole.member.rawValue)
            .case(UserRole.admin.rawValue)
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.enum("user_role").delete()
    }
}

struct CreateIdentityProviderEnum: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.enum("identity_provider")
            .case(IdentityProvider.apple.rawValue)
            .case(IdentityProvider.google.rawValue)
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.enum("identity_provider").delete()
    }
}

struct CreatePlanTierEnum: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.enum("plan_tier")
            .case(PlanTier.free.rawValue)
            .case(PlanTier.premium.rawValue)
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.enum("plan_tier").delete()
    }
}

struct CreateBillingCycleEnum: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.enum("billing_cycle")
            .case(BillingCycle.monthly.rawValue)
            .case(BillingCycle.yearly.rawValue)
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.enum("billing_cycle").delete()
    }
}

struct CreateSubscriptionStatusEnum: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.enum("subscription_status")
            .case(SubscriptionStatus.active.rawValue)
            .case(SubscriptionStatus.pastDue.rawValue)
            .case(SubscriptionStatus.canceled.rawValue)
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.enum("subscription_status").delete()
    }
}

struct CreateGroupVisibilityEnum: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.enum("group_visibility")
            .case(GroupVisibility.public.rawValue)
            .case(GroupVisibility.inviteOnly.rawValue)
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.enum("group_visibility").delete()
    }
}

struct CreateGroupRoleEnum: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.enum("group_role")
            .case(GroupRole.owner.rawValue)
            .case(GroupRole.moderator.rawValue)
            .case(GroupRole.member.rawValue)
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.enum("group_role").delete()
    }
}

struct CreateEventCategoryEnum: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.enum("event_category")
            .case(EventCategory.culture.rawValue)
            .case(EventCategory.drinks.rawValue)
            .case(EventCategory.film.rawValue)
            .case(EventCategory.food.rawValue)
            .case(EventCategory.music.rawValue)
            .case(EventCategory.travel.rawValue)
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.enum("event_category").delete()
    }
}

struct CreateEventVisibilityEnum: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.enum("event_visibility")
            .case(EventVisibility.public.rawValue)
            .case(EventVisibility.private.rawValue)
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.enum("event_visibility").delete()
    }
}

struct CreateActivityFeedItemTypeEnum: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.enum("activity_feed_item_type")
            .case(ActivityFeedItemType.joinedEvent.rawValue)
            .case(ActivityFeedItemType.leftEvent.rawValue)
            .case(ActivityFeedItemType.startedFollowing.rawValue)
            .case(ActivityFeedItemType.groupPostedEvent.rawValue)
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.enum("activity_feed_item_type").delete()
    }
}

struct CreateInvoiceStatusEnum: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.enum("invoice_status")
            .case(InvoiceStatus.paid.rawValue)
            .case(InvoiceStatus.open.rawValue)
            .case(InvoiceStatus.uncollectible.rawValue)
            .case(InvoiceStatus.void.rawValue)
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.enum("invoice_status").delete()
    }
}

struct CreateDataExportStatusEnum: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.enum("data_export_status")
            .case(DataExportStatus.pending.rawValue)
            .case(DataExportStatus.ready.rawValue)
            .case(DataExportStatus.expired.rawValue)
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.enum("data_export_status").delete()
    }
}
