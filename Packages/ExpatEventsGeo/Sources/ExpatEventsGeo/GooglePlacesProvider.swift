import Foundation

/// Google Places API (New), server-side.
///
/// - Autocomplete: `POST /v1/places:autocomplete`. Cities are restricted with
///   `includedPrimaryTypes: ["(cities)"]`; venues aren't restricted.
/// - Lookup: `GET /v1/places/{id}` with field mask `id,formattedAddress,location`,
///   all in the Place Details *Essentials* SKU. `displayName` would bump every
///   lookup to Pro, so the name comes from the suggestion instead.
/// - Both pass the same `sessionToken`, so the autocomplete requests in a
///   session that ends in a lookup aren't billed separately.
///
/// Terms to remember (docs/mapping-decision-plan.md): coordinates from Google
/// may only be kept 30 days, and Google place data must not be shown on a
/// non-Google map. Fine for development, which is what this adapter is for.
public struct GooglePlacesProvider: PlaceSearchProvider {
    public let name = "google"

    private let apiKey: String
    private let transport: any GeoHTTPTransport
    private let baseURL: String

    /// Radius of the venue search bias around the chosen city.
    static let venueBiasRadiusMeters = 30_000.0

    public init(apiKey: String, transport: any GeoHTTPTransport, baseURL: String = "https://places.googleapis.com/v1") {
        self.apiKey = apiKey
        self.transport = transport
        self.baseURL = baseURL
    }

    // MARK: - Autocomplete

    struct AutocompleteRequest: Encodable {
        struct LocationBias: Encodable {
            struct Circle: Encodable {
                struct Center: Encodable { let latitude: Double; let longitude: Double }
                let center: Center
                let radius: Double
            }
            let circle: Circle
        }
        let input: String
        let sessionToken: String
        let includedPrimaryTypes: [String]?
        let locationBias: LocationBias?
    }

    struct AutocompleteResponse: Decodable {
        struct Suggestion: Decodable {
            struct PlacePrediction: Decodable {
                struct Text: Decodable { let text: String }
                struct StructuredFormat: Decodable {
                    let mainText: Text
                    let secondaryText: Text?
                }
                let placeId: String
                let text: Text?
                let structuredFormat: StructuredFormat?
            }
            let placePrediction: PlacePrediction?
        }
        let suggestions: [Suggestion]?
    }

    public func suggestions(for query: String, kind: PlaceKind, sessionToken: String, near: GeoCoordinate?) async throws -> [PlaceSuggestion] {
        var bias: AutocompleteRequest.LocationBias?
        if kind == .venue, let near, near.isSet {
            bias = .init(circle: .init(center: .init(latitude: near.latitude, longitude: near.longitude), radius: Self.venueBiasRadiusMeters))
        }
        let body = try JSONEncoder().encode(AutocompleteRequest(
            input: query,
            sessionToken: sessionToken,
            includedPrimaryTypes: kind == .city ? ["(cities)"] : nil,
            locationBias: bias
        ))
        let response = try await send(GeoHTTPRequest(
            method: .post,
            url: "\(baseURL)/places:autocomplete",
            headers: ["Content-Type": "application/json", "X-Goog-Api-Key": apiKey],
            body: body
        ))
        let decoded: AutocompleteResponse
        do {
            decoded = try JSONDecoder().decode(AutocompleteResponse.self, from: response.body)
        } catch {
            throw GeoError.invalidResponse("autocomplete: \(error)")
        }
        return (decoded.suggestions ?? []).compactMap { suggestion in
            guard let prediction = suggestion.placePrediction else { return nil }
            let title = prediction.structuredFormat?.mainText.text ?? prediction.text?.text ?? ""
            guard !title.isEmpty else { return nil }
            return PlaceSuggestion(
                placeID: prediction.placeId,
                title: title,
                subtitle: prediction.structuredFormat?.secondaryText?.text ?? ""
            )
        }
    }

    // MARK: - Place lookup

    static let detailsFieldMask = "id,formattedAddress,location"

    struct DetailsResponse: Decodable {
        struct Location: Decodable { let latitude: Double; let longitude: Double }
        let id: String?
        let formattedAddress: String?
        let location: Location?
    }

    public func place(id: String, name: String, sessionToken: String) async throws -> ResolvedPlace {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? id
        // Query-safe characters only ("-" stays as-is, since tokens are
        // UUIDs); "+&=#?/" are escaped so they can't change the query.
        var queryAllowed = CharacterSet.urlQueryAllowed
        queryAllowed.remove(charactersIn: "+&=#?/")
        let encodedToken = sessionToken.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? sessionToken
        let response = try await send(GeoHTTPRequest(
            method: .get,
            url: "\(baseURL)/places/\(encodedID)?sessionToken=\(encodedToken)",
            headers: ["X-Goog-Api-Key": apiKey, "X-Goog-FieldMask": Self.detailsFieldMask]
        ))
        let decoded: DetailsResponse
        do {
            decoded = try JSONDecoder().decode(DetailsResponse.self, from: response.body)
        } catch {
            throw GeoError.invalidResponse("place details: \(error)")
        }
        guard let location = decoded.location else {
            throw GeoError.invalidResponse("place details had no location")
        }
        return ResolvedPlace(
            placeID: decoded.id ?? id,
            provider: self.name,
            name: name,
            formattedAddress: decoded.formattedAddress ?? name,
            coordinate: GeoCoordinate(latitude: location.latitude, longitude: location.longitude),
            timeZoneIdentifier: nil
        )
    }

    // MARK: - HTTP

    struct ErrorResponse: Decodable {
        struct Detail: Decodable { let message: String? }
        let error: Detail?
    }

    private func send(_ request: GeoHTTPRequest) async throws -> GeoHTTPResponse {
        let response = try await transport.send(request)
        guard (200..<300).contains(response.status) else {
            if response.status == 404 { throw GeoError.notFound }
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: response.body))?.error?.message ?? "no details"
            throw GeoError.provider(status: response.status, message: message)
        }
        return response
    }
}
