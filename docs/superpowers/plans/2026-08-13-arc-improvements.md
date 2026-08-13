# Arc — review and improvement plan

**Date:** 2026-08-13
**Repo HEAD:** `46b16e7` (`feat(trips)` merged into `main`)
**Goal:** Finish the trip-mode slice that is in git but not live, then raise the rest of the app to the same honesty bar already applied to air legs.

This is a proposal, not an implementation. Work is ordered so each slice is independently shippable.

---

## Current state

Arc is a map-first SwiftUI + SwiftData iOS 26 app (Flighty-class flight tracker) with a Cloudflare Worker (`arc-backend`) and a Supabase social/sync layer. The air product is mature: natural-language search, live tracking, inbound knock-on, gates, Live Activities, widgets, friends, passport stats.

The newest work (`12c6d4b feat(trips)`) extends the same `Flight` model to trains and ferries (`TripMode` / `DataTier`). The model, display vocabulary, search-result mapping, and backend routes are in the repo. They are **not on the production Worker**, and several client surfaces still speak only “flight.”

Verified against the default backend `https://arc-backend.owncalai.workers.dev` on 2026-08-13:

| Probe | Result |
| --- | --- |
| `GET /health` | OK — AeroDataBox + AirLabs configured (ADB used 1218/900 this month) |
| `GET /classify?q=ICE%20373` | **404 `not found`** |
| `GET /rail/stations?q=Berlin` | **404 `not found`** |
| `POST /search-flights` `"ferry Piraeus to Santorini 15 Aug 2026"` | `{"flights":[]}` — no ground/water fan-out |

Until `wrangler deploy` from `backend/` (and Supabase migration `012`) land, TestFlight/App Store users on the default Worker still get air-only search.

---

## Unfinished work already in the repo

These are the “not yet implemented or deployed” items. Do them before net-new product work.

### 0. Deploy what is already written

1. **Worker deploy** — `cd backend && wrangler deploy`. This is what actually turns on `/classify`, `/rail/*`, `/ferry/*`, and the `/search-flights` rail+ferry fan-out in `index.ts`.
2. **Supabase migration `012_trip_modes.sql`** — adds `mode`, `data_tier`, stop IDs, TZs, vessel, disruption, booking URL, `rail_trip_id` to `user_flights` / `shared_flights`. The iOS client already writes these columns; an unmigrated project will fail sync/share for any new field.
3. **Smoke after deploy** — `/classify?q=ICE+373`, `/rail/stations?q=Berlin`, `/ferry/ports?q=Piraeus`, and a natural search that should return a train and a ferry. Confirm `/health` still reports AeroDataBox.

No app-store build is required for (1)–(2). A new iOS build is required for users to *add* rail/sea legs, but the Worker must go first or search will keep returning empty.

### 1. Mode-aware tracking (blocker for “it works after add”)

`FlightTracker.updateFlightStatus` always calls `/flight?number=&date=` (AeroDataBox). A saved ICE or ferry will poll an airline API forever and never refresh.

**Do:**

- Branch on `flight.mode` in `Arc/Services/FlightTracker.swift`.
- **Air:** keep current `/flight` + inbound + OpenSky path.
- **Rail:** refresh via `railTrip(tripId:)` when `railTripId` is live; on miss, `railReresolve` then retry. Skip inbound, arrival-stand, security, ADS-B.
- **Sea:** re-search the crossing (`ferrySearch`) and attach `ferryDisruptions` into `disruptionNote`. Skip air-only intelligence.
- Position: `updateLivePosition` currently takes `icao24` only. Honor `flight.livePositionSource` (`.adsb` vs `.ais`). AIS needs a Worker `/position?mmsi=` path; today `/position` is airplanes.live for ICAO24, and Ferryhopper mapping leaves `vessel_mmsi` null — treat AIS as a follow-on, not a ship-blocker.

Client wrappers already exist and are unused: `classify`, `railStations`, `railDepartures`, `railTrip`, `railReresolve`, `ferryPorts`, `ferrySearch`, `ferryDisruptions` in `FlightAPIClient.swift`.

### 2. Detail, share, widget, Live Activity still say “flight”

`TripMode` was written so every surface can share verbs (`IN AIR` / `EN ROUTE` / `AT SEA`). Only list + detail header + friends rows use it.

| Surface | What’s wrong | Fix |
| --- | --- | --- |
| `AirlineInfoSection` | Shown for every mode; scrapes IATA airline pages | Gate to `.air`; add operator/vessel section for rail/sea |
| `GoodToKnowSection` | Copy is “Flight cancelled”; ignores `disruptionNote` | Show operator notice verbatim; link `bookingURL` |
| `DelayRiskCard`, overlap, baggage | Air METAR/ICAO assumptions | Hide unless `.air` |
| `ShareTicketView` | Hardcoded airplane + airline logo | `TripLogoView` + mode symbol |
| `WidgetFlight` / `NextFlightWidget` | No `mode`; always `airplane` / “In Flight” / “On Time” | Persist `mode` + `dataTier`; use `TripMode` verbs; don’t paint green “On Time” for `scheduled`/`manual` tiers |
| `FlightActivityAttributes` | Airplane glyphs, gate/security/boarding copy | Mode (or symbol) on attributes; skip air boarding phases for ferries |
| Passport | “FLIGHTS”, `AirlineLogoView` on past rows | `TripLogoView`; “trips” where it means all modes |

