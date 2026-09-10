# Milestone status

Tracking against [`docs/expatevents-mvp-plan.md`](docs/expatevents-mvp-plan.md)'s 13 milestones. Update this file whenever a milestone's status changes — it's the fastest way for anyone (or any agent) picking this up to see what's real.

Legend: ✅ built (not yet compiler-verified — see AGENTS.md "step zero") · 🟡 partial · ⬜ not started

## M1 — Project scaffolding & data model — ✅ done (build + test + human-reviewed server checkpoint)

- Monorepo layout: `Packages/ExpatEventsAPI`, `Server/`. ✅
- Vapor project with Postgres via environment variables (`configure.swift`). ✅
- Fluent migrations for every model in the architecture doc — all 16: `User`, `OAuthIdentity`, `PasskeyCredential`, `Subscription`, `Invoice`, `Group`, `GroupMembership`, `Event`, `EventAttendee`, `ChatMessage`, `Follow`, `ActivityFeedItem`, `Feedback`, `DeletionRequest`, `DataExportRequest`, `AdminAuditLog` — plus native Postgres enum types for every shared enum. ✅
- Local dev seed script, idempotent (`Commands/SeedCommand.swift`). ✅
- README. ✅
- `swift build` is clean (0 errors, 0 warnings from our own code — see `WARNINGS.md` for the third-party/tracked exceptions). ✅
- `swift test` passes all 3 tests against real Postgres (`testHealthCheckReturns200`, `testFreeUserCanHostExactlyFiveActiveEvents`, `testSeedCommandIsIdempotent`) — criterion #4 (health check) and #3 (idempotent seed) both confirmed for real, not just written. ✅ Along the way, found and fixed real bugs: a missing `import ExpatEventsAPI` and a wrong XCTVapor API name in the test file, a dev Postgres on the default port colliding with another Postgres already running on this machine (moved to host port 5433 — see `docker-compose.yml`/`.env.example`), and a test that crashed invoking `SeedCommand` without setting `context.application` first.
- Criterion #5 confirmed: `swift run App migrate --yes` (29 migrations) → `swift run App seed` (3 users, 1 group, 2 events) → `swift run App serve`, then `GET /health` returned `{"status":"ok","database":"connected"}` and the user visually reviewed `/events` and `/login` in a browser (intentionally unstyled beyond Tailwind's CDN defaults at this stage — noted as M4 follow-up). ✅
- **All M1 acceptance criteria met.** Open items are tracked in `WARNINGS.md` (nothing launch-blocking) rather than here.

## M2 — Auth: Apple + Google — 🟡 partial (Google in progress; Apple's live verification deliberately deferred to M13)

- `/login` offers Apple/Google only, no password field. ✅ (`pages/login.leaf`)
- New sign-in creates one `User` + one `OAuthIdentity`; a second provider on the same verified email links to the same `User` (`AuthService.findOrCreateUser`). ✅
- Session cookie (web) via `User.sessionAuthenticator()` / Fluent sessions. ✅
- **Real click-through bug, found and fixed (2026-09-10)**: after confirming Google sign-in worked end-to-end, a human server checkpoint caught that the nav never flipped to the signed-in state (no "Sign out") — `GET /events`/`GET /events/:id` sat entirely outside `User.sessionAuthenticator()`, so `req.auth.get(User.self)` was always `nil` there regardless of a valid session cookie, and `isSignedIn` was hard-wired `false`. Fixed by moving those two routes onto a session-authenticated-but-not-guarded route group in `EventWebController` (signed-out visitors can still browse). Covered by new test `testSignedInSessionFlipsEventsNavToSignedInState`, which constructs a real Fluent session record and round-trips it through an actual HTTP request rather than calling the handler directly — the earlier fragment-render tests wouldn't have caught this class of bug since they bypass routing/middleware entirely.
- Bearer token (API) via `UserJWTPayload` + `UserBearerAuthenticator`; `POST /api/v1/auth/apple`/`/google` → `GET /api/v1/me`. ✅
- Invalid/expired provider token → structured 401 via `APIErrorMiddleware`, never a 500. ✅ (untested against real tokens)
- Sign-out invalidates the web session (`/logout`). ✅
- **Deliberate scope decision (2026-09-09)**: Sign in with Apple JS requires a verified HTTPS domain in its Services ID's Web Authentication Configuration — it does not accept `localhost`, and `expatevents.net` currently points at Firebase Hosting (per the plan's own §2 prerequisites; DNS doesn't move to this build until M13). Rather than standing up a throwaway tunnel domain just to unblock local testing now, **Apple-specific configuration and end-to-end verification are moved to M13** (Deployment), once the real staging/production domain exists to register. `APPLE_CLIENT_ID` support, `AppleIdentityTokenVerifier`, and the Sign in with Apple JS wiring in `login.leaf` are already built and code-reviewed — this defers *testing them for real*, not the code itself, and M13's acceptance criteria gain an explicit item for it (see below). Google has no such constraint (`localhost` is an allowed JavaScript origin), so **M2 proceeds now on Google alone**: `GOOGLE_CLIENT_ID` has been provided and end-to-end verification (real sign-in → session → `/api/v1/me`) is in progress.
- PR #2's independent review flagged that no unit test exists for `AppleIdentityTokenVerifier`/`GoogleIdentityTokenVerifier`. Added `testGoogleIdentityTokenVerifierRejectsInvalidToken` (a garbage token is rejected as `.invalidProviderToken` via a real round trip to Google's `tokeninfo` endpoint). ✅ for Google; the equivalent for `AppleIdentityTokenVerifier` is still open, tracked with the rest of Apple's verification under M13.

