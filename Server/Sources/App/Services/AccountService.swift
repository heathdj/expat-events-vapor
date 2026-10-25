import Fluent
import FluentSQL
import Vapor
import ExpatEventsAPI

/// The `/account` page's data-rights operations (architecture §13, M9):
/// "Download my data," "Delete account," and processing a deletion
/// request. Shared by `AccountWebController`, the `process-deletions`
/// command, and any future `/api/v1/account` routes -- the same
/// one-service-both-surfaces convention every other domain follows.
struct AccountService {
    let db: Database

    /// What an erased account's tombstone row shows wherever it's still
    /// referenced (its anonymized chat messages, an owned group's owner
    /// line, a past event's host line).
    static let erasedDisplayName = "Deleted user"

    // MARK: - Profile

    /// The one profile edit the account page offers: display name.
    /// Trimmed; 1...80 characters.
    func updateDisplayName(_ rawName: String, for user: User) async throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else {
            throw APIError(code: "invalid_display_name", message: "Display name must be between 1 and 80 characters.")
        }
        user.displayName = name
        try await user.save(on: db)
    }

    // MARK: - Export (criterion #2)

    /// Builds the requester's export and records a `DataExportRequest`
    /// for it. Synchronous by design -- the MVP plan's GDPR row ships "a
    /// simpler synchronous version" instead of an async job queue, so the
    /// record is created already `.ready` and there's no download link
    /// to expire. See `AccountDataExportDTO`'s doc comment for what's
    /// deliberately left out so nothing belonging to anyone else leaks.
    func exportData(for user: User, now: Date = Date()) async throws -> AccountDataExportDTO {
        let userID = try user.requireID()
        let plan = try await PlanLimitsService(db: db).subscription(for: userID).plan

        let hostedEvents = try await Event.query(on: db)
            .filter(\.$hostUser.$id == userID)
            .sort(\.$date)
            .all()
        let attendance = try await EventAttendee.query(on: db)
            .filter(\.$user.$id == userID)
            .sort(\.$joinedAt)
            .all()
        let memberships = try await GroupMembership.query(on: db)
            .filter(\.$user.$id == userID)
            .with(\.$group)
            .sort(\.$joinedAt)
            .all()
        let messages = try await ChatMessage.query(on: db)
            .filter(\.$user.$id == userID)
            .sort(\.$createdAt)
            .all()
        let following = try await Follow.query(on: db)
            .filter(\.$follower.$id == userID)
            .sort(\.$createdAt)
            .all()
        let feedback = try await Feedback.query(on: db)
            .filter(\.$user.$id == userID)
            .sort(\.$createdAt)
            .all()
        let identities = try await OAuthIdentity.query(on: db)
            .filter(\.$user.$id == userID)
            .all()

        let export = AccountDataExportDTO(
            exportedAt: now,
            profile: .init(
                id: userID,
                displayName: user.displayName,
                email: user.email,
                photoURL: user.photoURL,
                plan: plan,
                createdAt: user.createdAt,
                privacyPolicyVersion: user.privacyPolicyVersion,
                termsVersion: user.termsVersion,
                consentedAt: user.consentedAt
            ),
            hostedEvents: try hostedEvents.map {
                .init(
                    id: try $0.requireID(),
                    title: $0.title,
                    description: $0.eventDescription,
                    date: $0.date,
                    cityAddress: $0.cityAddress,
                    venueAddress: $0.venueAddress,
                    visibility: $0.visibility,
                    isCancelled: $0.isCancelled
                )
            },
            attendedEvents: attendance.map { .init(eventID: $0.$event.id, joinedAt: $0.joinedAt) },
            groupMemberships: memberships.map {
                .init(groupID: $0.$group.id, groupName: $0.group.name, role: $0.role, joinedAt: $0.joinedAt)
            },
            chatMessages: try messages.map {
                .init(id: try $0.requireID(), eventID: $0.$event.id, parentMessageID: $0.$parent.id, text: $0.text, createdAt: $0.createdAt)
            },
            followingUserIDs: following.map { $0.$following.id },
            feedback: feedback.map { .init(message: $0.message, name: $0.name, email: $0.email, createdAt: $0.createdAt) },
            signInProviders: identities.map(\.provider)
        )

        let record = DataExportRequest(userID: userID, status: .ready, downloadToken: UUID().uuidString)
        try await record.save(on: db)
        return export
    }

    // MARK: - Deletion request (criterion #3, first half)

    func pendingDeletionRequest(for userID: UUID) async throws -> DeletionRequest? {
        try await DeletionRequest.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$processedAt == nil)
            .first()
    }

    /// Records a pending `DeletionRequest`. Idempotent: asking twice
    /// returns the request that's already pending rather than queueing a
    /// second one. Erases nothing by itself -- per the user's M9
    /// decision, deletion is "request only, process later," fulfilled by
    /// `processPendingDeletions` (the `process-deletions` command today,
    /// M10's admin Data-requests section later).
    func requestDeletion(for userID: UUID) async throws -> DeletionRequest {
        if let existing = try await pendingDeletionRequest(for: userID) {
            return existing
        }
        let request = DeletionRequest(userID: userID)
        try await request.save(on: db)
        return request
    }

    // MARK: - Deletion processing (criteria #3 second half, #4)

    /// Processes every pending request. Returns how many were processed.
    @discardableResult
    func processPendingDeletions(now: Date = Date()) async throws -> Int {
        let pending = try await DeletionRequest.query(on: db)
            .filter(\.$processedAt == nil)
            .all()
        for request in pending {
            try await process(request, now: now)
        }
        return pending.count
    }

    /// Erases one account, in a single transaction so a failure part-way
    /// leaves nothing half-erased:
    ///
    /// - Identifying `User` fields are overwritten (name, email, photo)
    ///   and `erasedAt` is set. The row itself stays as a tombstone --
    ///   see `AddUserErasedAt`.
    /// - Their `ChatMessage`s are kept, now attributed to that tombstone
    ///   ("Deleted user") -- anonymized, not deleted (criterion #3).
    /// - Their `Invoice` rows are kept with `user_id` nulled (criterion #3).
    /// - Every sign-in method is removed (OAuth identities, passkeys) and
    ///   every live web session for the account is deleted, so nothing can
    ///   authenticate as it again (criterion #4). A later Apple/Google
    ///   sign-in with the same provider account creates a brand-new,
    ///   unrelated account: neither `findOrCreateUser` lookup (provider
    ///   identity, then email) can find the erased row anymore.
    /// - Social graph and activity are removed (follows both ways, feed
    ///   items they sent or received, event attendance, non-owner group
    ///   memberships), and their own upcoming self-hosted events are
    ///   cancelled, since there's no longer a host behind them.
    ///
    /// Known gap, tracked in MILESTONES.md: a group they *own* stays
    /// owned by the tombstone -- `groups.owner_id` is `ON DELETE
    /// RESTRICT` and ownership transfer is M10's admin feature.
    func process(_ request: DeletionRequest, now: Date = Date()) async throws {
        let userID = request.$user.id
        try await db.transaction { tx in
            guard let user = try await User.find(userID, on: tx) else { return }

            user.displayName = Self.erasedDisplayName
            user.email = "erased-\(userID.uuidString.lowercased())@erased.invalid"
            user.photoURL = nil
            user.erasedAt = now
            try await user.save(on: tx)

            try await OAuthIdentity.query(on: tx).filter(\.$user.$id == userID).delete()
            try await PasskeyCredential.query(on: tx).filter(\.$user.$id == userID).delete()

            // Vapor's ModelSessionAuthenticatable stores the signed-in
            // user under "_UserSession" in each session's JSON data.
            // (`ActiveUserSessionAuthenticator` also refuses an erased user,
            // so a session created by a sign-in racing this transaction is
            // inert too.) Throws rather than silently skipping if the
            // database ever isn't SQL-backed.
            guard let sql = tx as? SQLDatabase else {
                throw Abort(.internalServerError, reason: "Session purge requires a SQL database.")
            }
            try await sql.raw("""
            DELETE FROM \(unsafeRaw: SessionRecord.schema)
            WHERE data->>'_UserSession' = \(bind: userID.uuidString)
            """).run()

            try await Invoice.query(on: tx)
                .filter(\.$user.$id == userID)
                .set(\.$user.$id, to: nil)
                .update()

            try await Follow.query(on: tx)
                .group(.or) { $0.filter(\.$follower.$id == userID).filter(\.$following.$id == userID) }
                .delete()
            try await ActivityFeedItem.query(on: tx)
                .group(.or) { $0.filter(\.$actor.$id == userID).filter(\.$recipient.$id == userID) }
                .delete()
            try await EventAttendee.query(on: tx).filter(\.$user.$id == userID).delete()
            try await GroupMembership.query(on: tx)
                .filter(\.$user.$id == userID)
                .filter(\.$role != .owner)
                .delete()

            try await Event.query(on: tx)
                .filter(\.$hostUser.$id == userID)
                .filter(\.$date > now)
                .set(\.$isCancelled, to: true)
                .update()

            try await Feedback.query(on: tx)
                .filter(\.$user.$id == userID)
                .set(\.$name, to: nil)
                .set(\.$email, to: nil)
                .set(\.$user.$id, to: nil)
                .update()

            request.processedAt = now
            try await request.save(on: tx)
        }
    }
}
