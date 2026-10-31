import Foundation
import tzf

/// Time zones from coordinates, offline, via tzf-swift's bundled boundary
/// data (simplified polygons, accurate to within ~111 m of a border). The
/// data is ODbL-1.0 (timezone-boundary-builder / OpenStreetMap) and needs
/// crediting wherever the app is public; the library itself is MIT.
///
/// Deployment (M13): the data ships as the SwiftPM resource bundle
/// `tzf-swift_tzf.resources`, which the server image must include, and
/// `TimeZone(identifier:)` needs the system tz database (`tzdata`) on Linux.
///
/// Uses `EmbeddedFinder` (~10 MB resident, ~2 ms to load) rather than
/// `DefaultFinder` (~48 MB): a few lookups per created event don't need the
/// faster one. Both are `Sendable`, so one instance serves every request.
public struct TZFTimeZoneResolver: TimeZoneResolver {
    private let finder: EmbeddedFinder

    public init() throws {
        finder = try EmbeddedFinder()
    }

    public func timeZoneIdentifier(for coordinate: GeoCoordinate) -> String? {
        guard let identifier = try? finder.getTimezone(lng: coordinate.longitude, lat: coordinate.latitude),
              !identifier.isEmpty,
              TimeZone(identifier: identifier) != nil
        else {
            return nil
        }
        return identifier
    }

    /// Which boundary-data release is bundled (e.g. "2026c").
    public var dataVersion: String { finder.dataVersion() }
}
