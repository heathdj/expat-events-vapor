import Vapor
import ExpatEventsGeo

extension Application {
    private struct LocationServiceKey: StorageKey {
        typealias Value = LocationService
    }

    /// Place search + time zones for the whole app, set up once by
    /// `configureLocation(_:)`. Tests can replace it directly.
    var location: LocationService {
        get {
            guard let existing = storage[LocationServiceKey.self] else {
                fatalError("LocationService not configured: call configureLocation(app) first.")
            }
            return existing
        }
        set { storage[LocationServiceKey.self] = newValue }
    }

    private struct PlaceSearchRateLimiterKey: StorageKey {
        typealias Value = PlaceSearchRateLimiter
    }

    /// Per-user limit on `/places/suggest` (see `PlaceSearchRateLimiter`).
    var placeSearchLimiter: PlaceSearchRateLimiter {
        get {
            guard let existing = storage[PlaceSearchRateLimiterKey.self] else {
                fatalError("PlaceSearchRateLimiter not configured: call configureLocation(app) first.")
            }
            return existing
        }
        set { storage[PlaceSearchRateLimiterKey.self] = newValue }
    }
}

/// Lets the geo package's adapters make HTTP calls through Vapor's own
/// client, so the package itself stays free of Vapor.
struct VaporGeoTransport: GeoHTTPTransport {
    let client: any Client

    func send(_ request: GeoHTTPRequest) async throws -> GeoHTTPResponse {
        var headers = HTTPHeaders()
        for (name, value) in request.headers {
            headers.replaceOrAdd(name: name, value: value)
        }
        let method: HTTPMethod = request.method == .post ? .POST : .GET
        let response = try await client.send(method, headers: headers, to: URI(string: request.url)) { clientRequest in
            clientRequest.timeout = .seconds(8)
            if let body = request.body {
                clientRequest.body = ByteBuffer(bytes: body)
            }
        }
        let data = response.body.map { Data($0.readableBytesView) } ?? Data()
        return GeoHTTPResponse(status: Int(response.status.code), body: data)
    }
}

/// Chooses the place-search provider:
///
/// - Tests always get the built-in sample places (no network, deterministic).
/// - `GEO_PROVIDER=sample` forces the sample places.
/// - Otherwise Google, when `GOOGLE_MAPS_API_KEY` is set (development, per
///   the mapping decision). An Apple adapter slots in here before launch.
/// - With no key, the sample places, with a warning, so the create form
///   still works on a fresh checkout.
///
/// Time zones always come from tzf-swift, whatever the provider.
func configureLocation(_ app: Application) {
    let timeZones: (any TimeZoneResolver)?
    do {
        timeZones = try TZFTimeZoneResolver()
    } catch {
        app.logger.error("Couldn't load time-zone boundary data: \(error). New events will have no time zone.")
        timeZones = nil
    }

    let requested = Environment.get("GEO_PROVIDER")?.lowercased()
    let googleKey = Environment.get("GOOGLE_MAPS_API_KEY").flatMap { $0.isEmpty ? nil : $0 }
    let provider: any PlaceSearchProvider
    if app.environment == .testing || requested == "sample" {
        provider = SamplePlaceSearchProvider()
    } else if let googleKey, requested == nil || requested == "google" {
        provider = GooglePlacesProvider(apiKey: googleKey, transport: VaporGeoTransport(client: app.client))
    } else {
        // In production this would quietly offer five sample cities to real
        // users, so refuse to start instead (found by the location review).
        if app.environment == .production {
            fatalError("No place-search provider configured for production: set GOOGLE_MAPS_API_KEY (or the launch provider's settings). See .env.example.")
        }
        app.logger.warning("No place-search provider configured (set GOOGLE_MAPS_API_KEY, see .env.example): using built-in sample places.")
        provider = SamplePlaceSearchProvider()
    }
    // Likewise, production must not silently create events with no time
    // zone: the usual causes are the tzf resource bundle missing from the
    // image or no tzdata on the host (M13).
    if timeZones == nil, app.environment == .production {
        fatalError("Time-zone boundary data failed to load in production. Check that the tzf-swift resource bundle and tzdata are in the image.")
    }
    app.location = LocationService(provider: provider, timeZones: timeZones)
    app.placeSearchLimiter = PlaceSearchRateLimiter()
}
