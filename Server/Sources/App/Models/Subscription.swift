import Fluent
import Vapor
import ExpatEventsAPI

/// Replaces the current flat `paid: Bool` flag (architecture §4).
final class Subscription: Model, Content, @unchecked Sendable {
    static let schema = "subscriptions"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Enum(key: "plan")
    var plan: PlanTier

    @OptionalEnum(key: "billing_cycle")
    var billingCycle: BillingCycle?

    @Enum(key: "status")
    var status: SubscriptionStatus

    @OptionalField(key: "stripe_customer_id")
    var stripeCustomerID: String?

    @OptionalField(key: "stripe_subscription_id")
    var stripeSubscriptionID: String?

    @OptionalField(key: "current_period_end")
    var currentPeriodEnd: Date?

    @Field(key: "cancel_at_period_end")
    var cancelAtPeriodEnd: Bool

    /// True for comped Premium granted directly by an admin (§12).
    @Field(key: "granted_by_admin")
    var grantedByAdmin: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    @Children(for: \.$subscription)
    var invoices: [Invoice]

    init() {}

    init(
        id: UUID? = nil,
        userID: User.IDValue,
        plan: PlanTier = .free,
        billingCycle: BillingCycle? = nil,
        status: SubscriptionStatus = .active,
        stripeCustomerID: String? = nil,
        stripeSubscriptionID: String? = nil,
        currentPeriodEnd: Date? = nil,
        cancelAtPeriodEnd: Bool = false,
        grantedByAdmin: Bool = false
    ) {
        self.id = id
        self.$user.id = userID
        self.plan = plan
        self.billingCycle = billingCycle
        self.status = status
        self.stripeCustomerID = stripeCustomerID
        self.stripeSubscriptionID = stripeSubscriptionID
        self.currentPeriodEnd = currentPeriodEnd
        self.cancelAtPeriodEnd = cancelAtPeriodEnd
        self.grantedByAdmin = grantedByAdmin
    }
}

extension Subscription {
    func toDTO() -> SubscriptionDTO {
        SubscriptionDTO(
            plan: plan,
            billingCycle: billingCycle,
            status: status,
            currentPeriodEnd: currentPeriodEnd,
            cancelAtPeriodEnd: cancelAtPeriodEnd,
            grantedByAdmin: grantedByAdmin
        )
    }

    /// Free-tier plan enforcement reads this — active Premium (real or
    /// admin-granted) is the only state that unlocks Premium behavior.
    var isActivePremium: Bool {
        plan == .premium && status == .active
    }
}
