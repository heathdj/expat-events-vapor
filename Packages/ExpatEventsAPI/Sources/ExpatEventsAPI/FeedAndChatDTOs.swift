import Foundation

public struct ActivityFeedItemDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let type: ActivityFeedItemType
    public let actorUserID: UUID
    public let actorDisplayName: String
    public let actorPhotoURL: String?
    public let eventID: UUID?
    public let eventTitle: String?
    public let createdAt: Date

    public init(
        id: UUID,
        type: ActivityFeedItemType,
        actorUserID: UUID,
        actorDisplayName: String,
        actorPhotoURL: String?,
        eventID: UUID?,
        eventTitle: String?,
        createdAt: Date
    ) {
        self.id = id
        self.type = type
        self.actorUserID = actorUserID
        self.actorDisplayName = actorDisplayName
        self.actorPhotoURL = actorPhotoURL
        self.eventID = eventID
        self.eventTitle = eventTitle
        self.createdAt = createdAt
    }
}

public struct ChatMessageDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let eventID: UUID
    public let userID: UUID
    public let displayName: String
    public let photoURL: String?
    public let parentID: UUID?
    public let text: String
    public let createdAt: Date

    public init(
        id: UUID,
        eventID: UUID,
        userID: UUID,
        displayName: String,
        photoURL: String?,
        parentID: UUID?,
        text: String,
        createdAt: Date
    ) {
        self.id = id
        self.eventID = eventID
        self.userID = userID
        self.displayName = displayName
        self.photoURL = photoURL
        self.parentID = parentID
        self.text = text
        self.createdAt = createdAt
    }
}

public struct SendChatMessageRequest: Codable, Sendable, Equatable {
    public let text: String
    public let parentID: UUID?

    public init(text: String, parentID: UUID? = nil) {
        self.text = text
        self.parentID = parentID
    }
}

/// The realtime wire format (architecture doc §5, §8). Because both the
/// Vapor broadcaster and any native client encode/decode this exact type,
/// a protocol change is a compile error in both places, not a runtime
/// mismatch discovered in production.
public enum ChatEnvelope: Codable, Sendable, Equatable {
    case message(ChatMessageDTO)
    case typing(UUID)
    case presence(count: Int)
    case error(APIError)

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private enum Kind: String, Codable {
        case message, typing, presence, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .message:
            self = .message(try container.decode(ChatMessageDTO.self, forKey: .payload))
        case .typing:
            self = .typing(try container.decode(UUID.self, forKey: .payload))
        case .presence:
            self = .presence(count: try container.decode(Int.self, forKey: .payload))
        case .error:
            self = .error(try container.decode(APIError.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let dto):
            try container.encode(Kind.message, forKey: .type)
            try container.encode(dto, forKey: .payload)
        case .typing(let userID):
            try container.encode(Kind.typing, forKey: .type)
            try container.encode(userID, forKey: .payload)
        case .presence(let count):
            try container.encode(Kind.presence, forKey: .type)
            try container.encode(count, forKey: .payload)
        case .error(let error):
            try container.encode(Kind.error, forKey: .type)
            try container.encode(error, forKey: .payload)
        }
    }
}
