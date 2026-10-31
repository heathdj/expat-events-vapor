// swift-tools-version:5.9
import PackageDescription

/// Provider-neutral places and time-zone lookups (docs/mapping-decision-plan.md).
/// The server talks to `PlaceSearchProvider` and `TimeZoneResolver` only, so
/// switching from Google (development) to Apple (likely at launch) is one new
/// adapter plus configuration. No Vapor dependency: HTTP goes through the
/// small `GeoHTTPTransport` protocol, which the server implements with its own
/// client and tests implement with canned responses.
let package = Package(
    name: "ExpatEventsGeo",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "ExpatEventsGeo", targets: ["ExpatEventsGeo"])
    ],
    dependencies: [
        // Coordinates -> IANA time zone, offline (bundled boundary data).
        // MapKit JS has no time zone and Google's only comes from a separate
        // paid API, so this fills it in for every provider. The library is
        // MIT; its bundled boundary data is ODbL-1.0 (derived from
        // timezone-boundary-builder / OpenStreetMap), so the app credits it
        // (see pages/privacy.leaf). Requires a Swift 6.0+ toolchain (its
        // manifest is tools-version 6.0).
        .package(url: "https://github.com/ringsaturn/tzf-swift.git", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "ExpatEventsGeo",
            dependencies: [
                .product(name: "tzf", package: "tzf-swift")
            ]
        )
    ]
)
