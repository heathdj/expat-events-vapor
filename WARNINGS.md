# Build warnings tracker

Every warning `swift build` has produced against this codebase, so nothing gets silently carried to launch. Each entry has a status: **fixed**, **suppressed** (deliberately silenced, with a reason), or **open** (still needs a decision). Update this file whenever a build log shows a new warning or an existing one changes status — treat "zero open warnings" as a release gate for M13.

Corresponding GitHub issue: see the repo's Issues tab (label `warnings`) — file/update one per **open** row below so the tracking isn't only local to this doc.

## Current status (as of the M1 verify-and-fix build, `build.log`)

| # | Warning | Location | Status | Notes |
|---|---|---|---|---|
| 1 | `warning: extension declares a conformance of imported type 'X' to imported protocol 'Content'; this will not behave correctly if the owners of 'X' introduce a conformance of their own` (×15 — one per DTO) | `Server/Sources/App/Extensions/ContentConformance.swift` | **fixed** | Both `Content` (Vapor) and every DTO (`ExpatEventsAPI`) are external to this module, so Swift flags it as a "retroactive conformance." This is intentional — the shared package is deliberately Foundation-only and can't declare `Content` itself (see the file's own doc comment) — so each extension is annotated `@retroactive` to acknowledge it rather than suppress the underlying check. Low risk in practice: we own both sides of the build (no third-party package will ever add its own `Content` conformance to our DTOs), but keep this row if a future Swift version changes `@retroactive`'s semantics. |
| 2 | `warning: 'postgres(hostname:port:username:password:database:tlsConfiguration:)' is deprecated` (or similar — exact message not yet re-confirmed against the current driver version) | `Server/Sources/App/configure.swift:36`, the `app.databases.use(.postgres(hostname:...))` fallback branch used for local dev (no `DATABASE_URL`) | **open** | Needs a real compiler to identify the exact replacement signature in the pinned `fluent-postgres-driver` 2.8.0 (likely `.postgres(configuration: SQLPostgresConfiguration(...))` or an initializer taking `tls:` explicitly) before swapping it — I don't have a local Swift toolchain to verify the fix compiles, so it's tracked here rather than guessed at. Not launch-blocking on its own (it's a warning, not an error, and only hit in local/dev config), but should be resolved before M13 (deployment) since production only uses the `DATABASE_URL` branch anyway — worth confirming that branch has no equivalent deprecation once we get there. |

## Process

1. Every time a milestone branch produces a build log, grep it for `warning:` and reconcile against this table — add new rows, update statuses, don't just glance at the tail (a warning count can hide behind others; always check the total, e.g. `grep -c "warning:" build.log`, and confirm which lines it maps to before assuming it's "just the one you already know about" — that's exactly the mistake this table exists to catch).
2. Each **open** row gets (or keeps updated) a matching GitHub issue labeled `warnings`, so it's visible outside this repo's working tree too and can be assigned/triaged independently of any one milestone's PR.
3. Before M13 (deployment), every row must be **fixed** or **suppressed with a written reason** — no **open** rows at launch.
