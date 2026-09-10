# ExpatEvents design system

Source: the "companion design canvas" referenced in `expatevents-vapor-architecture.md` (§17 step 4) — a six-artboard Claude Design canvas at `https://claude.ai/code/artifact/ead44890-d812-48b6-8819-3cc4f51e70be`, extracted and documented here on 2026-09-09 so the actual token values, screen layouts, and asset files are durable project artifacts rather than living only in a link. See `MILESTONES.md`'s design milestone(s) for how this gets applied page by page.

This is a reference doc, not a build target in itself — it exists so anyone (human or agent) implementing a page's styling can work from exact values instead of guessing from a screenshot.

## The six screens

| Canvas file | Canvas title | Maps to |
|---|---|---|
| `Main.dc.html` | Home | New public marketing landing page (`/`) — doesn't exist yet, being added |
| `Events.dc.html` | Events | `/events` dashboard (M4, built) |
| `EventDetail.dc.html` | Event detail | `/events/:id` (M4, built — chat panel itself is M5) |
| `Groups.dc.html` | Groups | Group directory/detail (M6, not yet built) |
| `GroupEventForm.dc.html` | Create group event | `/events/new` (M4, built; group-hosting picker is M6) |
| `Account.dc.html` | Account & billing | Account/billing pages (M8/M9, not yet built) |

## Design tokens

All six screens share one `:root` token set (verbatim from the canvas CSS):

```css
:root {
  /* surfaces */
  --bg: oklch(98% 0.004 250);          /* page background, warm off-white */
  --surface: #ffffff;                   /* card background */
  --surface-2: oklch(96.5% 0.006 255);  /* recessed/input background */

  /* ink (text) */
  --ink: oklch(23% 0.03 264);           /* primary text, navy-tinted near-black */
  --ink-soft: oklch(46% 0.02 264);      /* secondary text */
  --ink-faint: oklch(62% 0.014 264);    /* tertiary/meta text */
  --line: oklch(90% 0.008 264);         /* hairline borders */

  /* brand */
  --brand-1: #182a73;                   /* deep navy */
  --brand-2: #218aae;                   /* mid blue */
  --brand-3: #20a7ac;                   /* teal */
  --brand-gradient: linear-gradient(135deg, var(--brand-1) 0%, var(--brand-2) 69%, var(--brand-3) 89%);

  /* accent (interactive) */
  --accent: oklch(58% 0.11 195);        /* teal-cyan — primary buttons, links, focus */
  --accent-soft: oklch(94% 0.03 195);   /* accent-tinted background (chips, "going" state) */

  /* status / semantic */
  --gold: oklch(75% 0.14 70);           /* group-hosted / host badges */
  --gold-soft: oklch(95% 0.03 70);
  --green: oklch(70% 0.17 145);         /* live/realtime indicator dots */
  --green-soft: oklch(95% 0.03 145);    /* paid/success (Account screen only) */
  --danger: oklch(58% 0.18 25);         /* Home screen only; not used elsewhere yet */
  --danger-soft: oklch(95% 0.03 25);

  /* shape */
  --r-sm: 10px;   /* inputs, small chips */
  --r-md: 16px;   /* cards */
  --r-lg: 22px;   /* hero banners, large images */

  /* elevation */
  --shadow-sm: 0 1px 2px rgba(20,30,60,.07), 0 1px 1px rgba(20,30,60,.04);
  --shadow-md: 0 10px 30px -8px rgba(20,30,60,.18);

  /* type */
  --font-display: 'Outfit', system-ui, -apple-system, sans-serif;
  --font-body: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, 'Fira Sans', 'Droid Sans', 'Helvetica Neue', sans-serif;
}
```

`Outfit` is loaded from Google Fonts (`family=Outfit:wght@400;500;600;700;800`) — used for every heading (`h1`–`h4`) and a handful of display numbers (prices, step numbers). Body text, buttons, and inputs use the system font stack. Base body size is `15px` / `line-height:1.55`.

**Tailwind mapping**: these become `theme.extend.colors`/`borderRadius`/`boxShadow`/`fontFamily` entries in `tailwind.config.js` (architecture §15 already calls for the Tailwind CLI build over the current CDN load — this is what it should encode). Tailwind doesn't parse `oklch()` in arbitrary-value form as cleanly as hex in older versions; keep the CSS custom properties above defined in the compiled stylesheet's `@layer base` and reference them from Tailwind config as `'bg-app': 'var(--bg)'` etc., rather than hand-converting every oklch value to hex — that keeps this file the single source of truth and avoids transcription drift.

## Component patterns (consistent across all six screens)

