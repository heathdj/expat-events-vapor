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
      Commands/                Dev database seeding
    Resources/Views/           Leaf templates
    Public/                    Static assets (Tailwind/htmx/Alpine — currently CDN-loaded, see note below)
    docker-compose.yml         Local Postgres for development
    .env.example               Every environment variable the app reads
```

## Prerequisites

- **Swift 5.9+** (Xcode 15+ on macOS, or the Swift toolchain on Linux). Check with `swift --version`.
- **Docker** (or a local Postgres 14+ instance) for the database.
- Optionally, the [Vapor toolbox](https://docs.vapor.codes/getting-started/toolbox/) (`brew install vapor`) — not required, `swift build`/`swift run` work fine without it.

> **A note on this scaffold's build status**: this project was scaffolded and written in an environment without a Swift toolchain available to compile against, so the code below has **not** been compiled or run yet. It's written carefully against real Vapor 4 / Fluent 4 APIs, but **the very first thing to do is `swift build` it and fix whatever the compiler finds** — treat that as step zero of continuing this build, not a sign something went wrong.

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
   swift run App seed            # 3 users, 1 group, 2 events — see Commands/SeedCommand.swift
   swift run App serve           # starts the server on http://localhost:8080
   ```
4. Check it's alive:
   ```sh
   curl http://localhost:8080/health
   # {"status":"ok","database":"connected"}
   ```
5. Visit `http://localhost:8080/events` in a browser for the (currently unstyled-beyond-Tailwind-CDN) events dashboard, or `http://localhost:8080/login` for sign-in — sign-in won't actually complete without real `APPLE_CLIENT_ID`/`GOOGLE_CLIENT_ID` values and matching Apple/Google app configuration (see the architecture doc §2 prerequisites and the MVP plan's own §2).

## Running tests

```sh
cd Server
docker compose up -d   # tests run against real Postgres, not an in-memory substitute
swift test
```

## What's implemented vs. not

See [`MILESTONES.md`](MILESTONES.md) for the authoritative, milestone-by-milestone status. Short version: **M1 (scaffolding & full data model)** and most of **M2 (Apple/Google sign-in)** and **M4 (events, including Free-tier plan limits)** are built. M3 and M5–M13 are not — they're scoped in the plan and architecture docs, ready for whoever continues.

## Deliberately out of scope for this MVP

Per [`docs/expatevents-mvp-plan.md`](docs/expatevents-mvp-plan.md) §4 — do not build these without a deliberate, written reason:

- The native SwiftUI consumer app and admin Mac app.
- Invite-only groups' "request to join" workflow.
- Recurring-event auto-generation.
- Spanish translation content.
- A fully automated async job queue for data export/deletion.
- Multi-instance chat fan-out (Redis/Postgres `LISTEN`/`NOTIFY`).
