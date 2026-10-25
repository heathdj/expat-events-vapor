# Design audit: what's built vs. the design (after M9)

Audited 2026-10-25 against `main` at the PR #8 merge. Compares every screen against the design canvas's six artboards (`Main`, `Events`, `EventDetail`, `Groups`, `GroupEventForm`, `Account`, extracted directly from the canvas source, not from memory) and against the component patterns in `docs/design-system.md`. Design-visible gaps in behavior are included too, for example a form field the artboard shows but the website can't submit.

Status key: ✅ built to the design · 🟡 partly built · ❌ not built (the page works but is still plain Tailwind, or the element is missing).

## Summary

| Screen | Artboard | Status |
|---|---|---|
| Home (`/`) | `Main.dc.html` | ✅ built in M7, with a few deliberate changes |
| Account (`/account`) | `Account.dc.html` | 🟡 built in M9; the billing parts wait on M8; profile section to be redone |
| Events (`/events`) | `Events.dc.html` | ❌ plain Tailwind; most of the artboard's features missing |
| Event detail (`/events/:id`) | `EventDetail.dc.html` | ❌ plain Tailwind; works, but missing most of the layout |
| Groups (`/groups`, `/groups/:slug`) | `Groups.dc.html` | ❌ plain Tailwind; different layout from the artboard |
| Create event (`/events/new`) | `GroupEventForm.dc.html` | ❌ plain Tailwind; several fields can't be set from the website |
| Feed, Profile, Feedback, Privacy, Terms | no artboard | Styled with the design tokens (extrapolated) |
| Sign in, group create form | no artboard | ❌ plain Tailwind |
| App-wide nav (every page but Home) | all artboards | ❌ plain white Tailwind bar, not the design's nav |

The single biggest visual gap is the **app nav**: every artboard has the same gradient nav, and no page except Home uses it.

## 1. Screen by screen

### Home: `Main.dc.html` (✅, M7)

Every section on the artboard is built (hero, value props, how-it-works, pricing, groups explainer, footer), using the canvas's own CSS (`Public/css/home.css`). Deliberate differences, all recorded in `MILESTONES.md`:

- No "Register" button in the nav; it comes back with M3 (passkeys), which adds a real registration flow.
- "Get Started" goes to `/events`, not sign-in.
- Pricing buttons say "Get started free" / "Sign in to upgrade" instead of "Current plan" / "Upgrade to Premium" (no billing yet).
- The fake "212 events live now" badge shows the real event count.
- The sample group card is kept but labeled "Sample group shown for illustration".
- Icons are inlined rather than shared through one sprite (see §2).

### Account: `Account.dc.html` (🟡, M9)

