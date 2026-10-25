import Fluent
import Vapor
import ExpatEventsAPI

/// `/feedback` (M9 acceptance criterion #8). Works signed in or signed
/// out: `userID` is set for a signed-in submitter and nil otherwise.
struct FeedbackService {
    let db: Database

    static let maxMessageLength = 5000
    static let maxNameLength = 120
    static let maxEmailLength = 254

    func submit(message rawMessage: String, name rawName: String?, email rawEmail: String?, userID: UUID?) async throws -> Feedback {
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            throw APIError(code: "feedback_required", message: "Please enter your feedback.")
        }
        guard message.count <= Self.maxMessageLength else {
            throw APIError(code: "feedback_too_long", message: "Feedback must be \(Self.maxMessageLength) characters or fewer.")
        }
        let name = Self.nonEmpty(rawName)
        let email = Self.nonEmpty(rawEmail)
        // Same limits as the form's maxlength attributes, enforced here
        // too since those are only a browser hint.
        if let name, name.count > Self.maxNameLength {
            throw APIError(code: "name_too_long", message: "Name must be \(Self.maxNameLength) characters or fewer.")
        }
        if let email, email.count > Self.maxEmailLength {
            throw APIError(code: "email_too_long", message: "Email must be \(Self.maxEmailLength) characters or fewer.")
        }
        if let email, !email.contains("@") {
            throw APIError(code: "invalid_email", message: "That email address doesn't look right.")
        }
        let feedback = Feedback(userID: userID, message: message, name: name, email: email)
        try await feedback.save(on: db)
        return feedback
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
