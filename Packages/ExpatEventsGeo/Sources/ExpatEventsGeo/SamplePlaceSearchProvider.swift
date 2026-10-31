import Foundation

/// A fixed list of real places, no network. Used by the test suite (always)
/// and in development when no provider key is configured, so the create
/// form still works. Time zones are deliberately left nil so the resolver
/// path is exercised the same way it is for Google and Apple.
public struct SamplePlaceSearchProvider: PlaceSearchProvider {
    public let name = "sample"

    public struct Entry: Sendable {
        public let kind: PlaceKind
        public let place: ResolvedPlace

        public init(kind: PlaceKind, place: ResolvedPlace) {
            self.kind = kind
            self.place = place
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry] = SamplePlaceSearchProvider.defaultEntries) {
        self.entries = entries
    }

    public func suggestions(for query: String, kind: PlaceKind, sessionToken: String, near: GeoCoordinate?) async throws -> [PlaceSuggestion] {
        let needle = Self.fold(query)
        return entries
            .filter { $0.kind == kind && (Self.fold($0.place.name).contains(needle) || Self.fold($0.place.formattedAddress).contains(needle)) }
            .map { PlaceSuggestion(placeID: $0.place.placeID, title: $0.place.name, subtitle: $0.place.formattedAddress) }
    }

    public func place(id: String, name: String, sessionToken: String) async throws -> ResolvedPlace {
        guard let entry = entries.first(where: { $0.place.placeID == id }) else {
            throw GeoError.notFound
        }
        return entry.place
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func entry(_ kind: PlaceKind, _ id: String, _ name: String, _ address: String, _ lat: Double, _ lng: Double) -> Entry {
        Entry(kind: kind, place: ResolvedPlace(
            placeID: id, provider: "sample", name: name, formattedAddress: address,
            coordinate: GeoCoordinate(latitude: lat, longitude: lng), timeZoneIdentifier: nil
        ))
    }

    /// The five expat cities from the mapping plan's test list, each with
    /// one well-known venue.
    public static let defaultEntries: [Entry] = [
        entry(.city, "sample-city-lisbon", "Lisbon", "Lisbon, Portugal", 38.7223, -9.1393),
        entry(.city, "sample-city-madrid", "Madrid", "Madrid, Spain", 40.4168, -3.7038),
        entry(.city, "sample-city-berlin", "Berlin", "Berlin, Germany", 52.5200, 13.4050),
        entry(.city, "sample-city-mexico-city", "Mexico City", "Mexico City, Mexico", 19.4326, -99.1332),
        entry(.city, "sample-city-bangkok", "Bangkok", "Bangkok, Thailand", 13.7563, 100.5018),
        entry(.venue, "sample-venue-brasileira", "Café A Brasileira", "Rua Garrett 120, Lisbon, Portugal", 38.7107, -9.1424),
        entry(.venue, "sample-venue-retiro", "Parque del Retiro", "Plaza de la Independencia 7, Madrid, Spain", 40.4153, -3.6844),
        entry(.venue, "sample-venue-tempelhof", "Tempelhofer Feld", "Tempelhofer Damm, Berlin, Germany", 52.4731, 13.4039),
        entry(.venue, "sample-venue-chapultepec", "Bosque de Chapultepec", "Miguel Hidalgo, Mexico City, Mexico", 19.4204, -99.1819),
        entry(.venue, "sample-venue-lumphini", "Lumphini Park", "Rama IV Road, Bangkok, Thailand", 13.7307, 100.5418),
    ]
}
