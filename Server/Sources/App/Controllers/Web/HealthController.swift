import Fluent
import Vapor

/// M1 acceptance criterion #4: a health-check route returns 200 confirming
/// DB connectivity — not just that the process is up.
struct HealthController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("health", use: check)
    }

    struct HealthResponse: Content {
        let status: String
        let database: String
    }

    @Sendable
    func check(req: Request) async throws -> HealthResponse {
        do {
            _ = try await User.query(on: req.db).count()
            return HealthResponse(status: "ok", database: "connected")
        } catch {
            req.logger.error("Health check DB query failed: \(error)")
            throw Abort(.serviceUnavailable, reason: "Database is not reachable.")
        }
    }
}
