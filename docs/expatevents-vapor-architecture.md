# ExpatEvents — Vapor Rebuild: Architecture & Engineering Plan

This is the engineering plan for rebuilding ExpatEvents on Vapor (Swift) with an htmx + Alpine.js frontend styled in Tailwind CSS, real-time chat, and new support for groups, group-hosted events, subscription billing, an internal admin site, passkey/SSO sign-in, and GDPR-grade data handling. It's grounded in the current React/Firebase app's real data model and copy (see the companion design canvas for the visual redesign of the screens described here).

Two frontends sit on top of one Vapor backend: the server-rendered htmx/Alpine web app, and native SwiftUI apps for iOS, iPadOS, and macOS talking to a JSON API. Both share the same Swift types for every request, response, and realtime message — see §5.

This is a written plan, not runnable code — the next step, once the shape below is agreed, is a scaffolded starter project.

## 1. Technology stack

| Layer | Choice | Notes |
|---|---|---|
| Backend | Vapor 4 (Swift), Fluent ORM | Server-rendered web app *and* a JSON API from one codebase |
| Database | PostgreSQL (managed) | Fluent's most mature driver; handles relational data far better than Firestore's document model |
| Hosting | DigitalOcean (App Platform/Droplets + Managed Postgres + Spaces) | See §2 for the full reasoning |
| Templating | Leaf | Vapor's server-side templates; renders both full pages and htmx fragments |
| Interactivity | htmx | Server round-trips for anything that touches data: filters, join/leave, pagination, admin tables, and (§8) chat itself via the `ws` extension |
| Interactivity | Alpine.js | Pure client-side state: tabs, toggles, modals, the create-event live preview, the chat compose box — anything that doesn't need the server |
| Realtime | Vapor's native WebSockets (alternatives considered in §8) | One channel per event, used for chat; broadcast via an in-memory actor, shared by both the web client and the native apps |
| Auth | Passkeys, Sign in with Apple, Sign in with Google — all native Vapor, no third-party identity provider and no password to manage | Relying-party domain: `expatevents.net`, confirmed. Native apps use `AuthenticationServices` for both passkeys and Apple sign-in, and Google's native SDK; the web uses the browser WebAuthn API, "Sign in with Apple JS," and Google Identity Services JS. Library choice discussed in §18 |
| Styling | Tailwind CSS (CLI build) | Compiled at build time; no Node process at runtime |
| Component layer | Flowbite | Vanilla-JS components (dropdowns, modals, tabs) that coexist cleanly with Alpine |
| Payments | Stripe (Checkout + Billing + Webhooks) | Called directly via Vapor's `Client` against Stripe's REST API rather than a third-party Swift wrapper |
| Shared API types | Swift Package (`ExpatEventsAPI`) | Codable DTOs, enums, and the realtime message envelope, shared verbatim by the Vapor server and the SwiftUI apps — see §5 |
| File storage | DigitalOcean Spaces (S3-compatible) | Same provider as hosting — see §2 |

## 2. Hosting & infrastructure

Three contenders were on the table — Fly.io, DigitalOcean, Railway — weighed against two stated preferences: S3-compatible storage from the same provider, and GDPR-friendly EU regions (§13).

| | DigitalOcean | Fly.io | Railway |
|---|---|---|---|
| Compute | App Platform (managed) or Droplets | Fly Machines (edge-distributed) | Railway services |
| Managed Postgres | ✓ Managed Databases | via partners (Supabase/Neon) or self-run | ✓ Postgres plugin |
| S3-compatible storage, same provider | ✓ Spaces | ✓ Tigris (native integration) | ✗ — no first-party object storage |
| WebSocket / long-lived connections | Solid | Excellent — Fly's architecture is built around long-lived connections close to users | Solid |
| EU region(s) | ✓ Frankfurt, Amsterdam | ✓ Amsterdam, Paris, Frankfurt, more | ✓ EU region available |
| Pricing/DX | Predictable, mature dashboard | Usage-based, dev-friendly CLI | Best-in-class DX, newer at production scale |

**Recommendation: DigitalOcean.** It's the only one of the three where compute, managed Postgres, *and* S3-compatible object storage (Spaces) come from one provider with one bill and clear EU regions — exactly the "storage from the hosting provider" preference plus the data-residency angle from §13. App Platform (or a Droplet, for more control over the long-lived WebSocket process) handles Vapor's chat connections fine at this app's likely scale.

**Fly.io** is the strongest runner-up — genuinely better for WebSocket-heavy traffic at larger scale or a more geographically spread-out user base (which "expats everywhere" plausibly becomes over time), and Tigris is a real same-provider alternative to Spaces. Worth revisiting if realtime chat volume or global latency becomes a real constraint post-launch.

**Railway** has the best raw developer experience of the three, but no first-party object storage breaks the "one provider" preference — it would mean bolting on a separate storage vendor.

