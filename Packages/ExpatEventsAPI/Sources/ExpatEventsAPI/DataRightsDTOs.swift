import Foundation

/// Backs the "download my data" right-to-portability feature (architecture
/// doc §13). The export itself is delivered as a signed, expiring link,
/// not inline in this DTO.
public struct DataExportRequestDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let status: DataExportStatus
    public let requestedAt: Date
    public let expiresAt: Date?

    public init(id: UUID, status: DataExportStatus, requestedAt: Date, expiresAt: Date?) {
        self.id = id
        self.status = status
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
    }
}

/// Passkey ceremony DTOs (architecture doc §5, §18). Deliberately minimal —
/// M3 (Passkeys) ships under its own escape hatch and may land after M2.
public struct PasskeyRegistrationOptions: Codable, Sendable, Equatable {
    public let challenge: String
    public let relyingPartyID: String
    public let userID: UUID
    public let userDisplayName: String

    public init(challenge: String, relyingPartyID: String, userID: UUID, userDisplayName: String) {
        self.challenge = challenge
        self.relyingPartyID = relyingPartyID
        self.userID = userID
        self.userDisplayName = userDisplayName
    }
}

public struct PasskeyAssertionOptions: Codable, Sendable, Equatable {
    public let challenge: String
    public let relyingPartyID: String

    public init(challenge: String, relyingPartyID: String) {
        self.challenge = challenge
        self.relyingPartyID = relyingPartyID
    }
}

/// The "Download my data" export itself (architecture doc §13, M9
/// acceptance criterion #2). The MVP ships the plan's "simpler
/// synchronous version" (MVP plan §1, GDPR row): the web app builds this
/// in the same request and downloads it as a `.json` file, rather than
/// the async signed-link flow `DataExportRequestDTO`'s own doc comment
/// describes -- that remains the long-term design.
///
/// Contains only the requester's own data. Anything that would expose
/// another person is deliberately left out: no attendee lists on the
/// requester's hosted events, no other members of their groups, no other
/// people's chat messages (a reply records only the parent message's ID,
/// never its text), and followed accounts are listed by ID only, never
/// by name.
public struct AccountDataExportDTO: Codable, Sendable, Equatable {
    public struct Profile: Codable, Sendable, Equatable {
        public let id: UUID
        public let displayName: String
        public let email: String
        public let photoURL: String?
        public let plan: PlanTier
        public let createdAt: Date?
        public let privacyPolicyVersion: String
        public let termsVersion: String
        public let consentedAt: Date

        public init(id: UUID, displayName: String, email: String, photoURL: String?, plan: PlanTier, createdAt: Date?, privacyPolicyVersion: String, termsVersion: String, consentedAt: Date) {
            self.id = id
            self.displayName = displayName
            self.email = email
            self.photoURL = photoURL
            self.plan = plan
            self.createdAt = createdAt
            self.privacyPolicyVersion = privacyPolicyVersion
            self.termsVersion = termsVersion
            self.consentedAt = consentedAt
        }
    }

    public struct HostedEvent: Codable, Sendable, Equatable {
        public let id: UUID
        public let title: String
        public let description: String
        public let date: Date
        public let cityAddress: String
        public let venueAddress: String
        public let visibility: EventVisibility
        public let isCancelled: Bool

        public init(id: UUID, title: String, description: String, date: Date, cityAddress: String, venueAddress: String, visibility: EventVisibility, isCancelled: Bool) {
            self.id = id
            self.title = title
            self.description = description
            self.date = date
            self.cityAddress = cityAddress
            self.venueAddress = venueAddress
            self.visibility = visibility
            self.isCancelled = isCancelled
        }
    }

    public struct Attendance: Codable, Sendable, Equatable {
        public let eventID: UUID
        public let joinedAt: Date?

        public init(eventID: UUID, joinedAt: Date?) {
            self.eventID = eventID
            self.joinedAt = joinedAt
        }
    }

    public struct GroupMembership: Codable, Sendable, Equatable {
        public let groupID: UUID
        public let groupName: String
        public let role: GroupRole
        public let joinedAt: Date?

        public init(groupID: UUID, groupName: String, role: GroupRole, joinedAt: Date?) {
            self.groupID = groupID
            self.groupName = groupName
            self.role = role
            self.joinedAt = joinedAt
        }
    }

    public struct ChatMessage: Codable, Sendable, Equatable {
        public let id: UUID
        public let eventID: UUID
        public let parentMessageID: UUID?
        public let text: String
        public let createdAt: Date?

        public init(id: UUID, eventID: UUID, parentMessageID: UUID?, text: String, createdAt: Date?) {
            self.id = id
            self.eventID = eventID
            self.parentMessageID = parentMessageID
            self.text = text
            self.createdAt = createdAt
        }
    }

    public struct FeedbackEntry: Codable, Sendable, Equatable {
        public let message: String
        public let name: String?
        public let email: String?
        public let createdAt: Date?

        public init(message: String, name: String?, email: String?, createdAt: Date?) {
            self.message = message
            self.name = name
            self.email = email
            self.createdAt = createdAt
        }
    }

    public let exportedAt: Date
    public let profile: Profile
    public let hostedEvents: [HostedEvent]
    public let attendedEvents: [Attendance]
    public let groupMemberships: [GroupMembership]
    public let chatMessages: [ChatMessage]
    public let followingUserIDs: [UUID]
    public let feedback: [FeedbackEntry]
    /// Which sign-in providers are linked (Apple/Google). Provider
    /// account IDs are left out: they're opaque and only useful to us.
    public let signInProviders: [IdentityProvider]

    public init(exportedAt: Date, profile: Profile, hostedEvents: [HostedEvent], attendedEvents: [Attendance], groupMemberships: [GroupMembership], chatMessages: [ChatMessage], followingUserIDs: [UUID], feedback: [FeedbackEntry], signInProviders: [IdentityProvider]) {
        self.exportedAt = exportedAt
        self.profile = profile
        self.hostedEvents = hostedEvents
        self.attendedEvents = attendedEvents
        self.groupMemberships = groupMemberships
        self.chatMessages = chatMessages
        self.followingUserIDs = followingUserIDs
        self.feedback = feedback
        self.signInProviders = signInProviders
    }
}
