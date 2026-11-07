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

    private struct StaticMapProviderKey: StorageKey {
        typealias Value = any StaticMapProvider
    }

    /// The event page's map pictures (`GET /events/:id/map.png`), chosen
    /// with the place-search provider by `configureLocation(_:)`.
    var staticMaps: any StaticMapProvider {
        get {
            guard let existing = storage[StaticMapProviderKey.self] else {
                fatalError("StaticMapProvider not configured: call configureLocation(app) first.")
            }
            return existing
        }
        set { storage[StaticMapProviderKey.self] = newValue }
    }

    private struct MapImageRateLimiterKey: StorageKey {
        typealias Value = KeyedRateLimiter
    }

    /// Per-member limit on map pictures, which are billed per request.
    var mapImageLimiter: KeyedRateLimiter {
        get {
            guard let existing = storage[MapImageRateLimiterKey.self] else {
                fatalError("Map image limiter not configured: call configureLocation(app) first.")
            }
            return existing
        }
        set { storage[MapImageRateLimiterKey.self] = newValue }
    }

    private struct MapImageSiteLimiterKey: StorageKey {
        typealias Value = KeyedRateLimiter
    }

    /// A cap on map pictures for the whole site, whoever asks.
    var mapImageSiteLimiter: KeyedRateLimiter {
        get {
            guard let existing = storage[MapImageSiteLimiterKey.self] else {
                fatalError("Map image limiter not configured: call configureLocation(app) first.")
            }
            return existing
        }
        set { storage[MapImageSiteLimiterKey.self] = newValue }
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
    let maps: any StaticMapProvider
    if app.environment == .testing || requested == "sample" {
        provider = SamplePlaceSearchProvider()
        maps = SampleStaticMapProvider()
    } else if let googleKey, requested == nil || requested == "google" {
        provider = GooglePlacesProvider(apiKey: googleKey, transport: VaporGeoTransport(client: app.client))
        // Needs "Maps Static API" enabled on the same key (.env.example).
        maps = GoogleStaticMapProvider(apiKey: googleKey, transport: VaporGeoTransport(client: app.client))
    } else {
        // In production this would quietly offer five sample cities to real
        // users, so refuse to start instead (found by the location review).
        if app.environment == .production {
            fatalError("No place-search provider configured for production: set GOOGLE_MAPS_API_KEY (or the launch provider's settings). See .env.example.")
        }
        app.logger.warning("No place-search provider configured (set GOOGLE_MAPS_API_KEY, see .env.example): using built-in sample places.")
        provider = SamplePlaceSearchProvider()
        maps = SampleStaticMapProvider()
    }
    // Likewise, production must not silently create events with no time
    // zone: the usual causes are the tzf resource bundle missing from the
    // image or no tzdata on the host (M13).
    if timeZones == nil, app.environment == .production {
        fatalError("Time-zone boundary data failed to load in production. Check that the tzf-swift resource bundle and tzdata are in the image.")
    }
    app.location = LocationService(provider: provider, timeZones: timeZones)
    app.placeSearchLimiter = PlaceSearchRateLimiter()
    app.staticMaps = maps
    app.mapImageLimiter = KeyedRateLimiter(limit: 30, window: 60)
    app.mapImageSiteLimiter = KeyedRateLimiter(limit: 600, window: 60)
}

/// At most `limit` events per key in any rolling `window` seconds; in
/// memory, per server instance (map pictures: per member, and for the
/// whole site), so one script can't run up the map bill.
actor KeyedRateLimiter {
    let limit: Int
    let window: TimeInterval
    private var recent: [String: [Date]] = [:]
    private var lastPruned = Date.distantPast

    init(limit: Int, window: TimeInterval) {
        self.limit = limit
        self.window = window
    }

    func allow(_ key: String, now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-window)
        // Drop keys that have gone quiet, at most once a window, so the
        // table can't grow forever.
        if lastPruned < cutoff {
            recent = recent.filter { $0.value.contains { $0 > cutoff } }
            lastPruned = now
        }
        var times = (recent[key] ?? []).filter { $0 > cutoff }
        guard times.count < limit else {
            recent[key] = times
            return false
        }
        times.append(now)
        recent[key] = times
        return true
    }
}