| Element | Status |
|---|---|
| Profile card: avatar, name, email, member since, plan pill | ✅ (**to be redone**: user follow-up, the profile section doesn't feel in line with the site yet) |
| "Edit profile" | 🟡 edits the display name only; no photo upload |
| Free / Premium plan cards with "Current plan" tag | ✅ |
| Monthly / yearly toggle, Upgrade / Cancel subscription buttons | ❌ deferred to M8 (billing) |
| Payment method row | ❌ deferred to M8 |
| Billing history table | ❌ deferred to M8 |
| "Your data" card (download / delete) | built, but not on the artboard (extrapolated) |

### Events: `Events.dc.html` (❌)

| Artboard element | Today |
|---|---|
| "Discover events" header with a live "updated just now" indicator | ❌ just "Upcoming events" |
| Filter tabs: All / Going / Hosting | ❌ missing. "Going" also has no backend filter yet (the filter query has no attendee field) |
| City and venue search inputs | ❌ no UI. Filtering works if you type it into the URL (`?city=…&venue=…`), M4 criterion #4 |
| Category chips | ❌ no UI (same: works via `?category=`). The artboard's chips leave out **Film**, one of the six categories, so the design needs fixing too |
| Mini calendar date picker | ❌ no UI (backend supports `?onOrAfterDate=`) |
| Event card: category photo + badge, title, "Group event" tag, host avatar, date and place, description, attendee avatars, inline Join / Going button | 🟡 shows title, category text, city, host name and attendee count. **No date shown at all**, no photo, no description, no inline join |
| "Load more events" | ❌ missing. The backend pages at 20 events, and nothing on the page links to the next page; the 21st event onward is only reachable by typing `?page=2` |
| htmx filter and load-more endpoints (architecture §6: `POST /events/filter`, `GET /events?page=N`) | ❌ not built |

### Event detail: `EventDetail.dc.html` (❌)

| Artboard element | Today |
|---|---|
| Breadcrumb ("Events › title") | ❌ |
| Hero banner: category photo, "Hosted by a group" tag, title, date, place | ❌ plain heading. **The event's date and time aren't shown anywhere on the page** |
| Action bar: host avatar + name, Join / "Going ✓" toggle | 🟡 Join/Leave works over htmx but is plain; no avatar |
| Info panel: description, full date, venue with "Show map" | 🟡 description and venue as plain text; **no map** (venue latitude/longitude are always 0, see the event form) |
| Live chat card: "Connected" pulse, avatars, timestamps, your-messages-vs-others' bubbles, "Reply" link | 🟡 live chat works (M5) but is plain: no avatars, no timestamps, no bubbles, and **no way to reply from the UI** (replies work server-side; M5 scope trim) |
| Sidebar: "N people going", attendees with avatars, Host and You tags | 🟡 a plain attendee list with a count |

### Groups: `Groups.dc.html` (❌)

The artboard is one split-view page: a searchable list of groups on the left and the selected group's detail on the right. What's built is a separate directory page and detail page (`/groups`, `/groups/:slug`), both plain Tailwind.

| Artboard element | Today |
|---|---|
| Header "Groups" + description + "+ Create group" button | 🟡 heading + "Start a group" link |
| Search groups | ❌ |
| Group list items with avatar, visibility, member count, tagline | 🟡 name, description, member count, owner; no avatar |
| Detail: gradient cover, group avatar, Join button, visibility, member count | 🟡 Join/Leave works; no cover, no avatar (the `Group` model has `avatarURL`/`coverURL` but nothing can set them) |
| Moderator avatar row ("3 moderators") | ❌ |
| Tabs: Upcoming events / About / Members | ✅ functionally (M6), plain styling |
| "How group ownership works" policy box on About | ❌ |
| Member rows with avatar and "Moderator" tag | 🟡 the role is shown as raw text; promote/demote controls are built (not on the artboard) |

### Create event: `GroupEventForm.dc.html` (❌)

This is where the most behavior is missing, not just styling.

| Artboard element | Today |
|---|---|
| "Host as" chips: Myself or one of your groups | ❌ **The website can't create a group-hosted event.** The web form always hosts as yourself; group events can only be made through the API (the server-side permission checks exist, M6) |
| Category picker with photos | 🟡 a plain dropdown |
| Date & time, venue | 🟡 plain inputs; no city/venue autocomplete, so latitude/longitude are saved as 0 (tracked since M4) |
| Visibility: Public / Private cards | ❌ **Not on the form**, so every web-created event is public. Premium users can't make a private event from the website, even though the server allows it |
| "Limit attendees" switch + stepper | ❌ not on the form, and the create request has no attendee-limit field at all (the model does) |
| "Recurring event" switch | ❌ not on the form (in scope only as a flag) |
| "Save as draft" | ❌ no drafts in the data model |
| Live preview card | ❌ |
| Edit an existing event (`/events/:id/edit`, architecture §6) | ❌ not built |
| Friendly error when a plan limit blocks creation | ❌ the form re-renders with no message (tracked since M4) |

## 2. Design-system patterns across the app (`docs/design-system.md`)

| Pattern | Status |
|---|---|
| **Nav**: gradient bar, pill links with an active state, "+ Create Event" button, user pill (avatar + name) opening an account dropdown | ❌ only on Home. Every other page has the plain white nav from `layouts/base.leaf` |
| **Tailwind build with the tokens in `tailwind.config.js`** | ❌ Tailwind still loads from a CDN, and the tokens are copied by hand into two files (`home.css`, `design-tokens.css`) |
| **Shared icon sprite** (`partials/icon-sprite.leaf`) | ❌ deliberately not built: the sprite's `href="#icon"` references collide with Leaf's `#` syntax, so icons are inlined. Needs a decision: escape them in a sprite, or keep inlining |
| **Flowbite** (for the account dropdown) | ❌ not loaded anywhere |
| Buttons, cards, badges | 🟡 the classes exist (`design-tokens.css`) and are used on Feed, Profile, Account, Feedback and the legal pages; not yet on Events or Groups |
| Gold "Group event" / "Host" / "Moderator" badges; accent "You" badges | ❌ not used anywhere yet |
| Live / realtime indicator | 🟡 only on the home hero; not on Events or chat |
| Forms (inputs, focus ring, toggle switches) | 🟡 inputs built (M9) and used on Feedback and Account; event and group forms still plain; no toggle switches |
| Chat bubbles | ❌ |
| Responsive single-column collapse | 🟡 Home and Account have it; other pages rely on Tailwind defaults |
| **Avatars and photos** | ❌ no page ever shows a real photo: sign-in doesn't save the provider's profile picture, and there's no upload (the DigitalOcean Spaces bucket from the architecture isn't wired up). Everything shows the placeholder avatar |
| **Placeholder images** (`Public/design/`) | ⚠️ these are the design tool's sample photos, not licensed. `design-system.md` says they're flagged in `WARNINGS.md`, **but they aren't**: they need adding to the launch blockers |

## 3. Pages with no artboard

Styled with the design tokens, but every choice was extrapolated: Feed, Profile, Feedback, Privacy, Terms. Still plain Tailwind: Sign in, the group create form. The Profile page has Hosted events / Followers / Following tabs; the architecture (§6) also lists an **About** tab, which doesn't exist because users have no bio field yet (the old app had one). Worth asking for artboards for Sign in, Feed and Profile before restyling them further.

## 4. Other deferred or not-done items (already tracked in `MILESTONES.md`)

Not design items, listed here so the audit is complete in one place.

| From | Item |
|---|---|
| M2 | Sign in with Apple, live verification → M13 (needs the real domain). After signing in you land on `/feed`, not back on the page you came from |
| M3 | Passkeys and a real `/register` page: not started (stretch milestone) |
| M4 / M6 | Website errors such as "private event not found" show a generic 500 page instead of a 404 or a friendly message |
| M5 | Exactly what a client sees when a chat connection is refused is unverified; a message sent in the second before your chat connects only appears after a reload |
| M6 | No "request to join" for invite-only groups (Phase 2) |
| M7 | No notifications for new follows or feed items |
| M8 | Billing: skipped for now. When built, also erase Stripe data on account deletion, and finish the Account page |
| M9 | **Launch blocker**: real Privacy Policy and Terms wording. No re-consent prompt when they change. `process-deletions` and `retention-cleanup` aren't scheduled. A deleted user who owns a group stays its owner |
| M10 | Admin site: not started (it should also process deletion requests and transfer group ownership) |
| M11 | JSON API: no account, billing or admin endpoints yet |
| M12 | i18n: not started |
| M13 | Deployment: not started |
| Build | `WARNINGS.md` row #2 (deprecated Postgres config call) still open |
| Cleanup | `partials/chat-message.leaf` is unused and can be deleted |
