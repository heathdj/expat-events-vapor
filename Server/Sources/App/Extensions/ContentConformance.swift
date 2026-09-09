import Vapor
import ExpatEventsAPI

/// `ExpatEventsAPI` deliberately depends only on `Foundation` (architecture
/// §5 — it's the contract, shared with any future native client, and must
/// build on Apple platforms too), so it can't declare Vapor's `Content`
/// conformance itself. Every DTO returned directly from a route handler
/// needs that conformance added here, on the Server side, instead.
///
/// `Content` is just `Codable` + a couple of defaulted Vapor protocols, so
/// these are all empty extensions — but the compiler needs them to accept
/// e.g. `func me(req: Request) async throws -> UserDTO`.
extension UserDTO: @retroactive Content {}
extension ProfileDTO: @retroactive Content {}
extension EventSummaryDTO: @retroactive Content {}
extension EventDTO: @retroactive Content {}
extension AttendeeDTO: @retroactive Content {}
extension GroupDTO: @retroactive Content {}
extension GroupMemberDTO: @retroactive Content {}
extension SubscriptionDTO: @retroactive Content {}
extension InvoiceDTO: @retroactive Content {}
extension ActivityFeedItemDTO: @retroactive Content {}
extension ChatMessageDTO: @retroactive Content {}
extension DataExportRequestDTO: @retroactive Content {}
extension AuthTokenResponse: @retroactive Content {}
extension CheckoutSessionResponse: @retroactive Content {}
extension APIError: @retroactive Content {}