**Region**: default to an EU region (Frankfurt) for the primary database given the GDPR posture in §13, unless the actual user base turns out to skew heavily toward a different region once there's real usage data to look at.

## 3. High-level architecture

```
                         ┌─────────────────────────┐
Browser ──hx-get/post──▶ │                         │
                         │     Vapor Controllers    │──Fluent──▶ PostgreSQL
SwiftUI ──/api/v1──────▶ │  (HTML + JSON responses) │
  apps                    └─────────────────────────┘
   │                              │
   │◀── HTML fragments / JSON ────┘   (both built from the same service layer)
   │
   ├──WebSocket (browser, via htmx ws ext)──┐
   │                                        ├──▶ ChatRoomRegistry (actor, in-memory) ──Fluent──▶ ChatMessage table
   └──WebSocket (SwiftUI, URLSessionWebSocketTask)──┘           │
                                                                 └──broadcast (shared envelope type)──▶ all sockets in that event's room
```

Every web page is server-rendered HTML (Leaf); htmx swaps fragments in without a client router; Alpine owns local UI state the server doesn't need to know about. The native apps talk to the same backend over a `/api/v1` JSON surface (§7) and the same realtime channel (§8), using types from the `ExpatEventsAPI` package (§5) instead of hand-parsed JSON — so a schema change is a compile error on both server and client, not a runtime surprise discovered in production.

## 4. Data model (Fluent)

Mapped from the current Firestore collections (`users`, `events`, `following`, `feedback`, `deleteUserRequest`, the Realtime DB chat comments, and the Cloud Functions-driven activity feed), with new tables for groups, subscriptions, admin, identity, and data-rights requests. These are server-only Fluent models; the wire-format DTOs that mirror them live in the shared package described next.

**User**
| Field | Type | Notes |
|---|---|---|
| id | UUID | |
| displayName | String | |
| email | String, unique | |
| photoURL | String? | |
| role | enum: `member`, `admin` | new — drives admin-site access |
| isSuspended | Bool | new — admin action |
| privacyPolicyVersion / termsVersion | String | *which* version was agreed to, for compliance (§13) |
| consentedAt | Date | replaces the current flat `privacy`/`terms` booleans |
| createdAt | Date | |

No password field at all — every sign-in method (below) is passwordless.

**OAuthIdentity** *(new)* — `id`, `userID` FK, `provider` (enum: `apple`, `google`), `providerUserID`, `createdAt`. One user can link more than one identity (e.g. registered with Google, later added a passkey and linked Apple too).

