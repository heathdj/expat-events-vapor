import Foundation

/// A single, shared date-coding strategy so the server and every client
/// encode/decode dates identically (architecture doc §5).
public enum ExpatEventsDateCoding {
    /// ISO-8601 with fractional seconds, e.g. `2026-09-06T03:12:00.000Z`.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601WithFractionalSeconds
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return decoder
    }()
}

extension JSONEncoder.DateEncodingStrategy {
    public static var iso8601WithFractionalSeconds: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter.expatEvents.string(from: date))
        }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    public static var iso8601WithFractionalSeconds: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = ISO8601DateFormatter.expatEvents.date(from: string) {
                return date
            }
            if let date = ISO8601DateFormatter.expatEventsNoFractional.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO-8601 date string, got \(string)"
            )
        }
    }
}

extension ISO8601DateFormatter {
    static let expatEvents: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let expatEventsNoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
