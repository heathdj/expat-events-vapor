import Fluent
import Vapor
import ExpatEventsAPI

final class Invoice: Model, Content, @unchecked Sendable {
    static let schema = "invoices"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "subscription_id")
    var subscription: Subscription

    /// Nulled (not deleted) when the owning user is erased, so financial
    /// history survives account deletion (architecture §13, M9).
    @OptionalParent(key: "user_id")
    var user: User?

    @Field(key: "amount_cents")
    var amountCents: Int

    @Field(key: "currency")
    var currency: String

    @Enum(key: "status")
    var status: InvoiceStatus

    @Field(key: "stripe_invoice_id")
    var stripeInvoiceID: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        subscriptionID: Subscription.IDValue,
        userID: User.IDValue?,
        amountCents: Int,
        currency: String = "usd",
        status: InvoiceStatus,
        stripeInvoiceID: String
    ) {
        self.id = id
        self.$subscription.id = subscriptionID
        self.$user.id = userID
        self.amountCents = amountCents
        self.currency = currency
        self.status = status
        self.stripeInvoiceID = stripeInvoiceID
    }
}

extension Invoice {
    func toDTO() throws -> InvoiceDTO {
        InvoiceDTO(
            id: try requireID(),
            amountCents: amountCents,
            currency: currency,
            status: status,
            createdAt: createdAt ?? Date()
        )
    }
}
