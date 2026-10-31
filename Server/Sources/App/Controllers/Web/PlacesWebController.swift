import Vapor
import ExpatEventsGeo

/// The create-event form's city and venue autocomplete, over htmx.
///
/// Every provider call happens here on the server, never in the browser:
/// the provider's key stays server-side, and switching provider (Google in
/// development, likely Apple at launch) changes nothing in the templates.
///
/// - `GET /places/suggest?kind=city&cityAddress=lis&session=…` renders the
///   suggestion list under the field (`partials/place-suggestions.leaf`).
///   Venue searches also send the chosen city's coordinates, which bias
///   results toward it.
/// - `GET /places/select?kind=city&id=…&name=…&session=…` looks the chosen
///   place up and re-renders the whole field with its coordinates filled in
///   (`partials/city-field.leaf` / `partials/venue-field.leaf`).
///
/// Signed-in only, since every call costs money with a real provider, and
/// rate-limited per user (`PlaceSearchRateLimiter`). Picking a place (a
/// billed lookup) isn't rate-limited separately: it ends the session that
/// the limited searches started.
struct PlacesWebController: RouteCollection {
    struct SuggestionRow: Encodable {
        let title: String
        let subtitle: String
        let hasSubtitle: Bool
        /// Precomputed `/places/select?...` URL for this suggestion.
        let selectURL: String
    }

    struct SuggestionsContext: Encodable {
        let suggestions: [SuggestionRow]
        let hasSuggestions: Bool
        /// The field to replace when a suggestion is picked ("#city-field").
        let fieldTarget: String
        /// Shown when the search returned nothing for a real query.
        let showNoResults: Bool
        let errorMessage: String?
        /// Google's policies require crediting Google when its suggestions
        /// aren't shown on a Google map. Precomputed from the provider name
        /// (no Leaf equality checks).
        let showGoogleAttribution: Bool
    }

    /// Longest query sent to the provider; anything longer is cut, since
    /// nobody types 100 characters to find a place and each call costs.
    static let maxQueryLength = 100

    func boot(routes: RoutesBuilder) throws {
        let authenticated = routes.grouped(User.activeSessionAuthenticator(), User.guardMiddleware(), NotSuspendedMiddleware())
        authenticated.get("places", "suggest", use: suggest)
        authenticated.get("places", "select", use: select)
    }

    @Sendable
    func suggest(req: Request) async throws -> View {
        let kind = Self.kind(req)
        let rawQuery = (try? req.query.get(String.self, at: kind == .city ? "cityAddress" : "venueAddress")) ?? ""
        let query = String(rawQuery.prefix(Self.maxQueryLength))
        let session = Self.session(req)
        let near = kind == .venue
            ? GeoCoordinate.validated(latitude: try? req.query.get(String.self, at: "cityLat"), longitude: try? req.query.get(String.self, at: "cityLng"))
            : nil

        let userID = try req.auth.require(User.self).requireID()
        let isRealQuery = query.trimmingCharacters(in: .whitespaces).count >= LocationService.minimumQueryLength
        var suggestions: [PlaceSuggestion] = []
        var errorMessage: String?
        let allowed = isRealQuery ? await req.application.placeSearchLimiter.allow(userID) : true
        if !allowed {
            errorMessage = "Too many searches in a short time. Wait a moment, then keep typing."
        } else {
            do {
                suggestions = try await req.application.location.suggestions(for: query, kind: kind, sessionToken: session, near: near)
            } catch {
                req.logger.warning("Place suggestions failed: \(error)")
                errorMessage = "Place search isn't available right now. Try again in a moment."
            }
        }

        let rows = suggestions.prefix(6).map { suggestion in
            SuggestionRow(
                title: suggestion.title,
                subtitle: suggestion.subtitle,
                hasSubtitle: !suggestion.subtitle.isEmpty,
                selectURL: Self.url("/places/select", [
                    ("kind", kind.rawValue), ("id", suggestion.placeID), ("name", suggestion.title), ("session", session),
                ])
            )
        }
        return try await req.view.render("partials/place-suggestions", SuggestionsContext(
            suggestions: Array(rows),
            hasSuggestions: !rows.isEmpty,
            fieldTarget: "#\(kind.rawValue)-field",
            showNoResults: rows.isEmpty && errorMessage == nil && query.trimmingCharacters(in: .whitespaces).count >= LocationService.minimumQueryLength,
            errorMessage: errorMessage,
            showGoogleAttribution: !rows.isEmpty && req.application.location.provider.name == "google"
        ))
    }

