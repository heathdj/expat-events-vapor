import Vapor
import ExpatEventsAPI

/// `/feedback` (M9 acceptance criterion #8). Signed in or signed out --
/// a signed-in submitter's `Feedback.userID` is set, an anonymous one's is
/// nil. Form fields match the legacy app's feedback form (name, email,
/// message), prefilled from the account when signed in.
struct FeedbackWebController: RouteCollection {
    struct FeedbackPageContext: Encodable {
        let title = "Feedback"
        let isSignedIn: Bool
        let name: String
        let email: String
        let message: String
        let sent: Bool
        let errorMessage: String?
    }

    struct FeedbackForm: Content {
        let name: String?
        let email: String?
        let message: String
    }

    func boot(routes: RoutesBuilder) throws {
        let optionallyAuthenticated = routes.grouped(User.activeSessionAuthenticator())
        optionallyAuthenticated.get("feedback", use: page)
        optionallyAuthenticated.post("feedback", use: submit)
    }

    @Sendable
    func page(req: Request) async throws -> View {
        let user = req.auth.get(User.self)
        let sent = (try? req.query.get(String.self, at: "sent")) == "1"
        return try await req.view.render("pages/feedback", FeedbackPageContext(
            isSignedIn: user != nil,
            name: user?.displayName ?? "",
            email: user?.email ?? "",
            message: "",
            sent: sent,
            errorMessage: nil
        ))
    }

    /// Post/redirect/get on success, so a refresh can't resubmit. On a
    /// validation error the form re-renders with what was typed.
    @Sendable
    func submit(req: Request) async throws -> Response {
        let user = req.auth.get(User.self)
        let form = try req.content.decode(FeedbackForm.self)
        do {
            _ = try await FeedbackService(db: req.db).submit(
                message: form.message,
                name: form.name,
                email: form.email,
                userID: try user?.requireID()
            )
            return req.redirect(to: "/feedback?sent=1")
        } catch let error as APIError {
            let view = try await req.view.render("pages/feedback", FeedbackPageContext(
                isSignedIn: user != nil,
                name: form.name ?? "",
                email: form.email ?? "",
                message: form.message,
                sent: false,
                errorMessage: error.message
            ))
            let response = try await view.encodeResponse(for: req)
            response.status = .unprocessableEntity
            return response
        }
    }
}
