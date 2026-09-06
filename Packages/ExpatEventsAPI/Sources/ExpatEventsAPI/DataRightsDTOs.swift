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
