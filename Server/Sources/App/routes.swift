import Fluent
import Vapor

func routes(_ app: Application) throws {
    try app.register(collection: HealthController())

    // Web (Leaf/htmx) — session-authenticated, per-route guards applied
    // inside each controller (architecture §6).
    try app.register(collection: AuthWebController())
    try app.register(collection: EventWebController())
    try app.register(collection: ChatWebController())

    // `/api/v1` — bearer-token authenticated, wrapped in APIErrorMiddleware
    // so every error response is the shared `{code, message}` shape
    // (architecture §7).
    let api = app.grouped(APIErrorMiddleware())
    try api.register(collection: AuthAPIController())
    try api.register(collection: EventAPIController())
}
