# Design audit: what's built vs. the design

First audited 2026-10-25 against `main` at the PR #8 merge (after M9); **re-audited 2026-10-31 against `main` at the PR #14 merge (after M10)**, see §0. The first audit Compares every screen against the design canvas's six artboards (`Main`, `Events`, `EventDetail`, `Groups`, `GroupEventForm`, `Account`, extracted directly from the canvas source, not from memory) and against the component patterns in `docs/design-system.md`. Design-visible gaps in behavior are included too, for example a form field the artboard shows but the website can't submit.

**Update (event-basics PR, after this audit)**: the three behavior gaps found here are fixed. Event dates now show on the events list, event page, group page and profile; the create form works again (its date field was failing every submission) and has Host as, Public/Private and an attendee limit, with readable errors; and `/events` has "Load more events". The rows below are marked accordingly. Everything else in this audit is still open.

Status key: ✅ built to the design · 🟡 partly built · ❌ not built (the page works but is still plain Tailwind, or the element is missing).

## 0. Re-audit after M10, and the plan for the theme work

**What changed since the first audit**: the event-basics PR (#10) fixed the three behavior gaps; the location PR (#13) added city/venue autocomplete, coordinates and per-event time zones; M10 (#14) built the admin site with its own theme (dark sidebar, Tailwind, server-drawn charts), chosen by the user from a mockup since the canvas has no admin artboard. **No public page's look changed**: every page except Home, Account, Feed, Profile, Feedback and the legal pages is still plain Tailwind under the plain white nav, exactly as in §1. Re-checked page by page against the canvas source (`Events`, `EventDetail`, `Groups`, `GroupEventForm`, `Account`); the §1 tables still hold, with the updates marked there.

**New since the first audit (2026-10-31)**:

- **The user supplied the real assets** (logo mark, default avatar, and one photo per category: culture, drinks, film, food, music, travel) and confirmed they're cleared for the live site. They replace the design tool's placeholder copies in `Server/Public/design/` (the new photos are larger, about 1,275×546 against the old 700×300; the default avatar is 450×450 against 160×160). This closes the "placeholder images aren't licensed" launch concern in §2.
- **Profile photos are a new requirement**: a member's photo can be their Google photo, a Gravatar matching their email, or one they upload, falling back to the default avatar. Default order (user's decision): **Google photo, then Gravatar (if one exists), then uploaded, then the default**; on `/account` they can pick any one that's available. **Sign in with Apple never provides a photo** (only name and email), so Apple-only members get Gravatar, an upload or the default. Uploads are stored on local disk in development behind a small storage interface, with DigitalOcean Spaces plugged in at M13 (user's decision).
- **What exists today for photos**: `User.photoURL` is in the model and every DTO that shows a person (attendees, chat, feed, follows, profile, account), and Account/Feed/Profile already fall back to the placeholder avatar. But nothing ever sets it at sign-in (Google's `picture` claim is ignored), there's no Gravatar, no upload and no choice. The dev seed sets `randomuser.me` URLs, which are third-party photos of real people and should become the default avatar or Gravatar instead.
- **Admin site**: has its own theme now (§4, M10). Its sidebar logo is a text "EE" badge and should use the real logo mark too.

**Decisions for the theme work** (resolving open questions from §2):

- **Tailwind stays on the CDN for now**, with the canvas tokens added to `tailwind.config` (colors, radius, shadow, Outfit font) in the shared layout, as the admin layout already does; the compiled Tailwind build moves to M13, when there's a build step anyway.
- **Icons stay inlined** (Leaf's `#` makes a `<use href="#icon">` sprite error-prone); a few shared icon partials can cut repetition.
- **The nav's account dropdown uses Alpine** (already loaded on every page), not Flowbite, so no new library is added for one menu.
- **Category photos** show on event cards, the event-detail hero and the create form's category picker. The canvas's category chips leave out **Film**; the restyle includes all six.

**The theme work, in order (user's decision: one PR per area)**:

| # | PR | Covers |
|---|---|---|
| 1 | Foundation | New assets in `Public/design/`; Tailwind config with the tokens and Outfit; the gradient **app nav** (logo + wordmark, pill links with an active state, "+ Create Event", user pill with avatar and an account dropdown, Sign in for visitors, a phone menu); footer; the shared button/badge/card/form styles; real logo in the admin sidebar; one avatar helper used everywhere a person is shown |
| 2 | Profile photos | Save the Google photo at sign-in; Gravatar lookup; upload (JPEG/PNG/WebP, 2 MB, checked by content) with local storage; the photo choice on `/account`; erasure removes uploads; the seed stops using third-party photos |
| 3 | Events | Header with the live indicator; All / Going / Hosting tabs (Going needs a new filter); city and venue search; category chips with photos (all six); date picker; event cards with photo, badges, host avatar, description, attendee avatars and inline Join; restyled Load more |
| 4 | Event detail | Breadcrumb; photo hero; action bar with host avatar and Join/Going toggle; info panel with the **map** (Google in dev, per the mapping plan); chat with bubbles, avatars, timestamps, connection indicator and a Reply button; attendee sidebar with Host/You tags |
| 5 | Create event | Host-as chips; category picker with photos; restyled date and place fields (with the screen-reader fixes from the location PR); Public/Private cards; limit switch + stepper; live preview card. Drafts, recurring events and editing stay out unless asked for |
| 6 | Groups | Directory and detail restyled toward the split view: search, avatars, gradient cover, moderator row, styled tabs, the ownership policy box, member rows with role badges; group create form |
| 7 | Feed, Profile, Account, Sign in | Feed and Profile with real avatars; the Account profile section redone (the M9 follow-up); Sign in restyled |


## Summary

| Screen | Artboard | Status |
|---|---|---|
| Home (`/`) | `Main.dc.html` | ✅ built in M7, with a few deliberate changes |
| Account (`/account`) | `Account.dc.html` | 🟡 built in M9; the billing parts wait on M8; profile section to be redone |
| Events (`/events`) | `Events.dc.html` | ❌ plain Tailwind; most of the artboard's features missing |
| Event detail (`/events/:id`) | `EventDetail.dc.html` | ❌ plain Tailwind; works, but missing most of the layout |
| Groups (`/groups`, `/groups/:slug`) | `Groups.dc.html` | ❌ plain Tailwind; different layout from the artboard |
| Create event (`/events/new`) | `GroupEventForm.dc.html` | ❌ plain Tailwind; works and has its key fields since the event-basics PR, but none of the artboard's layout |
| Feed, Profile, Feedback, Privacy, Terms | no artboard | Styled with the design tokens (extrapolated) |
| Sign in, group create form | no artboard | ❌ plain Tailwind |
| App-wide nav (every page but Home and the admin site) | all artboards | ❌ plain white Tailwind bar, not the design's nav |
| Admin site (`/admin`) | none (mockup chosen by the user in M10) | ✅ own theme, built in M10 |

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
| Event card: category photo + badge, title, "Group event" tag, host avatar, date and place, description, attendee avatars, inline Join / Going button | 🟡 shows title, category text, **date** (fixed), city, host name and attendee count; no photo, no description, no inline join |
| "Load more events" | 🟡 **fixed** as a plain "Load more events" button (htmx, keeps the current filters); restyle pending |
| htmx filter and load-more endpoints (architecture §6: `POST /events/filter`, `GET /events?page=N`) | 🟡 the load-more half is built (`GET /events?page=N` with `HX-Request` returns just the next cards); the filter endpoint isn't |

### Event detail: `EventDetail.dc.html` (❌)

| Artboard element | Today |
|---|---|
| Breadcrumb ("Events › title") | ❌ |
| Hero banner: category photo, "Hosted by a group" tag, title, date, place | ❌ plain heading; the full date is now shown under it (fixed) |
| Action bar: host avatar + name, Join / "Going ✓" toggle | 🟡 Join/Leave works over htmx but is plain; no avatar |
| Info panel: description, full date, venue with "Show map" | 🟡 description, venue and the full date (shown in the event's own time zone), as plain text; **no map** yet, though new events now have real coordinates (location PR) |
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
| "Host as" chips: Myself or one of your groups | 🟡 **fixed** as a plain "Host as" dropdown (Myself plus every group you own or moderate); the design's chips are the restyle |
| Category picker with photos | 🟡 a plain dropdown |
| Date & time, venue | 🟡 plain date input; city and venue now have live autocomplete with coordinates and a time zone (location PR), still plain styling |
| Visibility: Public / Private cards | 🟡 **fixed** as plain Public/Private radio buttons; the design's cards are the restyle |
| "Limit attendees" switch + stepper | 🟡 **fixed** as a plain number field; the create request now carries `attendeeLimit`, capped by plan (5 for a Free host, 100 otherwise). The switch + stepper is the restyle |
| "Recurring event" switch | ❌ not on the form (in scope only as a flag) |
| "Save as draft" | ❌ no drafts in the data model |
| Live preview card | ❌ |
| Edit an existing event (`/events/:id/edit`, architecture §6) | ❌ not built |
| Friendly error when a plan limit blocks creation | 🟡 **fixed** (plain styling): the form re-renders with the reason and everything you typed |

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
| **Avatars and photos** | ❌ no page ever shows a real member photo: sign-in doesn't save the provider's profile picture, and there's no Gravatar or upload (the DigitalOcean Spaces bucket from the architecture isn't wired up). Only seeded accounts show photos (`randomuser.me`). Planned in §0 (PR 2) |
| **Placeholder images** (`Public/design/`) | ✅ resolved 2026-10-31: the user supplied the real, cleared logo, default avatar and category photos; they replace the placeholders in the foundation PR (§0) |

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
| M10 | Admin site: built (web only; the `/api/v1/admin` JSON surface moved to M11), with its own theme picked from a mockup. Billing is a placeholder until M8. Follow-ups from its reviews: per-row count queries, calendar-aligned chart buckets, focus trapping in the transfer dialog, and `HttpOnly`/`Secure` session cookies at M13 |
| M11 | JSON API: no account, billing or admin endpoints yet |
| M12 | i18n: not started |
| M13 | Deployment: not started |
| Build | `WARNINGS.md` row #2 (deprecated Postgres config call) still open |
| Cleanup | `partials/chat-message.leaf` is unused and can be deleted |
