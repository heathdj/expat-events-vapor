import Foundation

public struct GeoCoordinate: Codable, Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// The events table stores coordinates as non-optional doubles, with 0,0
    /// meaning "not set" (every event created before location lookup existed
    /// has exactly that). Nothing ExpatEvents cares about is in the Gulf of
    /// Guinea, so treating 0,0 as missing is safe.
    public var isSet: Bool {
        !(latitude == 0 && longitude == 0)
    }

    /// A coordinate from text (form fields, query strings), or nil if
    /// either part is empty, unreadable, not finite, out of range, or the
    /// 0,0 "not set" value.
    public static func validated(latitude: String?, longitude: String?) -> GeoCoordinate? {
        guard let lat = latitude.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
              let lng = longitude.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
              lat.isFinite, lng.isFinite,
              (-90...90).contains(lat), (-180...180).contains(lng)
        else {
            return nil
        }
        let coordinate = GeoCoordinate(latitude: lat, longitude: lng)
        return coordinate.isSet ? coordinate : nil
    }

    /// Great-circle distance (haversine), in kilometres.
    public func distanceKilometers(to other: GeoCoordinate) -> Double {
        let radius = 6371.0
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLng = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * .pi / 180) * cos(other.latitude * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * radius * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// What the create-event form is looking up.
public enum PlaceKind: String, Codable, Sendable, CaseIterable {
    /// A city or town.
    case city
    /// A specific place: a café, a bar, a park, an address.
    case venue
}

/// One autocomplete suggestion, before the user picks it.
public struct PlaceSuggestion: Codable, Sendable, Equatable {
    /// The provider's own place ID, passed back to `place(id:...)`.
    public let placeID: String
    /// The main line ("Café A Brasileira").
    public let title: String
    /// The second line ("Rua Garrett 120, Lisbon, Portugal"), may be empty.
    public let subtitle: String

    public init(placeID: String, title: String, subtitle: String) {
        self.placeID = placeID
        self.title = title
        self.subtitle = subtitle
    }
}

/// A place the user picked, with everything the event stores.
public struct ResolvedPlace: Codable, Sendable, Equatable {
    public let placeID: String
    /// Which provider the place ID belongs to ("google", "apple", "sample").
    public let provider: String
    public let name: String
    public let formattedAddress: String
    public let coordinate: GeoCoordinate
    /// IANA identifier ("Europe/Lisbon"). Providers that don't return one
    /// leave it nil and `LocationService` fills it in from the coordinates.
    public let timeZoneIdentifier: String?

    public init(placeID: String, provider: String, name: String, formattedAddress: String, coordinate: GeoCoordinate, timeZoneIdentifier: String?) {
        self.placeID = placeID
        self.provider = provider
        self.name = name
        self.formattedAddress = formattedAddress
        self.coordinate = coordinate
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    /// The text to show and store for this place. A city's formatted
    /// address already leads with its name ("Lisbon, Portugal"), but a
    /// venue's is only the street address, so the venue's name is put in
    /// front ("Franklin Bridge Golf Course, 123 Main St, ..."), unless the
    /// address already contains it (a street address picked as the venue).
    public func label(for kind: PlaceKind) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = formattedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAddress.isEmpty { return trimmedName }
        if trimmedName.isEmpty { return trimmedAddress }
        switch kind {
        case .city:
            return trimmedAddress
        case .venue:
            if trimmedAddress.range(of: trimmedName, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return trimmedAddress
            }
            return "\(trimmedName), \(trimmedAddress)"
        }
    }

    func withTimeZone(_ identifier: String?) -> ResolvedPlace {
        ResolvedPlace(placeID: placeID, provider: provider, name: name, formattedAddress: formattedAddress, coordinate: coordinate, timeZoneIdentifier: identifier)
    }
}

public enum GeoError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The provider answered with an error status.
    case provider(status: Int, message: String)
    /// The provider's response couldn't be read.
    case invalidResponse(String)
    /// No place with that ID.
    case notFound

    public var description: String {
        switch self {
        case .provider(let status, let message): return "Place lookup failed (\(status)): \(message)"
        case .invalidResponse(let detail): return "Unexpected place lookup response: \(detail)"
        case .notFound: return "That place couldn't be found."
        }
    }
}