- **Nav**: sticky top, `--brand-gradient` background, `--shadow-sm`. Brand mark (logo + wordmark) left, nav links center (pill-shaped, `.active` gets `rgba(255,255,255,.16)` background), actions right. Signed-out: ghost "Log in" + solid-light "Register". Signed-in: solid-light "+ Create Event" button + a rounded "user pill" (avatar + name + chevron, `rgba(255,255,255,.12)` background) that opens an account dropdown (Flowbite dropdown — the one clear use for the "component layer" architecture §1/§15 calls out Flowbite for).
- **Buttons**: always pill-shaped (`border-radius:999px`). Variants: `btn-accent` (solid `--accent`, primary action), `btn-solid-light` (white bg, navy text, for use on the gradient nav/hero), `btn-outline` (transparent, `--line` border), `btn-ghost` (transparent, white text, nav-only), `btn-going`/`btn-accent` toggle pair for join-state buttons (soft-accent background once joined, matching htmx's swap-in-place fragment from M4). A `btn-sm` modifier tightens padding for inline/nav use.
- **Cards**: white surface, `--r-md` (16px) radius, 1px `--line` border, `--shadow-sm`. Cards with a cover image (group preview, group detail) use a `--brand-gradient` cover strip with the avatar overlapping via negative margin.
- **Badges/tags**: pill-shaped, small (11–12px), semibold. Gold variant marks anything group-hosted (a small crown icon + "Group event" / "Host" / "Moderator"); accent-soft variant marks "You" / category chips.
- **Live/realtime indicator**: a small dot (`--green`, with a soft `box-shadow` ring matching its own color at low opacity) paired with "Live" or "Connected" text — used on the Events page header and the Event detail chat header. This is the visual cue M5's WebSocket chat should reuse for its own connection-status indicator.
- **Forms**: inputs/textareas are `--r-sm` (10px) radius, 1.5px `--line` border, `--surface-2` background, with a 2px `--accent-soft` outline + `--accent` border on focus. Toggle switches are pill-shaped sliders (`--line` off / `--accent` on).
- **Chat bubbles** (Event detail): own messages right-aligned with `--accent-soft` bubble background; others' messages left-aligned with `--surface-2` background. Each message shows a 34px round avatar, name + relative timestamp, and a "Reply" affordance.
- **Icons**: a single inline `<svg><symbol>` sprite per page (stroke-based, `stroke-width:1.8`, round caps/joins, `currentColor`) — calendar, pin, users, globe, check, arrow-right, search, crown, lock, chevron-down, info, send, card, bolt. No icon font/library dependency; this sprite should become one shared Leaf partial (`partials/icon-sprite.leaf`) included once in the base layout rather than duplicated per page.
- **Responsive**: every screen collapses its two-column layout (sidebar+content, or content+preview) to a single column under ~900–980px; the marketing Home page hides its hero illustration entirely below 980px rather than reflowing it.

## Assets

Extracted from the canvas and committed to `Server/Public/design/`:

- `logo.png` — the ExpatEvents mark used in the nav brand lockup (128×128, transparent).
- `avatar-placeholder.png` — generic user avatar (160×160) used everywhere a real profile photo isn't available yet.
- `categories/{culture,travel,food,music,drinks,film}.jpg` — one placeholder photo per `EventCategory` case, used as event-card thumbnails, category picker images on the create-event form, and a couple of group-cover images in the canvas mockup.

**These are the design tool's own sample/placeholder images, not licensed production assets.** They're fine for development, staging, and the server-checkpoint reviews, but flagged in `WARNINGS.md` as needing real, rights-cleared photography (or a different placeholder strategy, e.g. solid category-color tiles) before production launch — this should not silently become the real launch asset set.

## Known gaps between the canvas and the actual data model

Noted here so implementers don't quietly invent behavior the canvas's static mockup doesn't actually specify:

- The canvas's event/group data is all inline sample data in each artboard's own `Component` class (see `renderVals()` in each `.dc.html`) — none of it reflects real `EventService`/`GroupService` output. Treat the canvas strictly as a visual/layout reference, never as a data or behavior spec.
- Event detail's live chat UI (message list, compose box, connection pulse) is fully designed but has no backend yet — M5 builds the actual WebSocket wiring; this doc's chat-bubble pattern above is what M5's UI should target.
- The create-event form's "Host as" chip row assumes the user already belongs to one or more groups; M4's existing form only supports self-hosting today (group hosting arrives with M6) — the chip row's "Myself"-only state is what M4's restyle should ship, with the other chips appearing once M6 lands.
- Account & billing's plan/cycle toggle and billing history table are Stripe-shaped but contain zero real Stripe integration — M8 supplies that; this doc's styling should be applied to M8's real pages when built, not stubbed in ahead of the data.