## M3 — Passkeys — ⬜ not started (stretch milestone; escape hatch applies)

`PasskeyCredential` exists in the M1 data model so the schema won't shift later, but no WebAuthn ceremony, `/account/passkeys` UI, or `swift-server/swift-webauthn` integration yet. Per the plan's own escape hatch, this can ship as a documented fast-follow provided M2 fully covers sign-in on its own.

## M4 — Events — ✅ done (build + test + human-reviewed server checkpoint)

All 8 acceptance criteria from the plan (§3) are now implemented and each has a dedicated test in `AppTests.swift`:

1. Free user capped at 5 active events, 6th rejected — `testFreeUserCanHostExactlyFiveActiveEvents`. ✅
2. Free-tier event capped at 5 attendees, 6th join rejected — `testFreeTierEventAcceptsExactlyFiveAttendees`. ✅
3. Free user can't set an event `private` (server-side, not just UI) — `testFreeUserCannotCreatePrivateEvent` + `testPremiumUserCanCreatePrivateEvent` (positive case, confirms it's plan-gated not a blanket ban). ✅
4. `/events` filters by category, city, venue, host, date, matching and excluding correctly — `testEventFilteringMatchesAndExcludesCorrectly`. ✅
5. Event detail shows correct title/host/date/venue/description/attendees — `testEventDetailDTOHasCorrectFields`. ✅
6. Join/leave updates via htmx swap, no full reload — new `partials/event-fragment.leaf`, extended inline by `pages/event-detail.leaf` for the normal render and rendered standalone by `EventWebController`'s `respondWithEventUpdate` when the request carries htmx's `HX-Request` header (a non-JS `<form>` submit still gets the old full-page redirect, kept as a fallback). ✅ The fragment test caught a real bug before it ever reached a browser: `hx-target="#event-fragment"` was being parsed as a Leaf tag (Leaf's `#` sigil has no concept of HTML/CSS syntax) — fixed with Leaf's `\#` escape. Server checkpoint: `/events/:id` visually confirmed rendering correctly (title, host, venue, description, "Sign in to join" fallback since M2's real sign-in isn't wired up yet) — no map or chat shown, both correctly out of scope here (chat is M5).
7. Cancel sets `isCancelled = true`, row and attendee history survive — `testCancelEventSurvivesWithAttendeeHistory`. ✅
8. Non-host can't edit/cancel, 403 — `testNonHostCannotCancelSomeoneElsesEvent`. ✅

**All M4 acceptance criteria met.** **Not yet done** (explicitly out of scope for M4's own acceptance criteria, tracked as follow-ups): the Tailwind CLI build (currently CDN-loaded in `layouts/base.leaf`); a real city/venue autocomplete widget on the create-event form (currently hidden lat/lng inputs default to `0`); the Join/Leave/Cancel buttons themselves can't be exercised through a real browser session until M2's real Apple/Google sign-in is set up (their logic is fully tested — `EventService`/`PlanLimitsService` — and the fragment template is proven to render; only the live click-through is blocked on M2).

PR #3's independent review found and this PR now fixes a real information-disclosure bug the htmx wiring introduced: `EventService.leave` — unlike `join`/`detail` — never called `assertVisible`, and `EventWebController.respondWithEventUpdate` renders the full event (title/venue/description/attendee list) straight into the `HX-Request` response, so a signed-in user who was never a member of a private group could fetch that group's private event details via `POST /events/:id/leave` (a harmless no-op attendee-row delete either way, previously masked because the old code path only ever redirected to a `GET` that re-checked visibility). Fixed in `EventService.leave`: a non-attendee is now visibility-checked exactly like `join`; an *existing* attendee who has since lost visibility (e.g. removed from the group) can still leave, so the fix doesn't strand a dangling attendee row. Covered by new test `testNonMemberCannotLeavePrivateGroupEventOrLeakDetails`. The review's other findings (missing venue/date coverage in the filtering test, missing date/description assertions in the DTO test) were also addressed; the `hx-confirm`-vs-`onsubmit` double-confirm-dialog question and the non-htmx-path error-rendering gap (`APIErrorMiddleware` only wraps `/api/v1`, so a web-path plan-limit rejection still falls through to Vapor's generic error page) are deferred as follow-ups — the latter predates this PR.

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
