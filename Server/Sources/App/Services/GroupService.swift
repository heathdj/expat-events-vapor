import Fluent
import Vapor
import ExpatEventsAPI

/// Shared by `GroupWebController` and (future, M11) any `/api/v1` group
/// surface — same "one service, both surfaces" shape as `EventService`/
/// `ChatService` (architecture §3, §9, M6).
struct GroupService {
    let db: Database

    // MARK: - Fetching

    func find(_ id: UUID) async throws -> Group? {
        try await Group.query(on: db).filter(\.$id == id).with(\.$owner).first()
    }

    func find(slug: String) async throws -> Group? {
        try await Group.query(on: db).filter(\.$slug == slug).with(\.$owner).first()
    }

    /// The group directory (`/groups`) only ever lists `.public` groups.
    /// `.inviteOnly` groups exist in the data model but this MVP
    /// deliberately doesn't build the "request to join" workflow for them
    /// (see `join`'s doc comment and the plan's own explicit scope-out) —
    /// listing a group nobody can self-serve-join would just be a dead
    /// end, so they're left out of the directory entirely. A direct link
    /// to an invite-only group's detail page still works (see `find`
    /// above) for whoever already has the URL.
    func publicGroups() async throws -> [Group] {
        try await Group.query(on: db)
            .filter(\.$visibility == .public)
            .with(\.$owner)
            .sort(\.$createdAt, .ascending)
            .all()
    }

    // MARK: - Mutations

    /// M6 acceptance criterion #1/#2: Premium-only, one owned group at a
    /// time — `PlanLimitsService.assertCanCreateGroup` is the single
    /// enforcement point (already existed before this milestone); this
    /// just adds the actual group row plus the owner's own membership,
    /// which nothing before this milestone did.
    func createGroup(_ request: CreateGroupRequest, ownerID: UUID) async throws -> Group {
        try await PlanLimitsService(db: db).assertCanCreateGroup(ownerID: ownerID)

        let slug = try await uniqueSlug(from: request.name)
        let group = Group(
            name: request.name,
            slug: slug,
            description: request.description,
            visibility: request.visibility,
            ownerID: ownerID
        )
        try await group.save(on: db)

        let ownerMembership = GroupMembership(groupID: try group.requireID(), userID: ownerID, role: .owner)
        try await ownerMembership.save(on: db)

        return group
    }

