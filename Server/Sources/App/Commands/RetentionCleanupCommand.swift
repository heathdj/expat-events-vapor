import Vapor

/// `swift run App retention-cleanup` (M9 acceptance criterion #5). Deletes
/// past/cancelled events (and, by cascade, their chat) older than 30 days
/// -- see `RetentionService`. Run by hand locally; in production (M13) a
/// DigitalOcean scheduled job / cron runs it daily. A command rather than
/// an in-process timer, per the user's M9 decision: easy to test, and it
/// runs exactly once per schedule no matter how many web instances exist.
struct RetentionCleanupCommand: Command {
    struct Signature: CommandSignature {}

    var help: String { "Deletes past and cancelled events (and their chat) older than 30 days." }

    func run(using context: CommandContext, signature: Signature) throws {
        let application = context.application
        let console = context.console
        try application.eventLoopGroup.any().makeFutureWithTask {
            let count = try await RetentionService(db: application.db).run()
            console.print("Deleted \(count) event\(count == 1 ? "" : "s") older than \(RetentionService.retentionDays) days.")
        }.wait()
    }
}
