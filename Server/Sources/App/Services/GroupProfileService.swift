import Fluent
import Vapor
import ExpatEventsAPI

/// Editing a group's profile and logo (theme PR 3, at the user's request):
/// name, description, visibility and a logo, by the group's owner or
/// moderators (user's decision: the same people who can host events for
/// it). The logo is stored in `Group.avatarURL` and shows wherever the
/// group hosts an event (`EventSummaryDTO`/`EventDTO.hostPhotoURL` already
/// carry it). Uploads go through the same checks and storage as profile
/// photos (`ImageSanitizer`, `PhotoStorage`). The slug never changes on a
/// rename, so links to the group keep working.
struct GroupProfileService {
    let db: Database
    let storage: any PhotoStorage

    /// Admins can't yet edit a group's name or logo (only transfer it);
    /// see MILESTONES.md. Nothing deletes groups today; when something
    /// does, it must delete the logo file after its transaction commits.
    static let maxNameLength = 80
    static let maxDescriptionLength = 2000

    /// The owner or a moderator of this group.
    static func canManage(_ group: Group, userID: UUID?, on db: Database) async throws -> Bool {
        guard let userID else { return false }
        if group.$owner.id == userID { return true }
        let groupID = try group.requireID()
        let role = try await GroupMembership.query(on: db)
            .filter(\.$group.$id == groupID)
            .filter(\.$user.$id == userID)
            .first()?.role
        return role == .owner || role == .moderator
    }

    private func assertCanManage(_ group: Group, userID: UUID) async throws {
        guard try await Self.canManage(group, userID: userID, on: db) else {
            throw APIError.forbidden
        }
    }

    /// Trimmed name and description, or the message to show. Group
    /// creation uses the same rules (review), so a new group can always
    /// be saved from its edit page.
    static func validatedDetails(name rawName: String, description rawDescription: String) throws -> (name: String, description: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = rawDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= maxNameLength else {
            throw APIError(code: "invalid_group_name", message: "The group name must be between 1 and \(maxNameLength) characters.")
        }
        guard !description.isEmpty, description.count <= maxDescriptionLength else {
            throw APIError(code: "invalid_group_description", message: "The description must be between 1 and \(maxDescriptionLength) characters.")
        }
        return (name, description)
    }

    /// Owner and moderators edit the name and description. Only the
    /// owner changes the visibility (review): opening an invite-only
    /// group lets anyone join and see its members-only events, and making
    /// a group invite-only stops anyone new joining (there are no invites
    /// yet). `visibility` nil keeps the current one. The permission is
    /// checked again under the row lock, so a moderator removed meanwhile
    /// is refused.
    func updateProfile(_ group: Group, name rawName: String, description rawDescription: String,
                       visibility: GroupVisibility?, by userID: UUID) async throws {
        try await assertCanManage(group, userID: userID)
        let details = try Self.validatedDetails(name: rawName, description: rawDescription)
        let groupID = try group.requireID()
        let saved: Group = try await db.transaction { tx -> Group in
            try await tx.lockRow(Group.schema, id: groupID)
            guard let current = try await Group.find(groupID, on: tx) else { throw APIError.notFound }
            guard try await Self.canManage(current, userID: userID, on: tx) else { throw APIError.forbidden }
            if let visibility, visibility != current.visibility {
                guard current.$owner.id == userID else {
                    throw APIError(code: "visibility_owner_only", message: "Only the group's owner can change who can join.")
                }
                current.visibility = visibility
            }
            current.name = details.name
            current.groupDescription = details.description
            try await current.save(on: tx)
            return current
        }
        group.name = saved.name
        group.groupDescription = saved.groupDescription
        group.visibility = saved.visibility
    }

    /// Checks and cleans the logo, stores it, and removes the one it
    /// replaces. The group row is locked while it's updated, so two
    /// uploads at once can't strand a file.
    func uploadLogo(_ data: Data, for group: Group, by userID: UUID) async throws {
        try await assertCanManage(group, userID: userID)
        guard !data.isEmpty else {
            throw APIError(code: "logo_missing", message: "Choose an image to upload.")
        }
        guard data.count <= ProfilePhotoService.maxUploadBytes else {
            throw APIError(code: "logo_too_large", message: "That image is too large. The limit is 2 MB.")
        }
        let cleaned = try ImageSanitizer.clean(data)
        let groupID = try group.requireID()
        let path = try await storage.save(cleaned.data, fileExtension: cleaned.type.rawValue)
        let previous: String?
        do {
            previous = try await db.transaction { tx -> String? in
                try await tx.lockRow(Group.schema, id: groupID)
                guard let current = try await Group.find(groupID, on: tx) else { throw APIError.notFound }
                guard try await Self.canManage(current, userID: userID, on: tx) else { throw APIError.forbidden }
                let old = current.avatarURL
                current.avatarURL = path
                try await current.save(on: tx)
                return old
            }
        } catch {
            try? await storage.delete(path: path)
            throw error
        }
        group.avatarURL = path
        if let previous, previous != path {
            try? await storage.delete(path: previous)
        }
    }

    func removeLogo(for group: Group, by userID: UUID) async throws {
        try await assertCanManage(group, userID: userID)
        let groupID = try group.requireID()
        let previous: String? = try await db.transaction { tx -> String? in
            try await tx.lockRow(Group.schema, id: groupID)
            guard let current = try await Group.find(groupID, on: tx) else { return nil }
            guard try await Self.canManage(current, userID: userID, on: tx) else { throw APIError.forbidden }
            guard let old = current.avatarURL else { return nil }
            current.avatarURL = nil
            try await current.save(on: tx)
            return old
        }
        group.avatarURL = nil
        if let previous {
            try? await storage.delete(path: previous)
        }
    }
}
