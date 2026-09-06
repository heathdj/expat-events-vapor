import Foundation

public struct GroupDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let slug: String
    public let description: String
    public let avatarURL: String?
    public let coverURL: String?
    public let visibility: GroupVisibility
    public let ownerID: UUID
    public let ownerDisplayName: String
    public let memberCount: Int
    public let isRequesterMember: Bool
    public let requesterRole: GroupRole?
    public let createdAt: Date

    public init(
        id: UUID,
        name: String,
        slug: String,
        description: String,
        avatarURL: String?,
        coverURL: String?,
        visibility: GroupVisibility,
        ownerID: UUID,
        ownerDisplayName: String,
        memberCount: Int,
        isRequesterMember: Bool,
        requesterRole: GroupRole?,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.description = description
        self.avatarURL = avatarURL
        self.coverURL = coverURL
        self.visibility = visibility
        self.ownerID = ownerID
        self.ownerDisplayName = ownerDisplayName
        self.memberCount = memberCount
        self.isRequesterMember = isRequesterMember
        self.requesterRole = requesterRole
        self.createdAt = createdAt
    }
}

public struct GroupMemberDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let userID: UUID
    public let displayName: String
    public let photoURL: String?
    public let role: GroupRole
    public let joinedAt: Date

    public init(
        id: UUID,
        userID: UUID,
        displayName: String,
        photoURL: String?,
        role: GroupRole,
        joinedAt: Date
    ) {
        self.id = id
        self.userID = userID
        self.displayName = displayName
        self.photoURL = photoURL
        self.role = role
        self.joinedAt = joinedAt
    }
}

public struct CreateGroupRequest: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let visibility: GroupVisibility

    public init(name: String, description: String, visibility: GroupVisibility = .public) {
        self.name = name
        self.description = description
        self.visibility = visibility
    }
}
