import Fluent
import FluentPostgresDriver
import Leaf
import JWT
import Vapor

/// Wires up the app: Postgres (via environment variables, per M1's
/// acceptance criteria), Fluent migrations for every model in the
/// architecture doc, Leaf templating, session auth for the web app, and
/// JWT-based bearer auth for `/api/v1` (architecture §7).
public func configure(_ app: Application) async throws {
    try configureDatabase(app)
    try configureSessions(app)
    try configureJWT(app)
    app.chatRoomRegistry = ChatRoomRegistry()

    app.views.use(.leaf)
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    registerMigrations(app)
    registerCommands(app)

    try routes(app)
}

// MARK: - Database

/// Reads either a single `DATABASE_URL` (as DigitalOcean Managed Postgres
/// and most PaaS providers hand it out — include `?sslmode=require` in the
/// URL itself for DigitalOcean) or the individual `DATABASE_HOST` /
/// `DATABASE_PORT` / `DATABASE_USERNAME` / `DATABASE_PASSWORD` /
/// `DATABASE_NAME` variables used for local development (see `.env.example`).
private func configureDatabase(_ app: Application) throws {
    if let databaseURL = Environment.get("DATABASE_URL") {
        try app.databases.use(.postgres(url: databaseURL), as: .psql)
    } else {
        app.databases.use(.postgres(
            hostname: Environment.get("DATABASE_HOST") ?? "localhost",
            // 5433, not Postgres's usual 5432 — matches docker-compose.yml's
            // host port mapping (see its comment for why) and .env.example.
            // This fallback only bites when DATABASE_PORT is unset AND no
            // .env is present at all; keep it in sync with those two.
            port: Environment.get("DATABASE_PORT").flatMap(Int.init) ?? 5433,
            username: Environment.get("DATABASE_USERNAME") ?? "vapor_username",
            password: Environment.get("DATABASE_PASSWORD") ?? "vapor_password",
            database: Environment.get("DATABASE_NAME") ?? "expatevents"
        ), as: .psql)
    }
}

// MARK: - Sessions (web)

private func configureSessions(_ app: Application) throws {
    app.sessions.use(.fluent)
    app.middleware.use(app.sessions.middleware)
    app.migrations.add(SessionRecord.migration)
}

// MARK: - JWT (native API bearer tokens)

private func configureJWT(_ app: Application) throws {
    guard let secret = Environment.get("JWT_SECRET"), !secret.isEmpty else {
        if app.environment == .production {
            fatalError("JWT_SECRET must be set in production — see .env.example")
        }
        app.logger.warning("JWT_SECRET not set — using an insecure development-only default. Set it before deploying.")
        app.jwt.signers.use(.hs256(key: "development-only-insecure-secret"))
        return
    }
    app.jwt.signers.use(.hs256(key: secret))
}

// MARK: - Migrations

private func registerMigrations(_ app: Application) {
    // Enum types first — every model migration below reads one of these
    // back out via `database.enum("...").read()`.
    app.migrations.add(CreateUserRoleEnum())
    app.migrations.add(CreateIdentityProviderEnum())
    app.migrations.add(CreatePlanTierEnum())
    app.migrations.add(CreateBillingCycleEnum())
    app.migrations.add(CreateSubscriptionStatusEnum())
    app.migrations.add(CreateGroupVisibilityEnum())
    app.migrations.add(CreateGroupRoleEnum())
    app.migrations.add(CreateEventCategoryEnum())
    app.migrations.add(CreateEventVisibilityEnum())
    app.migrations.add(CreateActivityFeedItemTypeEnum())
    app.migrations.add(CreateInvoiceStatusEnum())
    app.migrations.add(CreateDataExportStatusEnum())

    // Tables, in dependency order.
    app.migrations.add(CreateUser())
    app.migrations.add(CreateOAuthIdentity())
    app.migrations.add(CreatePasskeyCredential())
    app.migrations.add(CreateSubscription())
    app.migrations.add(CreateInvoice())
    app.migrations.add(CreateGroup())
    app.migrations.add(CreateGroupMembership())
    app.migrations.add(CreateEvent())
    app.migrations.add(CreateEventAttendee())
    app.migrations.add(CreateChatMessage())
    app.migrations.add(CreateFollow())
    app.migrations.add(CreateActivityFeedItem())
    app.migrations.add(CreateFeedback())
    app.migrations.add(CreateDeletionRequest())
    app.migrations.add(CreateDataExportRequest())
    app.migrations.add(CreateAdminAuditLog())
}

// MARK: - Commands

private func registerCommands(_ app: Application) {
    app.commands.use(SeedCommand(), as: "seed")
}
