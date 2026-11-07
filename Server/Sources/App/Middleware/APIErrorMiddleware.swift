import Vapor
import ExpatEventsAPI

/// Wraps every `/api/v1` route so every error response — ours or Vapor's
/// own `Abort` — comes back as the shared `{code, message}` `APIError`
/// shape (architecture §5), never a bare 500 and never Vapor's default
/// `{"error":true,"reason":...}` abort body. M2 acceptance criterion #6:
/// an invalid/expired token must be a structured `401`, never a `500`.
struct APIErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch let apiError as APIError {
            return try encode(apiError, status: apiError.httpStatus)
        } catch let abort as AbortError {
            return try encode(APIError(code: "\(abort.status.code)", message: abort.reason), status: abort.status)
        } catch {
            request.logger.report(error: error)
            return try encode(
                APIError(code: "internal_error", message: "Something went wrong. Please try again."),
                status: .internalServerError
            )
        }
    }

    private func encode(_ error: APIError, status: HTTPResponseStatus) throws -> Response {
        let response = Response(status: status)
        try response.content.encode(error, as: .json)
        return response
    }
}

extension APIError {
    var httpStatus: HTTPResponseStatus {
        switch code {
        case "invalid_provider_token", "unauthorized": return .unauthorized
        case "forbidden", "plan_limit_exceeded", "account_suspended": return .forbidden
        case "not_found": return .notFound
        case "email_required": return .badRequest
        default: return .badRequest
        }
    }
}

/// Web pages (everything outside `/api/v1`) go through Vapor's own
/// ErrorMiddleware, which turned any `APIError` into a 500 (the gap noted
/// in M4). As an `AbortError` it gets the same status as the API: 404 for
/// an event you can't see, 403 for forbidden, 400 for bad input. Fixed in
/// the Search & filters PR, where the Events PR's card test caught it.
extension APIError: @retroactive AbortError {
    public var status: HTTPResponseStatus { httpStatus }
    public var reason: String { message }
}