    @Sendable
    func select(req: Request) async throws -> View {
        let kind = Self.kind(req)
        guard let id = try? req.query.get(String.self, at: "id"), !id.isEmpty else {
            throw Abort(.badRequest, reason: "Missing place ID.")
        }
        let name = String(((try? req.query.get(String.self, at: "name")) ?? "").prefix(Self.maxQueryLength))
        var field: PlaceFieldContext
        var errorMessage: String?
        do {
            let place = try await req.application.location.resolve(placeID: String(id.prefix(512)), name: name, sessionToken: Self.session(req))
            // A fresh session for any further typing: the lookup just ended this one.
            field = PlaceFieldContext.selected(place, kind: kind, newSession: UUID().uuidString)
        } catch {
            // A failed lookup still re-renders the field (htmx doesn't swap
            // a 500), with the typed name kept and a message, so the click
            // isn't silently lost.
            req.logger.warning("Place lookup failed: \(error)")
            field = PlaceFieldContext(address: name, latitude: "", longitude: "", placeID: "", session: UUID().uuidString)
            errorMessage = "That place couldn't be looked up. Try picking it again, or another suggestion."
        }
        switch kind {
        case .city:
            return try await req.view.render("partials/city-field", field.cityContext(error: errorMessage))
        case .venue:
            return try await req.view.render("partials/venue-field", field.venueContext(error: errorMessage))
        }
    }

    private static func kind(_ req: Request) -> PlaceKind {
        (try? req.query.get(String.self, at: "kind")).flatMap(PlaceKind.init(rawValue:)) ?? .city
    }

    private static func session(_ req: Request) -> String {
        let value = (try? req.query.get(String.self, at: "session")) ?? ""
        return value.isEmpty ? UUID().uuidString : value
    }

    static func url(_ path: String, _ items: [(String, String)]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#?/")
        let pairs: [String] = items.map { (name: String, value: String) -> String in
            name + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }
        let query: String = pairs.joined(separator: "&")
        return path + "?" + query
    }
}

/// What one city or venue field shows: the visible text plus the hidden
/// coordinates and place ID. Shared by the create form (blank, or re-filled
/// after a rejection) and `PlacesWebController.select`.
struct PlaceFieldContext {
    var address: String
    var latitude: String
    var longitude: String
    var placeID: String
    var session: String

    var isSelected: Bool { !placeID.isEmpty && !latitude.isEmpty && !longitude.isEmpty }

    static func blank() -> PlaceFieldContext {
        PlaceFieldContext(address: "", latitude: "", longitude: "", placeID: "", session: UUID().uuidString)
    }

    static func selected(_ place: ResolvedPlace, kind: PlaceKind, newSession: String) -> PlaceFieldContext {
        PlaceFieldContext(
            address: place.label(for: kind),
            latitude: String(place.coordinate.latitude),
            longitude: String(place.coordinate.longitude),
            placeID: place.placeID,
            session: newSession
        )
    }

    /// The flat, kind-prefixed keys the two field partials read, so both
    /// can be `#extend`ed into one form without colliding. The create
    /// form's own context repeats these same keys (`EventFormContext`).
    struct CityLeaf: Encodable {
        let cityAddress: String
        let cityLat: String
        let cityLng: String
        let cityPlaceID: String
        let citySession: String
        let citySelected: Bool
        let cityError: String?
    }

    struct VenueLeaf: Encodable {
        let venueAddress: String
        let venueLat: String
        let venueLng: String
        let venuePlaceID: String
        let venueSession: String
        let venueSelected: Bool
        let venueError: String?
    }

    func cityContext(error: String?) -> CityLeaf {
        CityLeaf(cityAddress: address, cityLat: latitude, cityLng: longitude, cityPlaceID: placeID, citySession: session, citySelected: isSelected, cityError: error)
    }

    func venueContext(error: String?) -> VenueLeaf {
        VenueLeaf(venueAddress: address, venueLat: latitude, venueLng: longitude, venuePlaceID: placeID, venueSession: session, venueSelected: isSelected, venueError: error)
    }
}

/// A simple per-user limit on place searches: at most `limit` searches in
/// any rolling `window`. In memory, so per server instance; that's enough to
/// stop one signed-in user running up the provider bill from a script. Set a
/// daily quota on the provider key too (see `.env.example`).
actor PlaceSearchRateLimiter {
    let limit: Int
    let window: TimeInterval
    private var recent: [UUID: [Date]] = [:]

    init(limit: Int = 60, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    func allow(_ userID: UUID, now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-window)
        var times = (recent[userID] ?? []).filter { $0 > cutoff }
        guard times.count < limit else {
            recent[userID] = times
            return false
        }
        times.append(now)
        recent[userID] = times
        return true
    }
}
