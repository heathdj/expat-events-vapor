# Choosing a mapping provider: decision plan

## Decision (2026-10-25)

Made by the user after checking the open questions directly with Apple:

- **Apple allows storing coordinates**, so the storage question that made Apple "unclear" in §2 is resolved in its favour.
- **MapKit JS has no time zone** for a place. The usual approach is a coordinates-to-time-zone library, and we'll use [`tzf-swift`](https://github.com/ringsaturn/tzf-swift) (MIT library; its bundled boundary data is ODbL, so it needs an OpenStreetMap credit; no network calls, no network calls, builds on Linux).
- **Development uses Google** (already set up). Whether to switch to Apple is decided before launch (M13). Google's terms only allow keeping coordinates for 30 days and forbid showing its place results on a non-Google map, so launching on Google would also mean a coordinate refresh job (§6, option b). That's one more point in Apple's favour at that decision.
- **Everything sits behind a provider-neutral package**, so switching is a configuration change plus one adapter: a place-search provider protocol (autocomplete and place lookup) and a time-zone resolver protocol, with `tzf-swift` filling in the time zone whenever the provider doesn't return one (Google's Place Details doesn't in its cheapest tier, Apple doesn't at all).

The spike in §4 is no longer needed to choose; its city/venue test list remains useful as a quality check when the Apple adapter is written.


Drafted 2026-10-25. Goal: pick one mapping and places provider (or a deliberate mix) for local development and for production, with evidence rather than habit. This is a plan to *make* the decision. It ends in a short spike and a scored comparison, not a pre-made answer.

## 1. What the app needs maps for

Taken from the codebase, the design canvas and the tracked gaps.

| # | Need | Where it shows up today | Must have for MVP? |
|---|---|---|---|
| R1 | **Place autocomplete** for city and venue on the create-event form | Architecture §15; the legacy app's `MyPlaceInput.jsx` (Google `react-places-autocomplete`); city/venue lat/lng are still hard-coded to 0 | Yes |
| R2 | **Store coordinates** (and a formatted address) for each event's city and venue | `Event.cityLat/cityLng/venueLat/venueLng` columns already exist | Yes |
| R3 | **Time zone** for each event, from its location | The known limitation from the event-basics PR: dates are stored as wall-clock time because events have no time zone | Yes, it fixes a tracked bug |
| R4 | **Map on the event page** ("Show map" on the EventDetail artboard) | Not built | Yes, for the design restyle |
| R5 | Venue filter / "events near me" later | Filtering is by city text today | Later |
| R6 | **Native iOS app** later, sharing the same location data | Architecture scope; native app deferred to Phase 2 | Later, but affects the choice |

Non-functional requirements:

- **N1 Storage rights.** We keep coordinates (and want to keep time zones) in our own database permanently. Whatever we choose must allow that, or we must design around it (store an ID and refresh).
- **N2 Privacy.** EU hosting (DigitalOcean Frankfurt), a privacy policy that promises no non-essential cookies or trackers (architecture §13), GDPR processor terms.
- **N3 Cost** at our scale, predictable, with no surprise bills.
- **N4 Dev ergonomics.** Works on `localhost` (Sign in with Apple doesn't, so that matters), keys kept out of the repo, and tests that don't call a live API.
- **N5 Data quality** for venues worldwide: cafés, bars and parks in the cities expats move to, not just street addresses.

## 2. The candidates

Prices and limits checked 2026-10-25 against each provider's own pricing pages (linked in §7). Rows marked "verify" couldn't be confirmed from primary sources yet and are part of the spike.

| | **A. Google Maps Platform** | **B. Apple (MapKit JS + Maps Server API)** | **C. Open-data stack** (MapLibre/Leaflet + MapTiler or Stadia tiles + Geoapify or OpenCage geocoding) | **D. Mapbox** |
|---|---|---|---|---|
| Autocomplete (R1) | Places Autocomplete: 10,000 requests/month free, then $2.83/1,000; session usage free | `mapkit.Search` autocomplete in the browser, or `/v1/searchAutocomplete` server-side | Geoapify Address Autocomplete (cities and "amenity" venues), 1 credit per request; OpenCage's autosuggest is cities/regions only | Search Box API: 500 sessions/month free (preview pricing), then $3/1,000 |
| Coordinates (R2) | Place Details Essentials: 10,000/month free, then $5/1,000 | Included in the shared quota | Included | Included |
| **Storing coordinates (N1)** | ❌ **Only 30 days**: lat/lng may be cached "for up to 30 consecutive calendar days", then must be deleted; `place_id` may be kept | ⚠️ **Unclear**: MapKit JS terms say map data "may not be cached, pre-fetched, or stored … other than on a temporary and limited basis"; Apple has never clarified whether coordinates count. Apple's persistent Place IDs are designed to be stored (verify) | ✅ OpenCage explicitly allows storing results permanently, even after you stop paying. Geoapify: verify | ⚠️ Only via the **Permanent Geocoding API**, which has no free tier ($5/1,000); Search Box results can't be stored |
| Time zone (R3) | Separate Time Zone API: 10,000/month free, then $5/1,000 | Verify whether the Server API's `Place` includes a time zone (native MapKit's map item has one) | ✅ Geoapify results include a `timezone` object | Verify |
| Map display (R4) | Dynamic Maps: 10,000 loads/month free, then $7/1,000; Embed is free and unlimited | 250,000 map views/day free | MapTiler: free plan is for non-commercial use (5,000 sessions/month); Flex is $30/month for 25,000. Stadia and OpenFreeMap are alternatives (verify) | GL JS: 50,000 loads/month free, then $5/1,000 |
| Mixing rule | **Places and Geocoding content may not be used with a non-Google map** | Apple map with Apple data | Any mix | Mapbox map recommended |
| Native iOS later (R6) | Google Maps SDK for iOS (billable) | Native MapKit, free on device | MapLibre Native or MapKit for display | Mapbox Maps SDK (billable) |
| Account and cost | Billing account and card required, even within the free caps | Needs the Apple Developer Program membership the project already needs for Sign in with Apple; 25,000 service calls/day per team (shared between MapKit JS and the Server API); above that, HTTP 429 until you ask Apple for more | Geoapify: 3,000 credits/day free, commercial use allowed with attribution; $59/month for 10,000/day. OpenCage: free trial is testing only (2,500/day); $50/month for 10,000/day | Card required for paid tiers |
| Privacy (N2) | US processor; disclose it in the privacy policy; verify cookie behaviour of the Maps JS API | US processor; verify | EU companies (MapTiler: Switzerland; Geoapify and OpenCage: Germany, verify), on OpenStreetMap data | US processor |
| Venue data (N5) | Best coverage | Good, improving | OpenStreetMap: good for cities, patchier for small venues | Good addresses, weaker places |
| Dev on localhost (N4) | Key restricted to `localhost:8080` | JWT signed by our server (we already sign JWTs); localhost behaviour to verify | API key | Token |

**Ruled out up front**: the public Nominatim (OpenStreetMap) server, whose usage policy doesn't allow autocomplete and is for light use only (verify; self-hosting it is out of scope). Mapbox stays a candidate on paper, but storing coordinates there has no free tier and its places search is the weakest of the four, so it only wins if the others fail.

## 3. What decides it

Score each candidate 0–3 on these weights after the spike.

| Criterion | Weight | Why |
|---|---|---|
| N1 storage rights for coordinates and time zone | **High (gate)** | Our data model stores them. A provider we can't legally store from needs a refresh job or ID-only storage, which changes the design |
| R1 + N5 venue autocomplete quality in 5 test cities | High | It's the user-facing part. Test cities: Lisbon, Madrid, Berlin, Mexico City, Bangkok (expat-heavy, mixed coverage) |
| R3 time zone available from the same call or a cheap second one | Medium | Fixes the wall-clock bug |
| N2 privacy fit (EU, no cookies, processor terms) | Medium | The privacy policy is still being written, so the choice shapes it |
| N3 cost at 1× and 10× expected usage | Medium | See §5 for the usage assumptions |
| R6 native iOS fit | Low–medium | Phase 2, but location data should carry over |
| N4 dev ergonomics | Low | All four are workable |

**Hard gate**: if a provider's terms don't allow keeping coordinates in our database beyond a short cache, it only stays in the running if we accept the design in §6, option (b).

## 4. The spike (about 2 days, in development)

Time-boxed and throwaway, on a branch, never merged as-is.

1. **Accounts and keys (½ day).**
   - Google: Cloud project with billing, key restricted to `http://localhost:8080`.
   - Apple: a Maps ID and private key under the existing Developer account; mint the MapKit JS token from Vapor (JWTKit, ES256).
   - Geoapify and MapTiler (or Stadia): free keys.
   - All keys go in `.env` (git-ignored) with matching entries in `.env.example`, never in templates or the repo.
