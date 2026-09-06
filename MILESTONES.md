# Milestone status

Tracking against [`docs/expatevents-mvp-plan.md`](docs/expatevents-mvp-plan.md)'s 13 milestones. Update this file whenever a milestone's status changes — it's the fastest way for anyone (or any agent) picking this up to see what's real.

Legend: ✅ built (not yet compiler-verified — see AGENTS.md "step zero") · 🟡 partial · ⬜ not started

## M1 — Project scaffolding & data model — ✅ built

- Monorepo layout: `Packages/ExpatEventsAPI`, `Server/`. ✅
- Vapor project with Postgres via environment variables (`configure.swift`). ✅
- Fluent migrations for every model in the architecture doc — all 16: `User`, `OAuthIdentity`, `PasskeyCredential`, `Subscription`, `Invoice`, `Group`, `GroupMembership`, `Event`, `EventAttendee`, `ChatMessage`, `Follow`, `ActivityFeedItem`, `Feedback`, `DeletionRequest`, `DataExportRequest`, `AdminAuditLog` — plus native Postgres enum types for every shared enum. ✅
- Local dev seed script, idempotent (`Commands/SeedCommand.swift`). ✅
- README. ✅
- **Not yet done**: actually running `vapor build` / `swift build` and confirming a clean checkout produces a running server (criterion #5) — see AGENTS.md "step zero." This is the single most important next action.

## M2 — Auth: Apple + Google — 🟡 partial

- `/login` offers Apple/Google only, no password field. ✅ (`pages/login.leaf`)
- New sign-in creates one `User` + one `OAuthIdentity`; a second provider on the same verified email links to the same `User` (`AuthService.findOrCreateUser`). ✅
- Session cookie (web) via `User.sessionAuthenticator()` / Fluent sessions. ✅
- Bearer token (API) via `UserJWTPayload` + `UserBearerAuthenticator`; `POST /api/v1/auth/apple`/`/google` → `GET /api/v1/me`. ✅
- Invalid/expired provider token → structured 401 via `APIErrorMiddleware`, never a 500. ✅ (untested against real tokens)
- Sign-out invalidates the web session (`/logout`). ✅
- **Not yet done**: end-to-end verification against real Apple/Google sandbox credentials (needs the prerequisites in AGENTS.md); the Sign in with Apple JS / Google Identity Services front-end wiring in `login.leaf` is written but unexercised.

## M3 — Passkeys — ⬜ not started (stretch milestone; escape hatch applies)

`PasskeyCredential` exists in the M1 data model so the schema won't shift later, but no WebAuthn ceremony, `/account/passkeys` UI, or `swift-server/swift-webauthn` integration yet. Per the plan's own escape hatch, this can ship as a documented fast-follow provided M2 fully covers sign-in on its own.

## M4 — Events — 🟡 partial

- Create (self-hosted and group-hosted), browse/filter, join/leave, cancel: `EventService` + `EventWebController` + `EventAPIController`. ✅
- Free-tier plan limits (5 active events, 5 attendees/event, no private events) via `PlanLimitsService`, enforced server-side on both web and API paths. ✅
- Non-host cannot edit/cancel (`EventService.assertCanManage`, `403` via `APIError.forbidden`). ✅
- Boundary test for the 5-vs-6 active-event limit (`AppTests.testFreeUserCanHostExactlyFiveActiveEvents`) — the plan's own §5 flags exactly this as the likely bug class. ✅
- **Not yet done**: htmx fragment responses (join/leave currently redirect the full page rather than swap an OOB fragment — see the note atop `EventWebController.swift`); the Tailwind CLI build (currently CDN-loaded in `layouts/base.leaf`); a real city/venue autocomplete widget on the create-event form (currently hidden lat/lng inputs default to `0`); compiler verification.

## M5 — Realtime chat — ⬜ not started

`ChatMessage` model and `ChatMessageDTO`/`ChatEnvelope` wire types exist (M1/shared package); no `ChatRoomRegistry` actor, WebSocket route, or htmx `ws` client wiring yet.

## M6 — Groups & group events — 🟡 partial

- Data model + membership roles + group-hosted event creation permission check (owner/moderator only) already work via `EventService.createEvent`'s `hostGroupID` path and `GroupMembership` checks. ✅
- Private group event visibility (listing, direct URL, API) enforced in `EventService.assertVisible`/`filteredEvents`. ✅
- `PlanLimitsService.assertCanCreateGroup` (Premium-only, one group per membership) exists. ✅
- **Not yet done**: no `GroupController` (web or API) to actually create/view/join a group, no moderator-promotion endpoint (max 5), no group directory/detail pages, no chat-socket visibility check (depends on M5).

## M7 — Follow & activity feed — 🟡 partial

- `Follow` model, `ActivityFeedItem` model + DTO exist. ✅
- `EventService` fans out `ActivityFeedItem` rows to followers on join/leave, synchronously in the same request (architecture §10's replacement for Firestore triggers). ✅
- **Not yet done**: no follow/unfollow endpoint, no profile Following/Followers tabs, no `/feed` endpoint, no feed generation on the `startedFollowing`/`groupPostedEvent` triggers.

## M8 — Billing (Stripe) — ⬜ not started

`Subscription`/`Invoice` models and DTOs exist; `PlanLimitsService` already reads `Subscription.isActivePremium`, so wiring real Stripe Checkout/webhooks later is additive. No Stripe integration, checkout route, or webhook handler yet.

## M9 — Account & GDPR basics — ⬜ not started

`DeletionRequest`/`DataExportRequest` models exist; `User.privacyPolicyVersion`/`termsVersion`/`consentedAt` are populated on every sign-up (`AuthService`, `LegalVersions`). No "download my data," "delete account," or retention-cleanup job yet.

## M10 — Admin web site — ⬜ not started

`AdminMiddleware` exists and is ready to gate a route group; `AdminAuditLog` model exists. No `/admin` routes, views, or the six sections yet.

## M11 — JSON API + shared Swift package — 🟡 partial

`Packages/ExpatEventsAPI` exists with the DTOs/enums/`ChatEnvelope`/`APIRoute`/`APIError` described in architecture §5, consumed by `Server` via a local path dependency (no duplicate type definitions). ✅ The `/api/v1` surface itself is only as complete as M2/M4 above — most of architecture §7's table (groups, profile, feed, billing, admin) isn't built yet.

## M12 — i18n scaffolding — ⬜ not started

Not started. The legacy app's `src/locales/en/translate.json` key structure (referenced in architecture §15) hasn't been ported yet.

## M13 — Deployment (DigitalOcean) — ⬜ not started

Not started — and can't meaningfully proceed without the DigitalOcean/Stripe/Apple/Google/DNS accounts listed in AGENTS.md's prerequisites section, which this build environment doesn't have access to.

---

**Definition of done reminder** (plan §6): all of M1–M13 passing, with M3 allowed to slip under its escape hatch, every §5 known-risk item explicitly tested, and nothing from §4's deferred list built without a written reason. We're a long way from that — this tracker exists so the distance is always visible rather than assumed.
