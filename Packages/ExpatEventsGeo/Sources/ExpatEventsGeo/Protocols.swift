import Foundation

/// Autocomplete plus place lookup. One adapter per provider.
///
/// `sessionToken` groups a run of autocomplete requests with the lookup that
/// ends it, which is how Google bills them (the autocomplete requests in a
/// session that ends in a lookup are free). Providers without sessions
/// ignore it.
public protocol PlaceSearchProvider: Sendable {
    /// Stable short name stored with each event ("google", "apple", "sample").
    var name: String { get }

    func suggestions(for query: String, kind: PlaceKind, sessionToken: String, near: GeoCoordinate?) async throws -> [PlaceSuggestion]

    /// `name` is the suggestion's title the user picked: providers whose
    /// cheapest lookup doesn't include a display name (Google) use it as is.
    func place(id: String, name: String, sessionToken: String) async throws -> ResolvedPlace
}

/// Coordinates -> IANA time zone identifier.
public protocol TimeZoneResolver: Sendable {
    func timeZoneIdentifier(for coordinate: GeoCoordinate) -> String?
}

/// Minimal HTTP so adapters don't depend on Vapor or URLSession. The server
/// implements it with its own HTTP client; tests with canned responses.
public struct GeoHTTPRequest: Sendable, Equatable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }

    public let method: Method
    public let url: String
    public let headers: [String: String]
    public let body: Data?

    public init(method: Method, url: String, headers: [String: String], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct GeoHTTPResponse: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol GeoHTTPTransport: Sendable {
    func send(_ request: GeoHTTPRequest) async throws -> GeoHTTPResponse
}
