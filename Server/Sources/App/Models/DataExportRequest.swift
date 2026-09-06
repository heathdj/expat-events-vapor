import Fluent
import Vapor
import ExpatEventsAPI

/// Backs the "download my data" right-to-portability feature
/// (architecture §13, M9).
final class DataExportRequest: Model, Content, @unchecked Sendable {
    static let schema = "data_export_requests"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Timestamp(key: "requested_at", on: .create)
    var requestedAt: Date?

    @Enum(key: "status")
    var status: DataExportStatus

    @Field(key: "download_token")
    var downloadToken: String

    @OptionalField(key: "expires_at")
    var expiresAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: User.IDValue,
        status: DataExportStatus = .pending,
        downloadToken: String,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.$user.id = userID
        self.status = status
        self.downloadToken = downloadToken
        self.expiresAt = expiresAt
    }
}

extension DataExportRequest {
    func toDTO() throws -> DataExportRequestDTO {
        DataExportRequestDTO(
            id: try requireID(),
            status: status,
            requestedAt: requestedAt ?? Date(),
            expiresAt: expiresAt
        )
    }
}
