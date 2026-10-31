import Fluent
import Vapor

func routes(_ app: Application) throws {
    try app.register(collection: HealthController())

    // Web (Leaf/htmx) — session-authenticated, per-route guards applied
    // inside each controller (architecture §6).
    try app.register(collection: AuthWebController())
    try app.register(collection: EventWebController())
    try app.register(collection: GroupWebController())
    try app.register(collection: ChatWebController())
    try app.register(collection: FeedWebController())
    try app.register(collection: ProfileWebController())
    try app.register(collection: HomeWebController())
    try app.register(collection: AccountWebController())
    try app.register(collection: LegalWebController())
    try app.register(collection: FeedbackWebController())
    try app.register(collection: PlacesWebController())
    // M10: the admin site, /admin (admins only).
    try app.register(collection: AdminWebController())

    // `/api/v1` — bearer-token authenticated, wrapped in APIErrorMiddleware
    // so every error response is the shared `{code, message}` shape
    // (architecture §7).
    let api = app.grouped(APIErrorMiddleware())
    try api.register(collection: AuthAPIController())
    try api.register(collection: EventAPIController())
    try api.register(collection: FeedAPIController())
}
