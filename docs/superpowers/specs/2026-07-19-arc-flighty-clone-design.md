# Arc → exact Flighty clone — design spec

**Date:** 2026-07-19
**Goal:** Turn Arc into a pixel-and-behavior-faithful private clone of Flighty for personal use, with flight search and live tracking working end-to-end.
**Approach chosen with user:** screen-by-screen (finish each screen's exact UI **and** working data before moving on); core-first (social/Friends deferred).

---

## 1. What "exact clone" means here

Faithful to Flighty's **layout, spacing, hierarchy, interaction, motion, and color language**, built with the user's own assets and bundled data. We do **not** copy Flighty's proprietary artwork or fonts. Because this is a personal, fully-owned build, **all "Pro"-gated features are simply unlocked** — there is no purchase flow, no purple "Get Pro" chrome anywhere.

Reference: the real Flighty app is a **light-themed, map-first** app. One Apple Maps view is the persistent background (flat when zoomed in, a globe in space when zoomed out); the UI lives in **bottom sheets** over that map; a **floating pill tab bar** (3 tabs + a circular search button) sits on top.

---

## 2. Current state (baseline audit)

Environment: **Xcode 26.6, iOS 26.5 SDK, xcodegen 2.46**, iPhone 17 simulators available → we can build and screenshot every screen for verification. Deployment target iOS 26.0. Project generated from `project.yml`; two targets (`Arc` app, `ArcWidget` extension) + `Shared`.

What exists and is reusable:
- `GlobeView` is **already MapKit** (`Map` + `.imagery(elevation: .realistic)`), not SceneKit — becomes the shared map.
- `FlightsHomeView` already uses a map-background + bottom-sheet layout (but a fixed 0.45-height material rect, dark-themed).
- SwiftData `Flight` model, `FlightTracker` polling loop, `LiveActivityManager`, `WidgetSync`, `ArcNotifications`, widget + Live Activity targets all scaffolded.
- Cloudflare Worker proxy with `/flight` (AviationStack), `/position` (OpenSky), `/journey/:code` (shared page).
- Supabase social layer (auth, friends, shared journeys) — functional, will be **deferred/frozen**, not expanded.

Gaps that define the work:
- Entire app is **dark-themed**; Flighty is light.
- **Flight Detail** is a pushed dark screen, not a bottom sheet over the map.
- **Add Flight** is one crude step (type 3 chars → AviationStack); Flighty is a multi-step airline/airport/flight typeahead.
- **Passport** is dark glass cards; Flighty uses navy/red/blue gradient "passport" cards + a sortable past-flights list.
- Data layer is weak: hardcoded 250 airports, no airline dataset, no logos, no inbound-aircraft, no city names, no live positions worth showing.

### 2a. Duplicate-sheet / blocking issues found (user explicitly asked)
1. **Two Add-Flight entry points** — a `Search` tab **and** a `+` button in `FlightsHomeView`, both showing `AddFlightSheet`. → collapse to one (pill search button).
2. **Wrong tab model** — 4 native tabs; Flighty is 3 tabs + a separate circular search button on a floating pill.
3. **Flight Detail pushed screen** instead of a map-backed sheet. → convert to sheet.
4. **Two independent map instances** (Home + Passport). → one shared map.
5. **Settings buried** in a Passport toolbar gear. → move behind the avatar circle.
6. **My Flights sheet is a fixed-height rect**, not draggable. → proper resizable sheet.

All six are resolved by the architecture in §4.

---

## 3. Scope

**In scope (this effort):**
- Light theme system matching Flighty.
- Shared map + camera controller; custom draggable bottom sheet; floating pill tab bar.
- Screens: **My Flights**, **Flight Detail** (full scroll), **Add Flight** (multi-step), **Passport** (+ stat detail screens), **In-flight/live tracking**, **Widgets + Live Activity** parity.
- Bundled reference data (airports + airlines) and curated logos + aircraft silhouettes.
- Cloudflare Worker upgraded to AeroDataBox; real search, status, inbound leg, aircraft, positions.
- Fix the six consolidation issues.

**Deferred (kept working, not expanded):** Friends, Shared Journeys, Watchers, family messaging, Pickup Coordinator, Apple Watch. The Friends tab stays and gets minimally re-themed to the light system so it doesn't look broken, but no new social work.

**Explicitly out of scope:** any purchase/Pro flow; copying Flighty artwork/fonts.

---

## 4. Target architecture

**One app, one map, sheets are the UI.**

- **`ArcRootView`** owns a single shared `Map` plus an `@Observable MapController` (camera position; `flyTo(route:)`, `follow(plane:)`, `fitAll(routes:)`).
- **Three main tabs** (My Flights, Friends, Passport) render their content inside a **custom draggable `BottomSheet`** (2–3 detents; map interactive behind). Custom — not native `.sheet` — because the pill must float *above* the sheet.
- **Floating pill `ArcTabBar`** overlaid bottom-center: 3 tab items + a trailing circular search button. Search button presents Add Flight.
- **Flight Detail** and **Add Flight** are **native presented sheets** over the map (`.presentationDetents`, `.presentationBackgroundInteraction(.enabled)`), tab bar hidden, `X` to close. Presenting Detail flies the shared camera to that route.
- **Theme:** new `ArcTheme` — **system-adaptive light + dark, both first-class** (Flighty follows the system exactly). Built on semantic system colors + material sheet surfaces so it flips automatically. `ArcColor`/`ArcType` in `DesignSystem/ArcDesign.swift` get rewritten; old hardcoded dark tokens retired.
- **No Pro gating:** every "upgrade to…" surface renders the real content.

### 4a. Theme tokens (`ArcTheme`)
- Surfaces: sheet uses a **material** (`.regularMaterial`/`.thickMaterial`) so it renders opaque-white in light mode and **dark frosted** in dark mode automatically; cards `Color(.secondarySystemBackground)` with hairline separators; the Passport gradient cards keep their navy/red/blue fills in both modes.
- Text: primary `Color(.label)`, secondary `Color(.secondaryLabel)`, tertiary for hints.
- Status: on-time green `#34C759`; late/cancelled red `#FF3B30` (original time shown struck-through in gray beside the live time); gate pill `#FFCC00` background, black text, ~8pt corner rounded-rect; routes/actions blue `#0A84FF`/`#007AFF`.
- Type scale (SF Pro / system): screen title 34 heavy; sheet section title 22 bold; times 40 regular; IATA code 15–17 bold; city-pair 22 semibold (city names bold, "to" regular secondary); captions 13; tag pills 13 medium.
- Map: `.standard`/`.hybrid` toggle (Flighty offers map/satellite); routes as `MapPolyline` in blue; airport pins as small circles with IATA/city labels; live plane annotation with heading rotation; dashed segment ahead of the plane, solid behind.

### 4b. Data layer
- **Bundled reference data** (offline, in app bundle):
  - `airports.json` — from OurAirports (IATA, ICAO, name, city, country, lat, lon, **IANA timezone**). Replaces hardcoded `AirportDatabase`.
  - `airlines.json` — from OpenFlights (IATA, ICAO, name, callsign, country). Powers airline typeahead + logo lookup.
  - Loaded once into an in-memory index for instant typeahead (name / IATA / ICAO / city prefix match, with matched-character highlight).
- **Curated assets** (bundled):
  - Airline logos for carriers the user flies (from their history: LX/Swiss, U2/easyJet, W6/Wizz, GQ/Sky Express, DL/Delta, B6/JetBlue, …) as an asset catalog keyed by IATA; fallback = tail-color initials chip.
  - ~12 stylized aircraft **side silhouettes** by family (A320/A321neo/A350/B737/B77W/B787/E190/CRJ/ATR/generic-narrow/generic-wide/default); mapped from aircraft type string.
- **Live data via Cloudflare Worker → AeroDataBox** (key server-side; provider-agnostic interface):
  - `/flight?number&date` → status: sched/estimated/actual times both ends, gate, terminal, baggage, status, delay, aircraft type + registration + ICAO24, dep/arr coords.
  - `/route?from&to&date` and `/airport/{iata}/departures` → find flights for airport/route typeahead results.
  - `/inbound?reg&date` (or by ICAO24) → previous leg of the same tail → "Where's My Plane" timeline + turnaround-based delay estimate.
  - `/position?icao24` → live lat/lon/alt/speed/heading (AeroDataBox positions; OpenSky fallback).
  - `/aircraft?reg` → type, age (optional).
  - Keep `/journey/:code` (unchanged, deferred).
- **Model additions** (`Flight`): `estimatedDeparture`, `actualArrival` already partial → ensure both-end estimated/actual; `bookingCode`, `seat` (already have `notes`); inbound leg fields (have `inboundFlightNumber`, `inboundDelayMinutes`) → extend with inbound route/times for the timeline; store `aircraftICAO24` (exists).

### 4c. Build & verify
- Regenerate project with `xcodegen`; build `xcodebuild -scheme Arc -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.
- Boot simulator, install, launch, drive with `xcrun simctl`; capture screenshots per screen and compare against the provided Flighty shots. Share screenshots with the user at each screen's completion.
- Commit a checkpoint per screen.

---

## 5. Screen-by-screen plan (ordered, each = exact UI + working data)

**Foundation (F)** — theme tokens; bundled `airports.json`/`airlines.json` + loader/index; asset catalogs (logos, aircraft silhouettes); `MapController` + shared `Map`; custom `BottomSheet`; floating `ArcTabBar` (3 tabs + search); consolidate the two add-flight paths into one; Worker interface stub returning bundled/mocked data until the AeroDataBox key arrives.

**1. My Flights** — map background auto-fit to upcoming routes; draggable white sheet; header "My Flights" 34 heavy + share + avatar (avatar → Settings/profile); flight cards: left countdown block (`49`/`DAYS`, `17`/`HOURS`, big), airline logo + flight number + right-aligned date, city-pair bold, route row with circular ↗/↘ arrow chips + IATA + time (green when on-time). Upcoming then Past sections. Empty state. Pull to refresh. Tap → Detail.

**2. Flight Detail** (native sheet over map, full scroll):
- Header: airline logo, `LX 14 • SUN, 19 JUL`, city-pair bold, circular `X`.
- Status banner (tinted): "Gate Departure in 1h 38m" (green) / "Landing in 6h 43m" (red) + inbound line ("Inbound aircraft has arrived ›").
- Departure block: `● SFO • San Francisco Intl. ›`, big time (green/red) with struck-through original when changed, "On Time / 1h 2m Late • Departs in… / … ago", yellow gate pill (`↗ C8`), `Terminal 1`.
- Duration divider: `5h 15m • 4.152 km`.
- Arrival block: same shape (`↘ B38`).
- Action row: pill with share / bell / `…`, "Booking Code — Tap to Edit", "Seat — Tap to Edit", blue Share.
- "Good to Know": per-airport disruption rows (real content, unlocked), "+1 Hour Timezone Change — 23:50 arrival is 22:50 <origin> time".
- "Where's My Plane?": aircraft type, bundled side silhouette, **inbound leg timeline** (previous flights of the tail with live/landed status).
- "Detailed Timetable": Scheduled / Estimated / Predicted / Actual grid — Depart (Gate/Taxi/Take Off), Arrive (Land/Taxi/Gate), Totals (Air/Total time).
- Airline card: logo + name, Phone/Website/X/Facebook buttons, ATC Callsign / ICAO / IATA.
- "My History on This Route": flights / distance / time on this city-pair.
- "Updates": chronological event log. "Notes": editable.
- Map flies to route behind; when active, shows live plane.

**3. Add Flight** (native sheet, multi-step):
- Step 1: "Add Flight / Enter airline, airport, or flight", search field placeholder "EasyJet, HAM, or U2123"; "FREQUENTLY USED" list; instant typeahead over bundled airlines/airports with matched-char highlight; a `LX1413`-style entry is detected as a flight number ("Detected flight number").
- Step 2 (airline chosen): "Enter flight number" — airline chip + number field, "Tip: Just The Numbers".
- Step 3: "Enter departure date" — Today / Tomorrow / Pick from Calendar.
- Step 4: result flight card ("Tap flight to add to My Flights"); tap → insert + map animates the new route; "Added to My Flights" confirmation.

**4. Passport** (shared map as globe behind):
- Header "Passport" + share + avatar; "All-Time" / `<year>` chips.
- **Passport card** (navy→blue gradient): FLIGHTS (+ long-haul), DISTANCE (+ "×around the world"), FLIGHT TIME, AIRPORTS, AIRLINES, "All Flight Stats ›".
- **Delay card** (red gradient): "N minutes lost from delays / Delayed flights averaged Xm late", "All Delay Stats ›".
- **Most-flown-aircraft card** (blue gradient): type + N flights + side silhouette, "All Aircraft Stats ›".
- **Past Flights**: sort chips (Date ↓ / From / To / Airline / Aircraft), list/grid toggle, `<year> — N FLIGHTS` headers, rows = logo + `LX 1056 ZRH → HAM` + city-pair bold + tag pills (duration, type, registration) + date.
- Stat detail screens: All Flight Stats, All Delay Stats, All Aircraft Stats.

**5. In-flight / live tracking** — active flight: map follows plane; annotation on the arc (solid behind, dashed ahead); top-center speed/altitude pill (`874 km/h 10'363m`); map controls (layers / collapse / weather); detail sheet shows live times; Live Activity running.

**6. Widgets + Live Activity parity** —
- Home widgets: small (next-flight countdown + route + status + gate), medium (status + progress), large (next 3).
- Live Activity lock screen: `SFO 11:00AM ✈ 12:00PM JFK`, cities, per-end times + "10m Early"/"On Time", green progress line, "1h 20m UNTIL GATE ARRIVAL".
- Dynamic Island: compact (status dot + timer), expanded (`SFO ●—✈···● JFK`, "On Time / Landing in 55m", baggage pill).

**7. Backend/data wiring** — swap Worker to AeroDataBox; implement `/route`, `/inbound`, upgrade `/flight` + `/position`; enrich `FlightTracker`, `InboundMonitor`; notifications on real transitions. (Interfaces built in Foundation; keyed calls turned on when the user provides the RapidAPI key.)

---

## 6. Risks / decisions resolved
- **Provider:** AeroDataBox (free Basic tier for testing, ~$5/mo Pro); FlightAware is the premium alternative. User provides RapidAPI key; Worker keeps it server-side; interface is provider-agnostic for easy swap.
- **Logos/art:** bundle curated set + fallbacks (chosen).
- **Custom vs native sheet:** custom for the 3 main tabs (pill floats above); native presented sheets for Detail/Add.
- **Dark mode:** first-class parity target. Screenshots are light mode; Flighty follows the system, so in dark mode the sheet/card surfaces become dark frosted while status colors, gate pills, blue routes, and gradient Passport cards stay identical. Achieved by building on semantic system colors + material surfaces (no separate dark palette to maintain). Verify each screen in **both** appearances in the simulator.
- **Social:** frozen, re-themed only.

## 7. Definition of done (per screen)
UI matches the corresponding Flighty screenshot in layout/spacing/color **in both light and dark appearance**; the screen's data is real (bundled or live via Worker) — no stub text where Flighty shows data; builds clean; verified by simulator screenshots (light + dark) shared with the user; committed as a checkpoint. Overall done when screens 1–6 pass and the six consolidation issues are closed.