2. **Autocomplete test page (1 day).** A dev-only page with the same input wired to each provider. For each of the 5 test cities, try one city lookup and three venue lookups: a café, a park and a bar the user knows exists. Record found or not, address quality, coordinates, whether a time zone came back, and calls used.
3. **Map test (½ day).** Show a pin for one venue with each provider's map on a mock event page. Note load weight, attribution needs, and whether the page sets cookies (browser devtools → Application → Cookies).
4. **Terms check (alongside).** Get written answers for the three open "verify" rows: Apple coordinate storage and Place ID persistence, Apple time zone, Geoapify storage. For Apple, ask through Developer Support, since the forum question was never answered.
5. **Write-up.** Fill in the scorecard in §3 and record the decision in this file. Then the real work becomes two tracked items: city/venue autocomplete plus time zone on the create form (closing the M4 follow-up and the time-zone limitation), and the map on the event page (part of the Event detail restyle PR).

## 5. Development vs. deployment

| | Development | Deployment (M13, DigitalOcean) |
|---|---|---|
| Keys | Personal or dev keys in `Server/.env`; restricted to `localhost` | Separate production keys in the App Platform/Droplet environment; restricted to the production and staging domains. Never reuse dev keys |
| Tests | **No live calls.** A `GeoService` protocol with a fake implementation for tests (same pattern as the identity-token verifiers) | Real provider behind the same protocol |
| Usage assumptions (to confirm) | Negligible | Start: ~500 events/month created (~1,500 autocomplete sessions, ~1,000 lookups), ~20,000 event-page map views/month. 10× for the growth case |
| Cost at start, from the prices above | $0 everywhere | Google within free caps (~1.5k autocomplete, ~1k details, ~1k time zone, map views over 10k → ~$70/month unless using the free Embed); Apple $0 (well inside 250k views/day); Geoapify within free credits; MapTiler $30/month for commercial use; Mapbox within free map loads, but permanent geocoding ~$5/month |
| Monitoring | None needed | Budget alerts (Google), the MapKit dashboard (Apple), usage emails (Geoapify/MapTiler); alert on HTTP 429s from Apple |
| Privacy policy | n/a | Name the chosen provider(s) as processors, where data goes, and whether any cookies are set (the M9 placeholder already has a "Who processes it" section) |

## 6. Design it so the choice is reversible

Whatever wins, build the integration so switching later is contained:

- A **`GeoService` protocol** in the server (autocomplete proxy if done server-side, place lookup, time zone), with one adapter per provider and a fake for tests.
- Store **our own fields** on each event: formatted address, latitude, longitude, time zone identifier (e.g. `Europe/Lisbon`), plus `provider` and `providerPlaceID`. A migration adds the last three.
- If the winner restricts storing coordinates, the choices are:
  - **(a)** pick a different provider for geocoding, or
  - **(b)** store only `providerPlaceID` and time zone, and refresh coordinates on a schedule: Google's 30-day rule means a refresh job. Option (b) is more moving parts, so it costs that provider points in §3.
- The front-end map is loaded only on pages that show one, so a provider's script never runs site-wide.

## 7. Sources

- Google Maps Platform pricing: <https://developers.google.com/maps/billing/pricing>
- Google Maps Platform Service Specific Terms (Places and Geocoding caching and non-Google-map rules, archived 2025-05-01 version; check the current version): <https://cloud.google.com/archive/maps-platform/terms/maps-service-terms-20250501>
- Apple MapKit JS limits: <https://developer.apple.com/maps/mapkitjs/pricing>
- Apple Maps Server API (endpoints, 25,000 shared calls/day, HTTP 429): <https://developer.apple.com/documentation/applemapsserverapi.md>
- Apple developer forum on the MapKit JS storage clause (no Apple answer): <https://developer.apple.com/forums/thread/116695>
- Mapbox pricing: <https://www.mapbox.com/pricing>; temporary vs permanent results: <https://docs.mapbox.com/help/getting-started/search/>
- MapTiler pricing: <https://www.maptiler.com/cloud/pricing/>
- Geoapify pricing: <https://geoapify.com/pricing>; Address Autocomplete (timezone in results): <https://apidocs.geoapify.com/docs/geocoding/address-autocomplete/>
- OpenCage pricing (permanent storage, trial for testing only): <https://opencagedata.com/pricing>
