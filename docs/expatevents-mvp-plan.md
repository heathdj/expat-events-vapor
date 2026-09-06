# ExpatEvents MVP — Handoff Plan

This document is meant to be handed to a coding agent to build, and separately to an independent QA agent to verify. It assumes both have access to `expatevents-vapor-architecture.md` (the full architecture plan) for background and rationale — this document is the actionable, testable subset of that plan, scoped to a first shippable release.

**The one scope call worth flagging up front**: this MVP ships the Vapor backend, the web app (public + admin), and the `/api/v1` JSON surface + shared `ExpatEventsAPI` Swift package — but not the native SwiftUI consumer app or the native macOS admin app themselves. Building the API correctly now means those are additive later with no backend rework, but actually shipping three Apple app targets isn't "minimum." If that's wrong, say so before the coding agent starts — everything below assumes it.

### For the coding agent
Build the milestones in order — each depends on the ones before it. Don't mark a milestone done until its acceptance criteria are demonstrably true, ideally backed by automated tests. Don't build anything listed under "Deferred to Phase 2" — that's scope creep, not thoroughness. Commit at milestone boundaries so QA can check out a specific point in history if needed.

### For the QA agent
Work strictly from the acceptance criteria below, milestone by milestone — don't rely on the coding agent's commit messages or self-reported status. File a finding for anything that doesn't hold, for anything from the "Deferred to Phase 2" list that got built anyway, and for anything the "Known risk areas" section turns up even where no specific criterion names it.

---

## 1. Scope at a glance

| Area | In MVP | Deferred to Phase 2 |
|---|---|---|
| Backend (Vapor/Fluent/Postgres) | ✓ full data model | — |
| Web app (Leaf/htmx/Alpine/Tailwind/Flowbite) | ✓ | — |
| Auth | Apple + Google (required), Passkeys (stretch, see M3) | — |
| Events | Create/edit/cancel, browse/filter, join/leave, plan limits | Recurring-event auto-generation (flag only, no engine) |
| Realtime chat | ✓ WebSocket, one-level replies | Multi-instance fan-out (Redis/LISTEN-NOTIFY) |
| Groups | Create, moderators, public/invite-only, group events | Invite-only "request to join" workflow (owner adds members directly for now) |
| Follow & feed | ✓ | — |
| Billing (Stripe) | ✓ Checkout, webhooks, plan enforcement, admin override | — |
| GDPR basics | Consent versioning, data export, account deletion, retention cleanup | Fully automated async export/deletion job queue (a simpler synchronous/admin-triggered version ships instead) |
| Admin | ✓ web admin, all six sections | Native macOS admin app, `/api/v1/admin`, `ExpatEventsAdminAPI` |
| JSON API (`/api/v1`) | ✓ everything except `/admin` | `/api/v1/admin` |
| Shared Swift package | ✓ `ExpatEventsAPI` (types only) | `ExpatEventsClient`, `ExpatEventsAdminAPI`, both native apps |
| i18n | Mechanism + English content | Spanish translations (mechanism supports adding them later) |
| Hosting | ✓ DigitalOcean, staging + production, EU region | — |

## 2. Prerequisites (before M1 starts)

