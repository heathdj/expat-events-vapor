import Foundation

/// A consistent `{code, message}` error shape for every `/api/v1` response
/// (architecture doc §5). Web (Leaf) error pages are rendered separately —
/// this type is JSON-only.
public struct APIError: Codable, Error, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    // Common, reusable cases referenced throughout the plan's acceptance
    // criteria (e.g. M2.6: invalid provider token -> structured 401, never a 500).
    public static let invalidProviderToken = APIError(
        code: "invalid_provider_token",
        message: "The sign-in token could not be verified."
    )

    public static let unauthorized = APIError(
        code: "unauthorized",
        message: "Authentication is required for this request."
    )

    public static let forbidden = APIError(
        code: "forbidden",
        message: "You don't have permission to do that."
    )

    public static func planLimit(_ message: String) -> APIError {
        APIError(code: "plan_limit_exceeded", message: message)
    }

    public static let notFound = APIError(
        code: "not_found",
        message: "The requested resource was not found."
    )
}
