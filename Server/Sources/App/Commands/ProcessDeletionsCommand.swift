import Vapor

/// `swift run App process-deletions` (M9). Processes every pending
/// "Delete account" request -- see `AccountService.process` for exactly
/// what gets erased. Per the user's M9 decision, "Delete account" only
/// records a request; this command (and, once built, M10's admin
/// Data-requests section) is what fulfills it. Locally you run it by
/// hand; in production (M13) a scheduled job runs it.
struct ProcessDeletionsCommand: Command {
    struct Signature: CommandSignature {}

    var help: String { "Erases every account with a pending deletion request." }

    func run(using context: CommandContext, signature: Signature) throws {
        let application = context.application
        let console = context.console
        try application.eventLoopGroup.any().makeFutureWithTask {
            let count = try await AccountService(db: application.db).processPendingDeletions()
            console.print("Processed \(count) pending deletion request\(count == 1 ? "" : "s").")
        }.wait()
    }
}