- DigitalOcean account + API token; a Postgres Managed Database and a Spaces bucket provisioned in an EU region (Frankfurt).
- A Stripe account in test mode, with a Product/two Prices ($10/mo, $100/yr) created, and a webhook signing secret.
- An Apple Developer account: a Services ID configured for "Sign in with Apple" (web), and the app's bundle identifier reserved now even though the native app ships later — the `apple-app-site-association` file in M13 needs it.
- A Google Cloud project with an OAuth consent screen and a web client ID/secret for "Sign in with Google."
- DNS access for `expatevents.net` (currently pointed at Firebase Hosting) — staging runs on a subdomain until go-live; go-live repoints the apex domain.
- Confirmation that no automated Firebase data migration is expected (per the architecture doc's launch approach) — the MVP database starts empty/seeded, not populated from the live site.

## 3. Milestones

### M1 — Project scaffolding & data model
**Deliverables**: monorepo layout (`/Packages/ExpatEventsAPI`, `/Server`); Vapor project with Postgres via environment variables; Fluent migrations for every model in the architecture doc (`User`, `OAuthIdentity`, `PasskeyCredential`, `Subscription`, `Invoice`, `Group`, `GroupMembership`, `Event`, `EventAttendee`, `ChatMessage`, `Follow`, `ActivityFeedItem`, `Feedback`, `DeletionRequest`, `DataExportRequest`, `AdminAuditLog`); a local dev seed script; a README.

**Acceptance criteria**
1. `vapor build` succeeds cleanly.
2. Running migrations against a fresh database creates every listed table with the fields, foreign keys, and enum constraints from the architecture doc.
3. The seed script creates at least 3 users, 2 events (one user-hosted, one group-hosted), and 1 group with a moderator; running it twice doesn't duplicate rows.
4. A health-check route returns 200 confirming DB connectivity.
5. Following the README exactly, on a clean checkout, produces a running server.

### M2 — Auth: Sign in with Apple + Sign in with Google
**Deliverables**: OAuth sign-in for both providers; session cookie (web) and bearer token issuance (API); account linking by verified email.

**Acceptance criteria**
1. `/login` offers "Continue with Apple" and "Continue with Google" only — no password field anywhere.
2. A new email signing in via Apple creates exactly one `User` and one `OAuthIdentity` (`provider = apple`); same for Google.
3. Signing in via Google with an email already linked to an Apple-created account links to the **same** `User` (verify by ID) — a second `OAuthIdentity`, not a second `User`.
4. A signed-in web session authenticates subsequent requests without re-prompting.
5. `POST /api/v1/auth/apple` / `/google` with a valid provider token returns a bearer token that authenticates `GET /api/v1/me`.
6. An invalid/expired provider token returns `401` with a structured error, never a 500.
7. Signing out invalidates the web session.

### M3 — Auth: Passkeys *(stretch — see escape hatch)*
**Deliverables**: WebAuthn registration/authentication via `swift-server/swift-webauthn`; `/account/passkeys` management UI.

**Acceptance criteria**
1. A signed-in user can register a passkey from `/account/passkeys`, creating a `PasskeyCredential` linked to their **existing** account, not a new one.
2. A signed-out user can sign in with a previously registered passkey and lands on the same account.
3. `/account/passkeys` lists credentials with a device label and lets the user remove one; a removed credential can no longer authenticate.
4. A replayed/tampered assertion is rejected, not accepted.

**Escape hatch**: if the alpha-stage library blocks this milestone, ship MVP with M2 only, file this as an immediate fast-follow, and don't let it block M4 onward.

### M4 — Events
**Deliverables**: create/edit/cancel (self-hosted only — group-hosting arrives in M6), browse/filter dashboard, event detail, join/leave, Free-tier plan-limit enforcement.

**Acceptance criteria**
1. A Free user can create up to 5 active events; the 6th attempt is rejected with a clear plan-limit error, not a 500.
2. A Free-tier event accepts up to 5 attendees; the 6th join attempt is rejected the same way.
3. A Free user cannot set an event to `private` — hidden in the UI, and rejected server-side if forced directly.
4. `/events` filters by category, city, venue, host, and date correctly against seeded data with both matching and non-matching rows.
5. `/events/:id` shows the correct title, host, date, venue, description, and attendee list for a seeded event.
6. Join/leave updates the attendee list and count via htmx swap, no full reload.
7. Cancelling (as host) sets `isCancelled = true`; the row and attendee history survive.
8. A non-host cannot edit or cancel someone else's event (`403` on a direct attempt).

### M5 — Realtime chat
**Deliverables**: one WebSocket channel per event; htmx `ws` extension on the web client; persistence; one-level reply threading; connect-time auth + visibility check.

**Acceptance criteria**
1. Two concurrent authenticated sessions on the same event's chat both see either one's message live, without reload.
2. Messages persist to `ChatMessage` — reload shows the same history the live view showed.
3. Replies store the correct `parentID` and render nested, matching current behavior.
4. An unauthenticated visitor cannot open a chat socket for any event.
5. A non-member of a private group event's hosting group cannot open that event's chat socket, even knowing the event id directly.
6. Reloading after the socket disconnects still shows full history (fallback path works).

### M6 — Groups & group events
**Deliverables**: group creation (Premium-gated, one per membership), moderator promotion (max 5), directory/detail pages, group-hosted events with public/private visibility.

**Acceptance criteria**
1. A Free user attempting to create a group sees a clear upgrade prompt, not a raw error.
2. A Premium user can create exactly one group; a second attempt while still owning the first is rejected.
3. An owner can promote up to 5 moderators; the 6th attempt is rejected.
4. A moderator (not the owner) can create a group-hosted event; a plain member cannot.
5. A private group event is invisible to a non-member via the listing, the direct detail URL, **and** the JSON API — check all three.
6. A member of the hosting group can see and join that same private event.
7. The group detail page's three tabs (Upcoming Events / About / Members) show correct, distinct content for at least 2 seeded groups.

### M7 — Follow & activity feed
**Deliverables**: follow/unfollow, profile Following/Followers tabs, activity-feed generation on join/leave/follow, feed display.

**Acceptance criteria**
1. Follow/unfollow creates/removes exactly one `Follow` row; the button updates immediately via htmx.
2. A profile's Followers/Following tabs list exactly the seeded relationships, with correct counts.
3. When a followed user joins an event, an `ActivityFeedItem` (`type = joinedEvent`) appears in the follower's `/feed`.
4. Unfollowing stops future activity from appearing but doesn't retroactively delete past feed items.
5. `/api/v1/feed` returns only the requester's own feed, regardless of query parameters passed.

### M8 — Billing (Stripe)
**Deliverables**: Checkout session creation, all four webhook handlers from the architecture doc, cancel-at-period-end, admin plan override.

**Acceptance criteria** *(Stripe test mode)*
1. "Upgrade to Premium" (monthly) creates a Checkout Session for the correct price and redirects there.
2. Completing test checkout and receiving `checkout.session.completed` sets `plan = premium`, `status = active` — verified functionally by then creating a 6th active event and having it succeed.
3. A simulated `invoice.payment_failed` sets `status = pastDue` and the UI shows it (a banner, not silence).
4. In-app cancellation schedules cancellation at period end; local `status` only flips to `canceled` when the webhook actually arrives, not optimistically.
5. An admin can grant Premium directly (`grantedByAdmin = true`) without a real Stripe subscription, and plan limits reflect it immediately; this writes an `AdminAuditLog` row.
6. A webhook request with an invalid signature is rejected, not processed.
7. Replaying the same webhook event id doesn't double-apply its effect (e.g., no duplicate `Invoice` row).

### M9 — Account & GDPR basics
**Deliverables**: consent versioning at signup, "Download my data," "Delete account," a retention cleanup job.

**Acceptance criteria**
1. Registration records `privacyPolicyVersion`, `termsVersion`, `consentedAt` matching what was actually presented.
2. "Download my data" produces an export containing only that user's own profile, events, group memberships, and chat messages — nothing belonging to anyone else.
3. "Delete account" creates a `DeletionRequest`; whatever fulfillment path was actually built (admin-actioned or automated — see scope note) hard-deletes identifying `User` fields, anonymizes that user's `ChatMessage`s (not deletes them), and nulls the user reference on their `Invoice` rows (also not deleted).
4. After deletion, no linked sign-in method (Apple/Google/passkey) can authenticate that account anymore.
5. The retention job deletes past/cancelled events (and their chat) older than 30 days, for both Free and Premium hosts.

### M10 — Admin web site
**Deliverables**: `/admin` route group with role middleware; the six sections (Dashboard, Users, Events, Groups, Billing, Data requests, Audit log).

**Acceptance criteria**
1. A non-admin hitting any `/admin/*` route is blocked (403/redirect), never rendered the page.
2. Users: searchable table; can comp/change plan, suspend (`isSuspended`), and view a user's events/groups.
3. A suspended user cannot sign in — verified directly, not just by checking the flag.
4. Groups: can transfer ownership to a different Premium user; both the old and new owner's `GroupMembership.role` end up correct.
5. Data requests: shows pending `DeletionRequest`/`DataExportRequest` rows and can mark them processed.
6. Every action above writes exactly one correct `AdminAuditLog` row (right admin, action, target) — not zero, not duplicates.

### M11 — JSON API (`/api/v1`) + shared Swift package
**Deliverables**: the full public `/api/v1` surface from the architecture doc (everything except `/admin`), sharing the same service layer as the web controllers; the `ExpatEventsAPI` package (DTOs, enums, `ChatEnvelope`) checked into `/Packages/ExpatEventsAPI`, consumed by `/Server` via a local path dependency.

**Acceptance criteria**
1. Every non-admin route from the architecture doc exists, enforces the same auth/permission rules as its web equivalent, and returns the documented DTO shape.
2. `/Server` depends on `ExpatEventsAPI` via the local path — no copy-pasted duplicate type definitions.
3. An end-to-end script (sign in → create event → join it → fetch it → open chat socket → send a message) succeeds using `/api/v1` alone, no HTML page involved.
4. Dates round-trip correctly through the shared ISO-8601 coding strategy.

### M12 — i18n scaffolding
**Deliverables**: Leaf key-lookup mechanism; English locale file covering all public-site copy (same keys as the current app's `translate.json`, Spanish content itself deferred).

**Acceptance criteria**
1. Every public-site string comes from the locale file, not hardcoded in a template.
2. Adding a second locale file with the same keys and switching locale changes rendered copy with zero template edits — test with a throwaway locale, real Spanish translation isn't required for this to pass.
3. Admin site and API error messages are deliberately NOT localized.

### M13 — Deployment (DigitalOcean)
**Deliverables**: staging + production, Managed Postgres (EU region), Spaces wired for file storage, `expatevents.net` TLS, `/.well-known/apple-app-site-association` served.

**Acceptance criteria**
1. Staging is reachable over HTTPS at a staging subdomain, via the same build process production will use.
2. `https://expatevents.net/.well-known/apple-app-site-association` returns correct JSON — even with no native app consuming it yet, this unblocks Phase 2 without a redeploy.
3. No secrets (Stripe keys, OAuth secrets, DB credentials) are committed to the repo.
4. A deploy from a clean checkout, following the README, succeeds with no undocumented manual steps.
5. Stripe's test webhook delivery successfully reaches the deployed staging endpoint.

## 4. Deferred to Phase 2 — do not build now

- The native SwiftUI consumer app (iOS/iPadOS/macOS) and the `ExpatEventsClient` package target.
- The native macOS admin app, `ExpatEventsAdminAPI`, and `/api/v1/admin`.
- Invite-only groups' "request to join" workflow (`GroupJoinRequest`) — owner/moderators add members directly for now.
- Recurring-event auto-generation (the `isRecurring` flag is stored; no repeat-instance engine yet).
- Spanish translation content.
- A fully automated async job queue for data export/deletion.
- Multi-instance chat fan-out (Redis pub/sub or Postgres `LISTEN`/`NOTIFY`).

## 5. QA verification approach

- Re-seed the database per test run for criteria that reference seeded data — don't test against state polluted by earlier manual poking.
- For Stripe (M8), use Stripe's test mode and CLI (`stripe trigger`, `stripe listen`) to fire real webhook payloads rather than hand-constructing them.
- For chat (M5), use two genuinely concurrent connections, not one connection talking to itself.
- Test everything with both a web and an API path (most of M4–M9) through **both** surfaces — a bug that only shows up in one is still a bug.

### Known risk areas — probe these even where no single criterion names them
1. **Plan-limit boundaries**: off-by-one is the likely bug class (4 vs. 5 vs. 6) — test the exact boundary.
2. **Stripe webhook idempotency/ordering**: webhooks can arrive out of order or be redelivered; confirm state doesn't corrupt.
3. **Private group event visibility**: test the listing, the direct URL, the JSON API, *and* the chat socket independently for a non-member — each surface must enforce the rule on its own.
4. **WebAuthn replay/tamper resistance** (if M3 shipped): specifically attempt to reuse a captured assertion.
5. **Account deletion side effects**: a deleted user's past chat messages should survive (anonymized), not break other users' view of old conversations; their invoices should survive (anonymized), not corrupt billing history.
6. **Admin audit completeness**: exactly one row per admin action tested — not zero, not duplicates.
7. **Account linking** (M2): the under-tested case is linking a *second* sign-in method to an existing email, not first-time sign-in.
8. **Cross-tier enforcement**: a Free user shouldn't reach Premium-gated actions via a raw route, even where the UI correctly hides the button.

## 6. Definition of done

All of M1–M13's acceptance criteria pass, with M3 (Passkeys) allowed to ship as a documented fast-follow under its own escape hatch, provided M2 fully covers sign-in on its own. Every item in §5's known-risk list has been explicitly tested, not just the milestone criteria. Nothing from §4's deferred list was built without a deliberate, written reason for the exception.