    /// Slugs are unique (`CreateGroup`'s migration enforces it at the DB
    /// level too) and user-facing in URLs, so collisions get a numeric
    /// suffix rather than a random one — "digital-nomads-berlin-2" reads
    /// better than a UUID fragment. Loops rather than trusting a single
    /// retry: pathological back-to-back creates with the exact same name
    /// are rare but not impossible.
    private func uniqueSlug(from name: String) async throws -> String {
        let base = name
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var candidate = base.isEmpty ? "group" : base
        var suffix = 2
        while try await Group.query(on: db).filter(\.$slug == candidate).count() > 0 {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// M6 acceptance criterion #3: only the owner may promote, and only
    /// up to `PlanLimitsService.freeMaxGroupModerators` (5) at a time —
    /// reusing that constant rather than redefining the cap here, since
    /// it's the same number the architecture doc quotes in one place.
    /// Promoting an already-owner/moderator member is a no-op rather than
    /// an error (idempotent, matching `EventService.join`'s style for an
    /// already-attending user) — only a plain `.member` actually changes
    /// role and counts against the cap.
    func promoteModerator(_ group: Group, memberUserID: UUID, requesterID: UUID) async throws {
        guard group.$owner.id == requesterID else { throw APIError.forbidden }

        let groupID = try group.requireID()
        guard let membership = try await GroupMembership.query(on: db)
            .filter(\.$group.$id == groupID)
            .filter(\.$user.$id == memberUserID)
            .first()
        else {
            throw APIError.notFound
        }

        guard membership.role == .member else { return }

        let currentModeratorCount = try await GroupMembership.query(on: db)
            .filter(\.$group.$id == groupID)
            .filter(\.$role == .moderator)
            .count()
        guard currentModeratorCount < PlanLimitsService.freeMaxGroupModerators else {
            throw APIError(
                code: "moderator_limit_reached",
                message: "A group can have at most \(PlanLimitsService.freeMaxGroupModerators) moderators."
            )
        }

        membership.role = .moderator
        try await membership.save(on: db)
    }

    /// M6's own deliverables list only "group creation, moderator
    /// promotion, directory/detail pages, group-hosted events" — plain
    /// membership join/leave for a `.public` group isn't a numbered
    /// acceptance criterion, but the Members tab and "a member of the
    /// hosting group can see/join that same private event" criterion (#6)
    /// both presuppose *some* way to become a member beyond the seed
    /// command, so this is the minimal version of that: self-serve join,
    /// public groups only.
    ///
    /// `.inviteOnly` groups reject here rather than silently no-op'ing —
    /// the plan explicitly scopes "invite-only groups' request-to-join
    /// workflow" out of this MVP, so there is deliberately no path from
    /// "reject" to "now a member" for one; a caller that reaches this for
    /// an invite-only group gets a clear, distinct error rather than a
    /// confusing silent failure.
    func join(_ group: Group, userID: UUID) async throws {
        guard group.visibility == .public else {
            throw APIError(code: "invite_only", message: "This group is invite-only.")
        }
        let groupID = try group.requireID()
        let alreadyMember = try await GroupMembership.query(on: db)
            .filter(\.$group.$id == groupID)
            .filter(\.$user.$id == userID)
            .count() > 0
        if alreadyMember { return }

        let membership = GroupMembership(groupID: groupID, userID: userID, role: .member)
        try await membership.save(on: db)
    }

    /// The owner can't leave their own group through this path — there's
    /// no ownership-transfer flow built (not in M6's stated deliverables),
    /// so an owner "leaving" would either orphan the group or silently
    /// delete a moderator/member's row while the owner row stayed, neither
    /// of which is right. A non-member calling this is a no-op, matching
    /// `EventService.leave`'s style for symmetry, not an error.
    func leave(_ group: Group, userID: UUID) async throws {
        guard group.$owner.id != userID else {
            throw APIError(code: "owner_cannot_leave", message: "The group owner can't leave their own group.")
        }
        let groupID = try group.requireID()
        try await GroupMembership.query(on: db)
            .filter(\.$group.$id == groupID)
            .filter(\.$user.$id == userID)
            .delete()
    }

    // MARK: - Tab data (group detail page)

    func members(of group: Group) async throws -> [GroupMemberDTO] {
        let groupID = try group.requireID()
        let rows = try await GroupMembership.query(on: db)
            .filter(\.$group.$id == groupID)
            .with(\.$user)
            .sort(\.$joinedAt, .ascending)
            .all()
        return try rows.map { row in
            GroupMemberDTO(
                id: try row.requireID(),
                userID: try row.user.requireID(),
                displayName: row.user.displayName,
                photoURL: row.user.photoURL,
                role: row.role,
                joinedAt: row.joinedAt ?? Date()
            )
        }
    }

    /// M6 acceptance criterion #7's "Upcoming Events" tab: every
    /// non-cancelled event this group hosts, on or after now, soonest
    /// first. Reuses `EventService.summaryDTO` rather than a second DTO
    /// mapper — the shape needed here (title/category/date/city/host/
    /// attendee count) is exactly `EventSummaryDTO`.
    func upcomingEvents(of group: Group, requesterID: UUID?) async throws -> [EventSummaryDTO] {
        let groupID = try group.requireID()
        let events = try await Event.query(on: db)
            .filter(\.$hostGroup.$id == groupID)
            .filter(\.$isCancelled == false)
            .filter(\.$date >= Date())
            .sort(\.$date, .ascending)
            .all()
        let eventService = EventService(db: db)
        var summaries: [EventSummaryDTO] = []
        for event in events {
            summaries.append(try await eventService.summaryDTO(for: event, requesterID: requesterID))
        }
        return summaries
    }

    // MARK: - DTO conversion

    /// `group.owner` must already be eager-loaded (`find(_:)`/`find(slug:)`/
    /// `publicGroups()` above all do `.with(\.$owner)`) — a crash here means
    /// a caller skipped that, same convention `ChatMessage.toDTO()` uses
    /// for its own `user` relation, rather than silently lazy-loading it
    /// here on every call.
    func toDTO(_ group: Group, requesterID: UUID?) async throws -> GroupDTO {
        let groupID = try group.requireID()
        let memberCount = try await GroupMembership.query(on: db)
            .filter(\.$group.$id == groupID)
            .count()
        var requesterRole: GroupRole?
        if let requesterID {
            requesterRole = try await GroupMembership.query(on: db)
                .filter(\.$group.$id == groupID)
                .filter(\.$user.$id == requesterID)
                .first()?.role
        }
        return GroupDTO(
            id: try group.requireID(),
            name: group.name,
            slug: group.slug,
            description: group.groupDescription,
            avatarURL: group.avatarURL,
            coverURL: group.coverURL,
            visibility: group.visibility,
            ownerID: group.$owner.id,
            ownerDisplayName: group.owner.displayName,
            memberCount: memberCount,
            isRequesterMember: requesterRole != nil,
            requesterRole: requesterRole,
            createdAt: group.createdAt ?? Date()
        )
    }
}
