# Brief for the coding agent

This file is the standing brief for whoever — human or AI coding agent —
picks up work on this repo next. Read this, then [`MILESTONES.md`](MILESTONES.md)
for exactly what's done, before touching code.

## Source of truth

Two documents in [`docs/`](docs/) are the actual spec. This file and
`MILESTONES.md` are secondary — if anything here ever conflicts with the
docs, the docs win:

1. **`docs/expatevents-vapor-architecture.md`** — the full engineering plan: data model, tech stack, API surface, permissions matrix, everything.
2. **`docs/expatevents-mvp-plan.md`** — the actionable subset: 13 milestones, each with a deliverables list and numbered acceptance criteria. **Build in milestone order; don't skip ahead.** Don't build anything listed under its §4 "Deferred to Phase 2" without a deliberate, written reason.

## Step zero: this code has never been compiled

It was written in an environment with no Swift toolchain and no network
access to install one, so nothing here has run through `swift build` yet.
It's written carefully against real Vapor 4 / Fluent 4 / JWTKit APIs based
on their documented behavior, but library APIs shift across versions and
mistakes are possible without a compiler checking as you go. **Before
building anything new: `swift build`, fix every error, get `swift test`
green against a real Postgres (`docker compose up -d` in `Server/`), then
proceed.** Treat compiler errors you find as normal first-pass cleanup, not
as a sign the approach is wrong — the priority is getting the existing
milestones' acceptance criteria demonstrably passing before adding more.

Specific spots worth a second look once you have a compiler:
- `configure.swift`'s Postgres setup (`.postgres(url:)` / individual-field convenience initializer) — confirm the exact fluent-postgres-driver 2.x signature.
- `AppleIdentityTokenVerifier` / `GoogleIdentityTokenVerifier` — JWTKit's `JWTSigners`/`JWKS` API surface.
- `AdminAuditLog.metadata`'s `.dictionary(of: .string)` Fluent field type, and the raw-SQL `CHECK` constraints added via `FluentSQL` in `CreateEvent`/`CreateFollow`.
- `Tests/AppTests/AppTests.swift`'s exact `XCTVapor` calling convention (`app.testing().test(...)` vs. `app.test(...)`) — this drifts across Vapor releases.

## Conventions already established — follow them

- **One service per feature area, shared by Web and API controllers**
  (`Services/EventService.swift`, `Services/AuthService.swift`,
  `Services/PlanLimitsService.swift`). A controller decodes the request,
  calls the service, converts the result to a DTO. Business logic and
  authorization checks live in the service, not the controller — that's
  what lets `EventWebController` and `EventAPIController` enforce
  identical rules, which the plan's own QA guidance (§5) explicitly tests
  for.
- **Errors are `ExpatEventsAPI.APIError`** (`{code, message}`), thrown from
  services. `Middleware/APIErrorMiddleware.swift` catches them at the
  `/api/v1` boundary and encodes the right HTTP status — add new error
  codes to `APIError` (the shared package) and to that middleware's
  `httpStatus` mapping together. Never let a plan-limit or auth failure
  surface as a bare 500 (M2 criterion #6 says this explicitly, and it's
  good practice generally).
- **Enums are shared verbatim** from `Packages/ExpatEventsAPI` and stored
  as native Postgres enum types (see `Migrations/CreateEnums.swift`) — add
  a case there and to the Swift enum together, never just one.
- **DTO conversion happens at the boundary** (`toDTO()` methods on models,
  or a service method like `EventService.fullDTO(for:requesterID:)`) —
  Fluent models never cross the wire directly.
- **Seed data is idempotent by design** (`Commands/SeedCommand.swift`
  looks up by a fixed email/slug before creating) — keep that pattern for
  any new seed data.
- **`docs/` copies are frozen** — if the plan changes, update the source
  files this repo was checked out from and re-copy them here; don't diverge.

## What's next

`MILESTONES.md` has the full picture, but in priority order:

1. Get M1 compiling and its acceptance criteria demonstrably passing (step zero, above).
2. Finish M2: the escape-hatch note in the plan means M3 (Passkeys) can slip, but M2 (Apple + Google) needs to fully hold on its own — double-check account-linking (§5 known-risk #7) and the `/api/v1/auth/*` error paths against real sandbox Apple/Google credentials once available.
3. Finish M4's htmx fragment responses (currently full-page redirects — see the note atop `EventWebController.swift`) and the Tailwind CLI build (currently CDN-loaded — see `layouts/base.leaf`).
4. M5 (realtime chat) is the next unbuilt milestone and several later milestones assume it exists (group events' chat-socket visibility check in M6, for instance).

## Prerequisites you'll need before certain milestones can complete

Per the MVP plan's §2 — these are real external accounts/secrets this
build environment did not have:

- A DigitalOcean account, Managed Postgres, and Spaces bucket (M13).
- A Stripe test-mode account with the $10/mo and $100/yr prices created (M8).
- An Apple Developer account with a Services ID for Sign in with Apple (M2/M3).
- A Google Cloud OAuth client ID (M2).
- DNS access for `expatevents.net` (M13).

None of M1/M2/M4's code depends on these being present to *compile* — the
Apple/Google client IDs are read from environment variables and their
absence is handled gracefully (the login page says so; the API returns a
structured 500 asking for configuration, not a crash) — but you can't
complete an actual sign-in without them.