Stored but never shown: `vesselName`, `disruptionNote`, `bookingURL`.

### 3. Discovery UX is “hope `/search-flights` guesses”

Add already maps a search *result* into trip-mode fields (`AddFlightView.add(_:)`). Prefetch still only hits `searchFlight` / `searchNatural`. There is no station board, no port picker, no mode-aware manual entry.

Minimum to make adding a train/ferry reliable without a perfect NL parse:

- Typeahead via `railStations` / `ferryPorts` when the classifier says rail/sea (or when local airport parse fails).
- Tapping a station → `railDepartures` board; tapping a sailing → add.
- Manual entry: mode picker (air / rail / sea) or hide air-only “FLIGHT NUMBER” / airport fields for non-air.

The product intent in `classify.ts` is “one search box, no mode picker.” Keep that as the default path; dedicated boards are the fallback when NL returns nothing.

---

## Product and quality improvements (after trip modes actually work)

### Honesty and dead settings

- **`trackingInterval` in Settings is a lie.** Stored in `@AppStorage` and never read. `FlightTracker` uses hardcoded tiers (2/5/30 min) for API-budget reasons. Either wire it as a *floor* on those tiers, or replace the picker with an explanation of the real cadence (and the ADB quota — August already shows `1218/900` used vs the documented monthly cap).
- **Watchers are implemented in Supabase + `ArcSupabase.watchFlight` / `unwatchFlight` and have no UI.** Spec deferred this. Either expose “notify me about this friend’s flight” on detail, or delete the dead API so it doesn’t look like a missing feature.
- **Passport / stats for ferries.** Distance is often 0 (no great-circle if coords missing; 838 of 1,426 ports have no lat/lon). Don’t let zero-km sea legs deflate “distance” and “× around the world.”

### Spec leftovers worth doing

From `docs/superpowers/specs/2026-07-19-arc-flighty-clone-design.md`, still open:

| Item | Notes |
| --- | --- |
| Large home widget (“next 3”) | Spec §6; only small + medium exist |
| Standalone Worker `/route`, `/airport/{iata}/departures`, `/aircraft?reg` | Folded into `/search-flights`; only add if typeahead needs them |
| Apple Watch, Pickup Coordinator | Explicitly out of scope — leave them there |
| Pixel-faithful Flighty screenshot pass | Original definition of done; lower priority than trip-mode honesty |

### Maintainability (the files that will fight the next feature)

- `AddFlightView.swift` (~1,400 lines) and `FriendsView.swift` (~1,000) are past the point where adding a station board is cheap. Split search results, manual entry, and add-confirmation before extending discovery.
- `backend/src/index.ts` (~2,960 lines) already extracted transit to `routes-transit.ts`. Next extract: search-flights, gates, share pages.
- `backend/package.json` `npm test` does not run `.ts` tests as-is. The suite passes with `node --experimental-strip-types --test test/*.test.ts` (119 tests). Fix the script.
- `wrangler.toml` comments still say `/position` is OpenSky; it is airplanes.live. Transit routes, `AI_API_KEY`, `APNS_*`, `AIRLABS_KEY` are undocumented. `README.md` is a single `# arc` line.
- Default Worker URL and Supabase anon JWT are compiled into the app (`FlightAPIClient`, `SupabaseClient`). Normal for anon keys, but every install is welded to one project. Settings already allows a backend URL override; document it.

### Tests to add when implementing the above

- Tracker: a rail `Flight` must not call `/flight`; a sea `Flight` must not apply AeroDataBox gates.
- Widget: `dataTier == scheduled` never renders as On Time green.
- Display: `disruptionNote` appears in Good to Know; `AirlineInfoSection` hidden for `.sea`.
- Backend: one `/search-flights` test that the rail/ferry fan-out merges (fixture the internal fetches). `handleTransit` HTTP paths are currently untested.

---

## Suggested order of work

```
P0  Deploy Worker + apply 012          (ops, unblocks everything)
P1  Mode-aware FlightTracker           (saved trains/ferries stay truthful)
P2  Detail + share + widget + LA copy  (vocabulary already in TripMode.swift)
P3  Disruption / vessel / booking URL  (data is stored, UI is missing)
P4  Station/port fallback discovery    (NL search can ship without this)
P5  Settings honesty, README, npm test
P6  Large widget, watchers UI, split AddFlightView
```

P0 is the only item that is not a code change. P1–P3 are the difference between “trip modes exist in git” and “a user can add a ferry and trust the app until it docks.”

---

## Out of scope (do not start)

- Forking `Flight` into separate Train/Ferry models — `TripMode` exists specifically to avoid that.
- Live train GPS — Transitous has no vehicle positions worth showing; timetable progress is the honest ceiling.
- Ferry AIS until Ferryhopper (or another source) actually yields MMSI.
- Social expansion, Watch, Pickup Coordinator — unchanged from the July spec freeze.
