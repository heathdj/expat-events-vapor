# ExpatEvents — Vapor MVP

A Vapor (Swift) rebuild of ExpatEvents: a server-rendered web app (Leaf +
htmx + Alpine + Tailwind), a versioned JSON API (`/api/v1`) for future
native clients, realtime chat, groups, subscription billing, and GDPR-grade
data handling.

This repo is being built against two planning documents, both checked into
[`docs/`](docs/):

- [`docs/expatevents-vapor-architecture.md`](docs/expatevents-vapor-architecture.md) — the full architecture & engineering plan (data model, stack choices, API surface).
- [`docs/expatevents-mvp-plan.md`](docs/expatevents-mvp-plan.md) — the milestone-by-milestone MVP scope and acceptance criteria this build follows.

**If you're picking this up to continue the build, read [`AGENTS.md`](AGENTS.md) first** — it's the brief for whoever (human or AI coding agent) works on this next, and [`MILESTONES.md`](MILESTONES.md) tracks what's actually done versus still open against the plan's 13 milestones.

## Repo layout

```
expatevents-mvp/
  docs/                        The two planning documents (source of truth for scope)
  Packages/
    ExpatEventsAPI/            Shared DTOs, enums, ChatEnvelope, route helpers (SPM package)
  Server/                      The Vapor app
    Sources/App/
      Models/                  Fluent models — every table in the architecture doc
      Migrations/              One migration per model, plus Postgres enum types
      Controllers/Web/         Leaf/htmx pages
      Controllers/API/         /api/v1 JSON endpoints
      Controllers/Admin/       (not yet built — M10)
      Middleware/              Admin gating, API error shaping, session/suspension checks
      Services/                Business logic shared by Web and API controllers
      WebSockets/              (not yet built — M5)
      Commands/                Dev seeding, the M9 process-deletions / retention-cleanup jobs, and M10 make-admin
    Resources/Views/           Leaf templates
    Public/                    Static assets (Tailwind/htmx/Alpine — currently CDN-loaded, see note below)
    docker-compose.yml         Local Postgres for development
    .env.example               Every environment variable the app reads
```

## Prerequisites

- **Swift 6.0+** (Xcode 16+ on macOS, or the Swift toolchain on Linux; the time-zone library `tzf-swift` needs a 6.0 toolchain). Check with `swift --version`.
- **Docker** (or a local Postgres 14+ instance) for the database.
- Optionally, the [Vapor toolbox](https://docs.vapor.codes/getting-started/toolbox/) (`brew install vapor`) — not required, `swift build`/`swift run` work fine without it.

> **Build status**: this project builds and its test suite passes for real. M1 (scaffolding & data model) and M4 (events) are compiler-verified, test-passing (`swift test`, run against real Postgres — see below), server-checkpointed by a human, independently code-reviewed, and merged; see [`MILESTONES.md`](MILESTONES.md) for the authoritative per-milestone status and [`WARNINGS.md`](WARNINGS.md) for the (small, tracked) set of open build warnings. If you're picking this up fresh, a clean `swift build` followed by `swift test` against a running Postgres (§ below) is still the right first move to confirm your environment matches — it should come back clean.

## Getting started (from a clean checkout)

1. Start Postgres:
   ```sh
   cd Server
   docker compose up -d
   ```
2. Copy the environment file and adjust if needed (the defaults match `docker-compose.yml`):
   ```sh
   cp .env.example .env
   ```
3. Build and run:
   ```sh
   swift build
   swift run App migrate --yes   # creates every table from Migrations/
   swift run App seed            # 5 users, 2 groups, 3 events — see Commands/SeedCommand.swift
   swift run App serve           # starts the server on http://localhost:8080
   ```
   City and venue suggestions on the create-event form come from Google in development: set `GOOGLE_MAPS_API_KEY` in `Server/.env` (a key with **Places API (New)** enabled; see `.env.example`). Without it the form falls back to a few built-in sample places (Lisbon, Madrid, Berlin, Mexico City, Bangkok). Time zones are worked out offline from coordinates with [`tzf-swift`](https://github.com/ringsaturn/tzf-swift).

   Two maintenance commands (M9), run by hand for now (scheduling them in production is M13's job):
   ```sh
   swift run App process-deletions   # erases accounts with a pending "Delete account" request
   swift run App retention-cleanup   # deletes past/cancelled events (and their chat) older than 30 days
   ```

   The admin site is at `/admin` (M10). Only admins can open it; the seed makes the `heathdj@gmail.com` account one. Anywhere else (including production), make the first admin from the command line once that account has signed in:
   ```sh
   swift run App make-admin someone@example.com            # grant admin access
   swift run App make-admin someone@example.com --revoke   # remove it (refused for the last admin)
   ```
4. Check it's alive:
   ```sh
   curl http://localhost:8080/health
   # {"status":"ok","database":"connected"}
   ```
5. Visit `http://localhost:8080/events` in a browser for the (currently unstyled-beyond-Tailwind-CDN) events dashboard, `http://localhost:8080/groups` for the group directory, or `http://localhost:8080/login` for sign-in — sign-in won't actually complete without real `APPLE_CLIENT_ID`/`GOOGLE_CLIENT_ID` values and matching Apple/Google app configuration (see the architecture doc §2 prerequisites and the MVP plan's own §2).

## Running tests

```sh
cd Server
docker compose up -d   # tests run against real Postgres, not an in-memory substitute
swift test
```

Tests use their own database, `expatevents_test` (set in `Server/.env.testing`), because each test migrates and then reverts every table. Before that file existed they shared the dev database, so every `swift test` run wiped your local data. A fresh Docker volume creates `expatevents_test` automatically (`Server/docker/initdb/`); on a volume that already existed, create it once:

```sh
docker compose exec db createdb -U vapor_username expatevents_test
```

The app refuses to run the tests against a database whose name doesn't end in `_test`.

## What's implemented vs. not

See [`MILESTONES.md`](MILESTONES.md) for the authoritative, milestone-by-milestone status. Short version: M1, M2 (on Google; Apple's live verification waits for M13's real domain), M4, M5, M6, M7 and M9 are done; M8 (billing) was skipped for now; M3 and M10–M13 aren't started. [`docs/design-audit.md`](docs/design-audit.md) lists how far each screen is from the design.

## Deliberately out of scope for this MVP

Per [`docs/expatevents-mvp-plan.md`](docs/expatevents-mvp-plan.md) §4 — do not build these without a deliberate, written reason:

- The native SwiftUI consumer app and admin Mac app.
- Invite-only groups' "request to join" workflow.
- Recurring-event auto-generation.
- Spanish translation content.
- A fully automated async job queue for data export/deletion.
- Multi-instance chat fan-out (Redis/Postgres `LISTEN`/`NOTIFY`).
