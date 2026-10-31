import Fluent
import Vapor
import ExpatEventsAPI

/// `swift run App make-admin <email>` (M10): gives an existing account
/// admin access to `/admin`. `--revoke` takes it away again. The account
/// must already exist (sign in once first). This is how the first admin is
/// made, locally and on the production server (user's M10 decision); after
/// that it's still the only way, since the admin site deliberately has no
/// "make admin" button.
///
/// Not written to `AdminAuditLog`: a log row needs an acting admin, and
/// whoever runs this is on the server itself. The command prints what it
/// did, and the server's own logs keep that.
struct MakeAdminCommand: Command {
    struct Signature: CommandSignature {
        @Argument(name: "email", help: "The email address of the account to change.")
        var email: String

        @Flag(name: "revoke", help: "Remove admin access instead of granting it.")
        var revoke: Bool
    }

    var help: String { "Grants (or with --revoke, removes) admin access for an existing account." }

    func run(using context: CommandContext, signature: Signature) throws {
        let application = context.application
        let console = context.console
        let email = signature.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let revoke = signature.revoke
        try application.eventLoopGroup.any().makeFutureWithTask {
            let message = try await Self.setAdmin(!revoke, email: email, db: application.db)
            console.print(message)
        }.wait()
    }

    /// Returns what happened, for the console. Throws when the account
    /// doesn't exist, or when revoking would leave no admin at all.
    static func setAdmin(_ makeAdmin: Bool, email: String, db: Database) async throws -> String {
        let user: User
        do {
            user = try await AdminService.uniqueUser(email: email, on: db)
        } catch let error as APIError {
            throw Abort(.badRequest, reason: error.code == "ambiguous_email"
                ? "More than one account uses \(email) in different letter cases."
                : "No account uses \(email). Sign in with it once first.")
        }
        let newRole: UserRole = makeAdmin ? .admin : .member
        guard user.role != newRole else {
            return makeAdmin ? "\(user.email) is already an admin." : "\(user.email) isn't an admin."
        }
        if !makeAdmin {
            let admins = try await User.query(on: db).filter(\.$role == .admin).filter(\.$erasedAt == nil).filter(\.$isSuspended == false)
                .filter(\.$id != user.requireID())
                .count()
            guard admins > 0 else {
                throw Abort(.badRequest, reason: "\(user.email) is the only active admin. Make someone else an admin first.")
            }
        }
        user.role = newRole
        try await user.save(on: db)
        return makeAdmin ? "\(user.email) is now an admin." : "\(user.email) is no longer an admin."
    }
}
