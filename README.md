# Arc

An iOS trip tracker for flights, trains and ferries. Live status, a home-screen
widget, a Live Activity that keeps counting with no app process running, and a
passport of everywhere you've been.

Arc's governing rule is that it never asserts something nobody told it. A leg
carries the tier of what its source actually knows (`DataTier`), and only a
source that reports revised times against a schedule earns a delay figure or a
status colour — a published ferry timetable gets neither. Arc's own knock-on
prediction is allowed to be ahead of the airline, but it says so: it wears
sparkles and the word "Arc", never a green "On Time".

## Layout

| Path | What's in it |
| --- | --- |
| `Arc/` | The app: SwiftUI views under `Features/`, SwiftData models under `Models/`, providers and tracking under `Services/` |
| `ArcWidget/` | Home-screen widget and the Live Activity |
| `Shared/` | Compiled into both app and widget: the widget snapshot, Live Activity attributes, `arc://` deep links, `TripMode`/`DataTier` |
| `ArcTests/` | Unit tests (`@testable import Arc`) |
| `backend/` | Cloudflare Worker: every provider call, so no key ships in the app |
| `supabase/migrations/` | Friends, shared journeys, gate stats, push tokens |
| `scripts/` | `build_reference_data.py` — bundles the offline airport/airline tables |
| `docs/` | `api-keys-setup.md`: getting an AeroDataBox key and deploying the Worker |

`project.yml` is the source of truth for the Xcode project. `Arc.xcodeproj` is
committed so you can open it directly, but if you add a file, add it where the
spec already looks (`Arc/`, `ArcWidget/`, `Shared/`, `ArcTests/`) — anything
hand-added to the project file is lost the next time someone runs XcodeGen.

## Running the app

Requires Xcode 26 (iOS 26 deployment target — the app uses `glassEffect`,
`TimelineView`-driven widget clocks and current Live Activity APIs).

```bash
xcodegen          # optional; only needed after adding or moving files
open Arc.xcodeproj
```

Build and run the `Arc` scheme. `⌘U` runs the tests, or:

```bash
xcodebuild test -scheme Arc -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Nothing needs configuring to try it: the UI, the bundled airport/airline
typeahead (~7,900 airports, ~990 airlines), manual trip entry, Passport stats,
widgets and Live Activities all work with no backend and no account. Live search
and live tracking are what need a Worker.

## Running the backend

```bash
cd backend
npm install
npm test          # 119 tests, no network — needs Node ≥ 22.6 for type stripping
npm run dev       # wrangler dev on http://localhost:8787
npm run deploy
```

The app's Info.plist allows local-network cleartext, so a simulator can point at
`wrangler dev`: Arc → Passport → avatar → Settings → Backend URL.

`wrangler.toml` documents every secret and what it unlocks, plus the full
endpoint list. Only `RAPIDAPI_KEY` (AeroDataBox) is needed for flight tracking;
rail and ferry data come from Transitous and Ferryhopper, which need no key at
all. `GET /health` reports which providers are configured and how much of the
month's API budget is spent.

## Where the data comes from

| Mode | Provider | What it reports |
| --- | --- | --- |
| Air | AeroDataBox (RapidAPI), AirLabs as schedule fallback | Status, revised times, gates, terminal, belt, aircraft — so air legs are `live` |
| Air position | airplanes.live | ADS-B position while airborne (OpenSky rejects Cloudflare's egress IPs) |
| Rail | Transitous / MOTIS | Timetable plus realtime where the operator publishes it, so a train is `live` or `scheduled` depending on the answer |
| Sea | Ferryhopper MCP | A timetable and, separately, prose disruption notices. No per-sailing delay exists anywhere, so every sailing is `scheduled` |

A train is re-found after a feed rebuild by what its ticket says rather than by
the trip id, which MOTIS renumbers on every import: see `RailServiceKey`
(`Shared/TripMode.swift`) and `railServiceKey` (`backend/src/transit.ts`) — the
two build the same string and have to stay that way.

## Social features (optional)

Friends, shared journeys and the live share link run on Supabase. The app ships
pointing at a project with the anon key baked into `ArcSupabase.init` — to use
your own, create a project, apply `supabase/migrations/*.sql` in order, and
change those two defaults (they can also be overridden at runtime through the
`supabase_url` and `supabase_anon_key` user defaults; Settings only exposes the
Worker's Backend URL).

The Worker needs its own `SUPABASE_URL` and `SUPABASE_SERVICE_KEY` for the
shared-journey page, the gate store and the API budget row. Remote Live Activity
pushes need those two plus the three `APNS_*` secrets.

Rail and sea legs need migration `012_trip_modes.sql` applied and the Worker
deployed before they can be added at all.
