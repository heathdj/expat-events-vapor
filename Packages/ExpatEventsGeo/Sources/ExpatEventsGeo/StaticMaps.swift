import Foundation

/// A map picture of one point, fetched on the server (the event page's map;
/// user's decision in the Event detail PR: a server-fetched image, so the
/// provider key never reaches the browser and the page loads no map
/// scripts). The image keeps the provider's own logo and attribution.
public struct StaticMapImage: Sendable, Equatable {
    public let data: Data
    public let contentType: String

    public init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }
}

public protocol StaticMapProvider: Sendable {
    /// "google", "sample".
    var name: String { get }
    /// A map centred on `center` with a pin there, `width` x `height`
    /// points (served at twice that many pixels).
    func image(center: GeoCoordinate, width: Int, height: Int) async throws -> StaticMapImage
}

public struct StaticMapError: Error, Equatable {
    public let status: Int
}

/// Google Maps Static API. Google's terms forbid storing its map images,
/// so callers fetch one per view (browsers may keep it briefly).
public struct GoogleStaticMapProvider: StaticMapProvider {
    public let name = "google"

    private let apiKey: String
    private let transport: any GeoHTTPTransport
    private let baseURL: String

    public init(apiKey: String, transport: any GeoHTTPTransport, baseURL: String = "https://maps.googleapis.com/maps/api/staticmap") {
        self.apiKey = apiKey
        self.transport = transport
        self.baseURL = baseURL
    }

    public func image(center: GeoCoordinate, width: Int, height: Int) async throws -> StaticMapImage {
        let point = String(format: "%.6f,%.6f", center.latitude, center.longitude)
        // Google's free sizes stop at 640 points a side.
        let size = "\(min(max(width, 1), 640))x\(min(max(height, 1), 640))"
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#?/")
        let key = apiKey.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let url = "\(baseURL)?center=\(point)&zoom=15&size=\(size)&scale=2&format=png"
            + "&markers=color:0x218aae%7C\(point)&key=\(key)"
        let response = try await transport.send(GeoHTTPRequest(method: .get, url: url, headers: [:]))
        // A PNG, or it isn't a map (Google answers errors with text).
        guard response.status == 200, response.body.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            throw StaticMapError(status: response.status)
        }
        return StaticMapImage(data: response.body, contentType: "image/png")
    }
}

/// No network: a plain grey square, for tests and a checkout without a key.
public struct SampleStaticMapProvider: StaticMapProvider {
    public let name = "sample"

    /// A 1x1 light grey PNG.
    public static let placeholderPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGN48eYjAAWFAsaIxHAXAAAAAElFTkSuQmCC")!

    public init() {}

    public func image(center: GeoCoordinate, width: Int, height: Int) async throws -> StaticMapImage {
        StaticMapImage(data: Self.placeholderPNG, contentType: "image/png")
    }
}
