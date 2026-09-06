import Foundation

public struct SubscriptionDTO: Codable, Sendable, Equatable {
    public let plan: PlanTier
    public let billingCycle: BillingCycle?
    public let status: SubscriptionStatus
    public let currentPeriodEnd: Date?
    public let cancelAtPeriodEnd: Bool
    public let grantedByAdmin: Bool

    public init(
        plan: PlanTier,
        billingCycle: BillingCycle?,
        status: SubscriptionStatus,
        currentPeriodEnd: Date?,
        cancelAtPeriodEnd: Bool,
        grantedByAdmin: Bool
    ) {
        self.plan = plan
        self.billingCycle = billingCycle
        self.status = status
        self.currentPeriodEnd = currentPeriodEnd
        self.cancelAtPeriodEnd = cancelAtPeriodEnd
        self.grantedByAdmin = grantedByAdmin
    }
}

public struct InvoiceDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let amountCents: Int
    public let currency: String
    public let status: InvoiceStatus
    public let createdAt: Date

    public init(id: UUID, amountCents: Int, currency: String, status: InvoiceStatus, createdAt: Date) {
        self.id = id
        self.amountCents = amountCents
        self.currency = currency
        self.status = status
        self.createdAt = createdAt
    }
}

public struct CheckoutSessionResponse: Codable, Sendable, Equatable {
    public let checkoutURL: URL

    public init(checkoutURL: URL) {
        self.checkoutURL = checkoutURL
    }
}

public struct UpgradePlanRequest: Codable, Sendable, Equatable {
    public let billingCycle: BillingCycle

    public init(billingCycle: BillingCycle) {
        self.billingCycle = billingCycle
    }
}
