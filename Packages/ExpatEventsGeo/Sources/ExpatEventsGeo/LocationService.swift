import Foundation

/// What the server actually uses: a provider for search, plus a time-zone
/// resolver that fills in any time zone the provider didn't return.
public struct LocationService: Sendable {
    public let provider: any PlaceSearchProvider
    public let timeZones: (any TimeZoneResolver)?

    /// Queries shorter than this aren't sent to the provider (each one costs).
    public static let minimumQueryLength = 2

    public init(provider: any PlaceSearchProvider, timeZones: (any TimeZoneResolver)?) {
        self.provider = provider
        self.timeZones = timeZones
    }

    public func suggestions(for query: String, kind: PlaceKind, sessionToken: String, near: GeoCoordinate? = nil) async throws -> [PlaceSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumQueryLength else { return [] }
        return try await provider.suggestions(for: trimmed, kind: kind, sessionToken: sessionToken, near: near)
    }

    public func resolve(placeID: String, name: String, sessionToken: String) async throws -> ResolvedPlace {
        let place = try await provider.place(id: placeID, name: name, sessionToken: sessionToken)
        if place.timeZoneIdentifier != nil { return place }
        return place.withTimeZone(timeZoneIdentifier(for: place.coordinate))
    }

    public func timeZoneIdentifier(for coordinate: GeoCoordinate) -> String? {
        guard coordinate.isSet else { return nil }
        return timeZones?.timeZoneIdentifier(for: coordinate)
    }
}
