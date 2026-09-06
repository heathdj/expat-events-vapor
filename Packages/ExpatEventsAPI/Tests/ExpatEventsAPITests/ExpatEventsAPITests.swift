import XCTest
@testable import ExpatEventsAPI

final class ExpatEventsAPITests: XCTestCase {
    func testDateRoundTrips() throws {
        let original = Date(timeIntervalSince1970: 1_757_000_000)
        let data = try ExpatEventsDateCoding.encoder.encode(["date": original])
        let decoded = try ExpatEventsDateCoding.decoder.decode([String: Date].self, from: data)
        // ISO-8601 with fractional seconds round-trips to millisecond precision.
        XCTAssertEqual(decoded["date"]!.timeIntervalSince1970, original.timeIntervalSince1970, accuracy: 0.001)
    }

    func testChatEnvelopeMessageRoundTrips() throws {
        let dto = ChatMessageDTO(
            id: UUID(),
            eventID: UUID(),
            userID: UUID(),
            displayName: "Bob",
            photoURL: nil,
            parentID: nil,
            text: "Hello!",
            createdAt: Date()
        )
        let envelope = ChatEnvelope.message(dto)
        let data = try ExpatEventsDateCoding.encoder.encode(envelope)
        let decoded = try ExpatEventsDateCoding.decoder.decode(ChatEnvelope.self, from: data)
        guard case .message(let decodedDTO) = decoded else {
            return XCTFail("Expected .message case")
        }
        XCTAssertEqual(decodedDTO.id, dto.id)
        XCTAssertEqual(decodedDTO.text, dto.text)
    }

    func testChatEnvelopePresenceRoundTrips() throws {
        let envelope = ChatEnvelope.presence(count: 3)
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(ChatEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
    }

    func testAPIRouteHelpersFormatCorrectly() {
        let id = UUID()
        XCTAssertEqual(APIRoute.event(id), "/api/v1/events/\(id)")
        XCTAssertEqual(APIRoute.eventJoin(id), "/api/v1/events/\(id)/join")
        XCTAssertEqual(APIRoute.group(slug: "brunch-club"), "/api/v1/groups/brunch-club")
    }

    func testEventCategoryRawValuesMatchLegacyApp() {
        // Regression guard: these must stay byte-identical to the legacy
        // React app's categoryOptions.js values so seeded/migrated data lines up.
        let expected: Set<String> = ["culture", "drinks", "film", "food", "music", "travel"]
        let actual = Set(EventCategory.allCases.map(\.rawValue))
        XCTAssertEqual(actual, expected)
    }
}