**PasskeyCredential** *(new)* — `id`, `userID` FK, `credentialID` (unique), `publicKey`, `signCount`, `deviceLabel` (e.g. "iPhone 15 Pro," shown in an account's "manage passkeys" list), `createdAt`, `lastUsedAt`. Stores only what WebAuthn ever hands the server — a public key and a signature counter; no biometric data ever leaves the user's device.

**Subscription** *(new — replaces the current `paid: Bool` flag)*
| Field | Type | Notes |
|---|---|---|
| id | UUID | |
| userID | User FK | |
| plan | enum: `free`, `premium` | |
| billingCycle | enum: `monthly`, `yearly` | |
| status | enum: `active`, `pastDue`, `canceled` | |
| stripeCustomerID / stripeSubscriptionID | String? | null for `free` |
| currentPeriodEnd | Date? | |
| grantedByAdmin | Bool | true for comped Premium, see §12 |

**Invoice** *(new)* — `id`, `subscriptionID`, `amountCents`, `currency`, `status`, `stripeInvoiceID`, `createdAt`.

**Group** *(new)*
| Field | Type | Notes |
|---|---|---|
| id | UUID | |
| name / slug / description | String | |
| avatarURL / coverURL | String? | |
| visibility | enum: `public`, `inviteOnly` | matches "groups are public by default" |
| ownerID | User FK | must hold an active Premium subscription |
| createdAt | Date | |

**GroupMembership** *(new)* — `id`, `groupID`, `userID`, `role` (`owner` / `moderator` / `member`), `joinedAt`. App-level rule: at most 5 moderators per group.

**Event** — extends the current `events` doc:
| Field | Type | Notes |
|---|---|---|
| id, title, description | | as today |
| category | enum: culture/drinks/film/food/music/travel | |
| cityAddress/cityLat/cityLng, venueAddress/venueLat/venueLng | | as today |
| date | Date | |
| hostUserID | User FK, nullable | |
| hostGroupID | Group FK, nullable | exactly one of hostUserID/hostGroupID is set |
| visibility | enum: `public`, `private` | private only for group events, visible to members only |
| attendeeLimit | Int? | nil = plan default (100 for Premium) |
| isRecurring | Bool | |
| isCancelled | Bool | as today |

**EventAttendee** *(new table, replaces the embedded `attendees[]`/`attendeeIds[]` arrays)* — `id`, `eventID`, `userID`, `joinedAt`.

**ChatMessage** *(new table, replaces the Realtime Database comments)* — `id`, `eventID`, `userID`, `parentID` (self-referencing, nullable — one level of replies, matching the current UI), `text`, `createdAt`.

**Follow** *(kept from the current app's `following` collection)* — `id`, `followerID`, `followingID`, `createdAt`.

**ActivityFeedItem** *(new — replaces the Cloud Functions that pushed to Realtime DB `/posts/{userId}`)* — `id`, `recipientUserID` (whose feed this appears in), `actorUserID`, `type` (enum: `joinedEvent`, `leftEvent`, `startedFollowing`, `groupPostedEvent`), `eventID?`, `createdAt`. Populated synchronously inside the relevant handler (join/leave/follow) rather than via a separate trigger function, since Vapor doesn't have a Firestore-style `onCreate`/`onUpdate` hook — the equivalent logic just lives directly in `EventController`/`ProfileController`.

**Feedback** — `id`, `userID?`, `message`, `createdAt` (as today).

**DeletionRequest** — `id`, `userID`, `requestedAt`, `processedAt?` (formalizes the current `deleteUserRequest` into a real GDPR erasure pipeline — see §13).

**DataExportRequest** *(new)* — `id`, `userID`, `requestedAt`, `status` (`pending`/`ready`/`expired`), `downloadToken`, `expiresAt`. Backs the "download my data" right-to-portability feature (§13).

**AdminAuditLog** *(new)* — `id`, `adminUserID`, `action`, `targetType`, `targetID`, `metadata` (JSON), `createdAt`. Every mutating admin action writes one row here.

## 5. Shared Swift package for API types

A dedicated package, `ExpatEventsAPI`, holds every type that crosses the wire — request bodies, response bodies, enums, and the realtime message envelope — and nothing else. It depends only on `Foundation`, so it builds cleanly on both Linux (the Vapor server) and Apple platforms (the SwiftUI apps). No Vapor, no Fluent, no UIKit/SwiftUI, no secrets, and no admin-only or server-internal types belong here — this package is the *contract*, not the implementation.

**What lives in it:**

- **Enums** shared verbatim: `EventCategory`, `EventVisibility`, `PlanTier`, `BillingCycle`, `SubscriptionStatus`, `GroupVisibility`, `GroupRole`, `UserRole`, `IdentityProvider` (`apple`/`google`).
- **DTOs** mirroring the Fluent models in §4, shaped for the wire rather than the database — e.g. `EventSummaryDTO` (lighter, for list views) alongside a fuller `EventDTO`; `UserDTO`/`ProfileDTO` expose only public-safe fields; `GroupDTO`, `GroupMemberDTO`, `SubscriptionDTO`, `ChatMessageDTO`, `ActivityFeedItemDTO`.
- **Request types**: `CreateEventRequest`, `UpdateEventRequest`, `CreateGroupRequest`, `AppleSignInRequest`/`GoogleSignInRequest` (carrying the provider's identity token for server-side verification), and so on.
- **Passkey ceremony DTOs**: `PasskeyRegistrationOptions` / `PasskeyAssertionOptions` (the challenge and relying-party info, RP ID `expatevents.net`) and the attestation/assertion payloads the client posts back. The actual cryptographic verification stays server-side only (library options in §18).

A sibling package, **`ExpatEventsAdminAPI`**, holds the admin-only DTOs (`AdminUserDTO`, `AdminEventDTO`, `AuditLogEntryDTO`, and so on) for the native macOS admin app (§12). It's kept separate from `ExpatEventsAPI` on purpose — the consumer iOS/iPadOS/macOS app never links it, so admin data shapes never ship inside a public app bundle.
- **`ChatEnvelope`** — an enum (`.message(ChatMessageDTO)`, `.typing(UserID)`, `.presence(...)`) that *is* the realtime wire format. Because both the Vapor broadcaster and the native app's client encode/decode this exact Swift type, a protocol change is a compile error in both places instead of a runtime mismatch.
- **`APIError`** — a consistent `{code, message}` shape for error responses.
- **A shared date-coding strategy** (ISO 8601) defined once, so the server and every client encode/decode dates identically.
- **Route path helpers** — a small `APIRoute` namespace (`APIRoute.events`, `APIRoute.event(id:)`, `APIRoute.groupJoin(slug:)`) so endpoint paths aren't hand-typed and drifting between client and server.

**Optional second target**, `ExpatEventsClient`: a thin `async`/`await` URLSession-based API client built on the DTOs above. Kept separate from the DTOs so a consumer that only wants the types isn't forced to also pull in networking code — the Vapor server imports `ExpatEventsAPI` but never `ExpatEventsClient`.

Vapor controllers convert between Fluent models and these DTOs at the boundary (`Event.toDTO()` / `EventDTO(from:)`) — the database schema and the wire format are related but never the same type.

**Repo layout.** A monorepo with the package added as a local SPM path dependency, keeping server and client in lockstep during active development:

```
expatevents/
  Packages/
    ExpatEventsAPI/            SPM package
      Package.swift
      Sources/
        ExpatEventsAPI/          DTOs, enums, ChatEnvelope, route helpers
        ExpatEventsClient/        URLSession client (depends on ExpatEventsAPI)
    ExpatEventsAdminAPI/        SPM package — admin-only DTOs (§12)
      Package.swift
      Sources/ExpatEventsAdminAPI/
  Server/                       Vapor app
    Package.swift               .package(path: "../Packages/ExpatEventsAPI")
                                .package(path: "../Packages/ExpatEventsAdminAPI")
    Sources/App/...
  AppleClients/                  Xcode project/workspace for the consumer
                                 iOS/iPadOS/macOS app (adds ExpatEventsAPI +
                                 ExpatEventsClient as local packages)
  AdminMacApp/                   Separate macOS-only Xcode project for the
                                 internal admin tool (§12) — adds
                                 ExpatEventsAPI + ExpatEventsAdminAPI
```

Once the API stabilizes — or a mobile team ships on its own release cadence — `ExpatEventsAPI` can graduate to its own git repository, versioned with semver tags. That's a mechanical move later, not a reason to over-engineer the layout today.

## 6. Public site: pages and htmx endpoint map

**Full pages** (server-rendered, `GET`):

| Route | Page |
|---|---|
| `/` | Home / marketing |
| `/events` | Events dashboard (filters render client-side via htmx after initial load) |
| `/events/:id` | Event detail, with initial chat history + live connection |
| `/events/new`, `/events/:id/edit` | Create/edit event (host as self or group) |
| `/groups` | Groups directory |
| `/groups/:slug` | Group detail |
| `/groups/new` | Create group (Premium only) |
| `/profile/:id` | Public profile — About / Events / Following / Followers tabs, carried over from the current app |
| `/account` | Account & billing, including "Download my data" and "Delete account" |
| `/account/passkeys` | Manage registered passkeys and linked Apple/Google identities |
| `/login`, `/register` | Auth — "Continue with Passkey," "Continue with Apple," "Continue with Google"; no password field |
| `/privacy`, `/terms` | Static content — versioned; a material change re-triggers consent |

**htmx fragment endpoints** (partial HTML, swapped into the page):

| Route | Method | Returns | Triggered by |
|---|---|---|---|
| `/events/filter` | POST | event-list fragment | filter sidebar changes |
| `/events?page=N` | GET | appended event cards | "Load more" button |
| `/events/:id/join`, `/leave` | POST | action-bar fragment + OOB attendee-count update | Join/Going button |
| `/events/:id/chat` | POST | new message fragment | chat send, fallback when realtime is unavailable (§8) |
| `/groups/:slug/join`, `/leave` | POST | membership button fragment | Join group button |
| `/groups/:slug/tab/:name` | GET | tab content fragment | Upcoming events / About / Members tabs |
| `/profile/:id/follow`, `/unfollow` | POST | follow-button fragment | Follow button |
| `/feed` | GET | activity feed fragment | dashboard sidebar for signed-in users, matching the current `EventsFeed` component |
| `/account/plan/upgrade` | POST | redirect to Stripe Checkout | Upgrade button |
| `/account/plan/cancel` | POST | updated plan card fragment | Cancel subscription button |
| `/account/export` | POST | "export requested" confirmation | Download my data button |
| `/account/delete` | POST | confirmation + sign-out | Delete account button |
| `/admin/users/table` | GET | searchable/paginated table rows | admin search box, pagination |
| `/admin/events/:id/cancel`, `/admin/groups/:id/transfer-owner` | POST | updated row fragment | admin row actions |

**Alpine vs. htmx**: if the interaction needs fresh data from the server or must persist, it's htmx (joins, follows, filters, paginated tables, chat). If it's purely local — a tab that doesn't need new data, a toggle, the create-event live-preview card, a modal's open state, the chat compose box's draft text — it's Alpine.

## 7. JSON API for native clients

A native SwiftUI app can't consume htmx HTML fragments, so the same backend also exposes a versioned JSON surface under `/api/v1`, backed by the same service layer as the web controllers and typed end-to-end with the `ExpatEventsAPI` package.

| Route | Method | Returns |
|---|---|---|
| `/api/v1/auth/passkey/register/options`, `/register/verify`, `/login/options`, `/login/verify` | POST | `PasskeyRegistrationOptions` / `AuthTokenResponse` |
| `/api/v1/auth/apple` | POST | `AuthTokenResponse` — verifies the Apple identity token from `ASAuthorizationAppleIDProvider` |
| `/api/v1/auth/google` | POST | `AuthTokenResponse` — verifies the Google ID token |
| `/api/v1/me` | GET | `UserDTO` |
| `/api/v1/events` | GET | `[EventSummaryDTO]` (filter/paginate via query params) |
| `/api/v1/events/:id` | GET | `EventDTO` |
| `/api/v1/events` | POST | `EventDTO` (create) |
| `/api/v1/events/:id/join`, `/leave` | POST | `EventDTO` (updated) |
| `/api/v1/events/:id/chat/history` | GET | `[ChatMessageDTO]` |
| `/api/v1/groups` | GET | `[GroupDTO]` |
| `/api/v1/groups/:slug` | GET | `GroupDTO` |
| `/api/v1/groups/:slug/join`, `/leave` | POST | `GroupDTO` |
| `/api/v1/profile/:id` | GET | `ProfileDTO` |
| `/api/v1/profile/:id/follow`, `/unfollow` | POST | updated `ProfileDTO` |
| `/api/v1/feed` | GET | `[ActivityFeedItemDTO]` |
| `/api/v1/account/plan` | GET | `SubscriptionDTO` |
| `/api/v1/account/plan/checkout` | POST | `CheckoutSessionResponse` (Stripe Checkout URL, opened in an in-app browser session) |
| `/api/v1/account/export` | POST | `DataExportRequestDTO` |
| `/api/v1/account` | DELETE | kicks off the erasure pipeline (§13) |
| realtime chat channel (§8) | — | `ChatEnvelope` frames — the same channel the web client uses |

**Auth for native**: token-based rather than the web's cookie session. A successful passkey, Apple, or Google sign-in returns a bearer token the app sends as `Authorization: Bearer …` on every subsequent call. Vapor runs a cookie-session authenticator on the web route group and a bearer-token authenticator on the `/api/v1` group side by side, both resolving to the same `User` model.

**Admin API** (backs the native Mac admin app, §12), gated by the same bearer-token auth plus the `AdminMiddleware` role check:

| Route | Method | Returns |
|---|---|---|
| `/api/v1/admin/users`, `/users/:id` | GET | `[AdminUserDTO]` / `AdminUserDTO` |
| `/api/v1/admin/users/:id/plan` | POST | comp/change a user's plan |
| `/api/v1/admin/users/:id/suspend` | POST | toggle `isSuspended` |
| `/api/v1/admin/events`, `/events/:id/cancel` | GET / POST | `[AdminEventDTO]` / updated `AdminEventDTO` |
| `/api/v1/admin/groups`, `/groups/:id/transfer-owner` | GET / POST | `[AdminGroupDTO]` / updated `AdminGroupDTO` |
| `/api/v1/admin/billing/subscriptions`, `/invoices` | GET | `[SubscriptionDTO]` / `[InvoiceDTO]` |
| `/api/v1/admin/data-requests` | GET | pending `DeletionRequest`/`DataExportRequest` rows |
| `/api/v1/admin/audit-log` | GET | `[AuditLogEntryDTO]` |

## 8. Realtime chat

**Why WebSockets, and what else was considered:**

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **WebSockets** | True bidirectional channel; first-class `URLSessionWebSocketTask` support in SwiftUI; Vapor has native support; htmx's `ws` extension lets the web client join declaratively | Needs its own connection/reconnect handling; less proxy-friendly than plain HTTP | **Recommended** |
| Server-Sent Events (SSE) | Plain HTTP; browser `EventSource` auto-reconnects; pairs naturally with htmx's `sse` extension | One-directional only — sending still needs a POST; no first-party SSE client on Apple platforms | Good **fallback transport**, not primary |
| Managed realtime service (Pusher, Ably, Supabase Realtime) | Scaling/fan-out handled for you; some ship native Swift SDKs | Third-party dependency and cost; still need to write back to Postgres for persistence anyway | Revisit only if the in-memory registry below becomes a bottleneck |

**Design:**

- One channel per event; group-hosted events use the same per-event channel. Both the browser and native apps connect to the same channel.
- On connect: verify the connection is authenticated (session cookie for web, bearer token for native) and that the user can see the event (public, or a member of the hosting group if private).
- An actor-based `ChatRoomRegistry` (`[EventID: Set<WebSocket>]`) holds live connections in memory.
- On incoming message: validate, persist to `ChatMessage`, then broadcast a `ChatEnvelope.message(...)` to everyone in the room, including the sender.
- Client side: the web uses htmx's `ws` extension (`ws-connect`, `ws-send`) so incoming messages render via server-returned HTML swaps with no hand-written JS; Alpine handles only the compose box's local state. The SwiftUI app's socket client decodes `ChatEnvelope` directly.
- Resilience fallback: htmx polling on the web, or a plain history poll on native, if the socket can't connect.
- Scaling note: the in-memory registry is single-process; multi-instance deployment needs Postgres `LISTEN`/`NOTIFY` or Redis pub/sub in front of it — not needed at launch.

## 9. Groups & group events

- Only users with an **active Premium subscription** can create a group, and — matching the current copy — **one group per membership**.
- The owner can promote up to **5 members to moderator**.
- A group must always have a Premium owner. If the owner's subscription lapses, block new group-event creation until they resubscribe; ownership transfer becomes an **admin action** (§12).
- Visibility: `public` (default) or `inviteOnly`. Public groups show a Join button; invite-only groups show "Request to join," notifying the owner/moderators (a `GroupJoinRequest` model — a reasonable fast-follow rather than launch-blocking).
- Group events set `Event.hostGroupID` instead of `hostUserID`; only that group's owner/moderators can create or edit events under it. A private group event is only visible to members of `hostGroupID` — enforced as a query filter, not just UI hiding.

## 10. Follow & activity feed

Kept from the current app, and built as a first-class feature rather than an afterthought:

- `Follow` records who follows whom (as today); a profile's Following/Followers tabs list them directly.
- `ActivityFeedItem` replaces the current Cloud Functions that pushed to a Realtime Database `/posts/{userId}` node on event join/leave. Since Vapor doesn't have a Firestore-style trigger function, the equivalent write happens synchronously inside the same handler that processes the join/leave/follow — e.g. `EventController.join(...)` writes the `EventAttendee` row and, in the same request, fans out an `ActivityFeedItem` to each of the joining user's followers.
- The dashboard's feed sidebar (`/feed`, matching the current `EventsFeed` component) shows recent activity from people the signed-in user follows — new followers, events they joined or are hosting, new group events from groups they belong to.
- No special permission gating: any authenticated user can follow any other.

## 11. Billing & charging

Stripe Checkout + Billing Portal + webhooks, matching the current $10/mo or $100/yr Premium pricing (including the "billed in local currency at the day's exchange rate" note, which Stripe's multi-currency presentment handles automatically).

- **Upgrade**: `POST /account/plan/upgrade` (web) or `POST /api/v1/account/plan/checkout` (native) creates a Stripe Checkout Session. The web redirects there directly; native opens the URL in an in-app browser session (`ASWebAuthenticationSession`).
- **Webhook**: `POST /webhooks/stripe` (signature-verified) handles `checkout.session.completed`/`customer.subscription.updated` (create/update `Subscription`), `customer.subscription.deleted` (mark canceled), `invoice.paid` (create `Invoice`), `invoice.payment_failed` (mark `pastDue`).
- **Cancel**: `POST /account/plan/cancel` cancels at period end via Stripe; the webhook confirms.
- **Plan enforcement**: a `PlanLimitsService` — Free: 5 active hosted events, 5 attendees/event, public only; Premium: unlimited events, 100 attendees by default, private events allowed, one group.
- **Admin override**: comp/change a plan directly, logged to `AdminAuditLog`.
- Stripe is itself a data subprocessor — see §13.

## 12. Admin site

A separate route group (`/admin`) in the same Vapor app, gated by an `AdminMiddleware` checking `req.auth.get(User.self)?.role == .admin`.

| Section | What it does |
|---|---|
| Dashboard | Stat cards: total users, active Premium subscribers, rough MRR, events this week, group count |
| Users | Searchable/paginated table; view profile, comp or change plan, suspend/ban, view a user's events/groups, action pending deletion/export requests |
| Events | Searchable/filterable table; view, edit, cancel, delete, view attendees |
| Groups | Table; view, edit, **transfer ownership**, disband (cancels future events, notifies members) |
| Billing | Subscriptions, invoices, manual refund trigger, failed-payment queue |
| Data requests | Queue of pending `DeletionRequest`/`DataExportRequest` rows with an SLA countdown (§13) |
| Audit log | Read-only view of `AdminAuditLog` |

Every mutating admin action writes an audit row.

**Native admin client**: a Mac app (not iPad) for the team members who manage the platform day to day, distributed outside the App Store via Developer ID to keep it restricted to staff — this is an internal tool touching billing and PII, not a consumer product. It's a separate Xcode project from the consumer app (§16's `AdminMacApp/`), talking to the `/api/v1/admin` JSON namespace below and built against `ExpatEventsAdminAPI` (§5) rather than the consumer-facing package. The web admin (`/admin`, Leaf/htmx) stays as the always-available fallback — useful the moment a new admin action ships, before the Mac app has caught up.

## 13. Data protection & privacy (GDPR and similar)

ExpatEvents serves an inherently international, mobile-first audience, so build to GDPR's bar as the baseline — CCPA/CPRA (California), LGPD (Brazil), and similar regimes share most of the same mechanics, so meeting GDPR covers the others with only minor jurisdiction-specific differences.

**Lawful basis & consent**
- Account creation already requires accepting a Privacy Policy and Terms — carried forward, now recording *which version* of each was agreed to and *when* (`User.privacyPolicyVersion`, `termsVersion`, `consentedAt`). Re-prompt when either document changes materially.
- Core functional data (an event you host, who's attending) is processed under contract performance, not consent; consent is reserved for anything genuinely optional, like marketing email.
- With no non-essential (marketing/analytics) cookie or tracker, say so plainly in the privacy policy — that removes the need for a cookie-consent banner, since the login session cookie is "strictly necessary" and exempt.

**Data subject rights, built as real features**
- *Access & portability*: "Download my data" (§6, §7) produces a JSON/zip export of the user's own profile, events, group memberships, and chat messages via `DataExportRequest` — processed async, delivered as a signed, expiring link.
- *Rectification*: the existing profile-edit flow.
- *Erasure*: formalizes the current delete-account flow into a pipeline with a defined SLA (e.g. 30 days): hard-delete identifying fields, retain anonymized financial records (`Invoice` with the user reference nulled) as long as tax law requires, anonymize a deleted user's `ChatMessage`s (`displayName` → "Deleted user") rather than removing them outright.
- *Objection/restriction*: an admin can suspend processing (`isSuspended`) while a dispute is resolved.

**Data minimization & retention**
- Carry forward the current 30-day deletion of past/cancelled Free-tier events (and their chat) to all tiers, run by a periodic cleanup job.
- Define explicit retention windows for `AdminAuditLog` and `ChatMessage`.
- Collect only what each feature needs — location data exists for map display, not to build a location history.

**Cross-border transfer & subprocessors**
- Hosting in an EU region (§2) simplifies this considerably; still put Standard Contractual Clauses in place with each subprocessor (Stripe, email provider) and list them in the privacy policy.
- Passkeys and OAuth sign-in are a privacy win here too: no passwords to breach, and WebAuthn stores only a public key and signature counter (§4) — no biometric data ever leaves the device.

**Breach response**
- The 72-hour GDPR notification clock is an operational commitment; `AdminAuditLog` and standard request logging give the trail needed to scope an incident quickly. Worth a short incident-response runbook alongside the launch checklist.

**Minors**
- State a minimum age explicitly in the Terms (commonly 16 for GDPR consent, EU member states vary 13–16) rather than leaving it implicit.

## 14. Permissions matrix

| Capability | Anonymous | Free member | Premium member | Group moderator | Group owner | Admin |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Browse public events | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Join a public event | | ✓ | ✓ | ✓ | ✓ | ✓ |
| Follow another user | | ✓ | ✓ | ✓ | ✓ | ✓ |
| Host a public event | | ✓ (≤5) | ✓ (unlimited) | ✓ | ✓ | ✓ |
| Host a private event | | | ✓ | ✓ (as group) | ✓ (as group) | ✓ |
| Create a group | | | ✓ (one) | | | ✓ (any) |
| Create/manage events as a group | | | | ✓ | ✓ | ✓ |
| Promote a moderator | | | | | ✓ | ✓ |
| Transfer group ownership | | | | | (via admin) | ✓ |
| Edit/cancel any event | | | | | | ✓ |
| Comp or change any plan | | | | | | ✓ |
| Action a data request | | | | | | ✓ |
| View admin dashboard | | | | | | ✓ |

## 15. Frontend conventions

- **Tailwind**: compiled at build time via the Tailwind CLI. Content-scan paths cover `Resources/Views/**/*.leaf`; keep full class strings in templates rather than constructing them dynamically.
- **Flowbite**: vanilla-JS, data-attribute driven — dropdowns, modals, tabs, tooltips. Alpine covers anything Flowbite doesn't, or state reactive against form values.
- **htmx**: `hx-boost` for SPA-like nav without a router; `hx-target`/`hx-swap="outerHTML"` for component updates; `hx-swap-oob` for two-place updates; the `ws` extension for chat (§8).
- **Leaf layout**: a `base.leaf` shell extended by each page; a shared `partials/` directory holds fragments used by both full-page and htmx routes, chosen by checking the `HX-Request` header.
- **i18n**: needed only on the public web app (English/Spanish today, per the current `i18next` setup) — not the admin site, and not the API/backend. A small Leaf tag backed by JSON locale files (mirroring the current `src/locales/en|es/translate.json` key structure so content migrates directly) covers this; no dedicated i18n package needed.

## 16. Suggested project structure

```
expatevents/
  Packages/
    ExpatEventsAPI/             SPM package — shared DTOs, enums, realtime
      Package.swift              envelope, route helpers (§5)
      Sources/
        ExpatEventsAPI/
        ExpatEventsClient/       (optional) typed URLSession client

  Server/                        Vapor app
    Package.swift                depends on ../Packages/ExpatEventsAPI
    Sources/App/
      Models/                    User, OAuthIdentity, PasskeyCredential,
                                 Group, GroupMembership, Event, EventAttendee,
                                 ChatMessage, Follow, ActivityFeedItem,
                                 Subscription, Invoice, DeletionRequest,
                                 DataExportRequest, AdminAuditLog...
      Migrations/
      Controllers/
        Web/                     HomeController, EventController, ... (HTML/Leaf)
        API/                     Api/EventController, Api/GroupController, ... (JSON)
        Admin/                   Web/ (Leaf) and API/ (JSON, for AdminMacApp)
        StripeWebhookController.swift
      Middleware/                AdminMiddleware, PlanLimitsMiddleware,
                                 SessionAuthMiddleware, BearerTokenMiddleware
      Services/                  StripeService, PlanLimitsService,
                                 PasskeyService, OAuthService, DataRightsService
      WebSockets/                ChatRoomRegistry (actor), ChatSocketController
    Resources/Views/             layouts/, pages/, partials/, admin/   (Leaf)
    Public/                      compiled Tailwind CSS, htmx.min.js,
                                 alpine.min.js, flowbite.min.js, images
    tailwind.config.js

  AppleClients/                  Xcode project/workspace: iOS, iPadOS, macOS
                                 targets, depending on ExpatEventsAPI
                                 (+ ExpatEventsClient) as local Swift packages,
                                 with Associated Domains set for shared
                                 web/native passkeys
```

## 17. Launch approach

No automated Firebase migration: current usage will be transferred manually rather than built as a data pipeline, so there's no Firestore-export/UUID-mapping/ETL work in this plan. What that simplifies to:

1. Stand up the Postgres schema via Fluent migrations, matching §4, in a DigitalOcean-managed database in an EU region.
2. Launch the new schema fresh. If any existing accounts, events, or history are carried over by hand, enter them directly against the new Postgres schema rather than building a one-off import script for what's effectively a small, known dataset.
3. Existing users create a passkey or link Apple/Google on first sign-in, since there's no password to carry over either way.
4. Check the rebuilt screens against the six-screen design canvas for feature parity before launch.

## 18. WebAuthn library options

Two real candidates for the server-side WebAuthn/passkey ceremony:

| Library | Strengths | Watch out for |
|---|---|---|
| **[`swift-server/swift-webauthn`](https://github.com/swift-server/swift-webauthn)** (formerly `webauthn-swift`, originated by Brokenhands, now under the Swift Server ecosystem) | The library [Swift.org's own official server guide](https://www.swift.org/documentation/server/guides/passkeys.html) walks through step by step; framework-agnostic — wires directly into Vapor routes and our own Fluent models with no adapter layer; the larger and more active of the two (177+ stars, 172+ commits); Apache-2.0 | Still `1.0.0-alpha.2` — expect possible breaking API changes before a 1.0 release; it's *only* the WebAuthn ceremony (challenge generation/verification) — sessions, OAuth, and account linking are code we write ourselves, which this plan already scopes as `PasskeyService`/`OAuthService` (§16) regardless |
| **[`vapor-community/passage`](https://github.com/vapor-community/passage)** | A full identity framework, not just WebAuthn: bundles passkeys (via a companion `passage-webauthn` package), Sign in with Google/Apple/GitHub, magic links, JWT + refresh tokens, and *automatic account linking by verified email* — close to exactly our "one account, three sign-in methods" shape, and ships NIST-aligned login rate-limiting for free | Younger and much smaller (19 stars, 4 forks) than the base library it depends on; explicitly marked alpha with its own warning about breaking changes before a stable release; since its passkey support is itself built on `swift-server/swift-webauthn`, choosing Passage doesn't avoid that library's alpha status, it just wraps it |

**Recommendation**: build directly on `swift-server/swift-webauthn`. It's the path with an official Swift.org walkthrough and the larger community, and since this plan already scopes `PasskeyService`/`OAuthService` and the `User`/`OAuthIdentity`/`PasskeyCredential` schema (§4, §16) as our own code rather than inheriting a framework's, Passage's main selling point — bundling all of that — matters less starting from zero than it would retrofitting an existing app. Worth a second look if Passage reaches a stable release later and there's an appetite to hand off more of that plumbing.

On the native client side, no third-party library is needed at all: since every native surface is Apple-only (the consumer iOS/iPadOS/macOS app and the admin Mac app), `AuthenticationServices`' `ASAuthorizationPlatformPublicKeyCredentialProvider` handles the passkey ceremony natively, synced via iCloud Keychain — the right choice regardless of which server-side library wins above.

One concrete to-do this unblocks: hosting `/.well-known/apple-app-site-association` (with a `webcredentials` entry for the app's Team ID + bundle identifiers) at `https://expatevents.net/`, so passkeys created on the web are usable from the native apps and vice versa.
