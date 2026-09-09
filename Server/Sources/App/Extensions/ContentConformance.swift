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
extension UserDTO: Content {}
extension ProfileDTO: Content {}
extension EventSummaryDTO: Content {}
extension EventDTO: Content {}
extension AttendeeDTO: Content {}
extension GroupDTO: Content {}
extension GroupMemberDTO: Content {}
extension SubscriptionDTO: Content {}
extension InvoiceDTO: Content {}
extension ActivityFeedItemDTO: Content {}
extension ChatMessageDTO: Content {}
extension DataExportRequestDTO: Content {}
extension AuthTokenResponse: Content {}
extension CheckoutSessionResponse: Content {}
extension APIError: Content {}
