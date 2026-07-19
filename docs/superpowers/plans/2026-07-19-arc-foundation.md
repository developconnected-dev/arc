# Arc Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the shared architecture for the Flighty-parity rebuild — adaptive light/dark theme, bundled offline airport/airline data, curated logo/aircraft mapping, one shared MapKit map with a camera controller, a custom draggable bottom sheet, a floating pill tab bar, and a root view that ties them together — producing a runnable app shell with stubbed screens.

**Architecture:** One `ArcRootView` owns a single shared `Map` plus an `@Observable MapController`. Three main tabs render inside a custom `BottomSheet`; a floating `ArcTabBar` (3 tabs + circular search) floats above it; Add Flight and Flight Detail are presented sheets over the map. Theme is built on semantic system colors + material surfaces so it adapts to light/dark automatically.

**Tech Stack:** Swift 6, SwiftUI, MapKit (SwiftUI `Map`), SwiftData, xcodegen, XCTest. Deployment target iOS 26.0; Xcode 26.6; iPhone 17 simulators.

**Conventions:**
- Regenerate the project after editing `project.yml`: `xcodegen generate` (run in `/Users/carl/Downloads/Arc`).
- Build: `xcodebuild -project Arc.xcodeproj -scheme Arc -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- Test: `xcodebuild -project Arc.xcodeproj -scheme Arc -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`
- Commit after each task with the message shown.
- Reference data / logic gets real XCTest tests. Pure view layout is verified by a clean build + a simulator screenshot (there is no meaningful unit test for pixel layout).

---

## File structure (created/modified in this plan)

**Created:**
- `Arc/DesignSystem/ArcTheme.swift` — adaptive color/type/metric tokens (status colors, gate-pill style).
- `Arc/Models/ReferenceModels.swift` — `AirportRef`, `AirlineRef` value types.
- `Arc/Services/ReferenceData.swift` — bundle loader + in-memory search index.
- `Arc/Resources/airports.json`, `Arc/Resources/airlines.json` — bundled datasets (generated).
- `Arc/Services/AirlineBranding.swift` — IATA → logo asset / fallback initials + tail color.
- `Arc/Services/AircraftImage.swift` — aircraft type string → bundled silhouette asset name.
- `Arc/Map/GeoMath.swift` — great-circle sampling + bounding-region helpers.
- `Arc/Map/MapController.swift` — `@Observable` camera controller.
- `Arc/Map/ArcMapView.swift` — the shared map view (replaces `GlobeView`).
- `Arc/Components/BottomSheet.swift` — custom draggable multi-detent sheet.
- `Arc/Components/ArcTabBar.swift` — floating pill tab bar.
- `Arc/Components/AirlineLogoView.swift`, `Arc/Components/RouteArrowChip.swift` — small shared views.
- `Arc/Features/Root/ArcRootView.swift` — root coordinator (shared map + tabs + sheets + pill).
- `Arc/Features/Root/StubSheets.swift` — temporary My Flights / Friends / Passport / Add sheet bodies (perfected in later plans).
- `ArcTests/ReferenceDataTests.swift`, `ArcTests/GeoMathTests.swift`, `ArcTests/BrandingTests.swift` — unit tests.
- `scripts/build_reference_data.py` — data generation script (run once, committed output).

**Modified:**
- `project.yml` — add `ArcTests` target; ensure `Arc/Resources` is bundled.
- `Arc/ArcApp.swift` — root becomes `ArcRootView`.
- `Arc/DesignSystem/ArcDesign.swift` — retire hardcoded dark tokens; re-point to `ArcTheme` (keep enum names `ArcColor`/`ArcType`/`ArcRadius`/`ArcSpace` so existing frozen screens still compile).

**Deleted:**
- `Arc/Features/Flights/RootTabView.swift` — replaced by `ArcRootView` (removes the duplicate Add-Flight entry point and the 4-tab model).
- `Arc/Globe/GlobeView.swift` — replaced by `ArcMapView`.

---

## Task 1: Add a unit-test target so TDD works

**Files:**
- Modify: `project.yml`
- Create: `ArcTests/SmokeTests.swift`

- [ ] **Step 1: Add the test target to `project.yml`**

Append under `targets:` (sibling of `Arc` and `ArcWidget`):

```yaml
  ArcTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: ArcTests
    dependencies:
      - target: Arc
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.arc.flighttracker.tests
        SWIFT_VERSION: "6.0"
        GENERATE_INFOPLIST_FILE: YES
```

And add a scheme so `xcodebuild test` finds it — add at the end of `project.yml`:

```yaml
schemes:
  Arc:
    build:
      targets:
        Arc: all
        ArcTests: [test]
    test:
      targets:
        - ArcTests
```

- [ ] **Step 2: Create a smoke test**

`ArcTests/SmokeTests.swift`:

```swift
import XCTest

final class SmokeTests: XCTestCase {
    func testHarnessRuns() {
        XCTAssertEqual(1 + 1, 2)
    }
}
```

- [ ] **Step 3: Regenerate and run the test**

Run:
```bash
cd /Users/carl/Downloads/Arc && xcodegen generate && \
xcodebuild -project Arc.xcodeproj -scheme Arc \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test 2>&1 | tail -20
```
Expected: `Test Suite 'SmokeTests' passed`, `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "build: add ArcTests unit-test target"
```

---

## Task 2: Generate bundled airport + airline reference data

**Files:**
- Create: `scripts/build_reference_data.py`
- Create: `Arc/Resources/airports.json`, `Arc/Resources/airlines.json`

- [ ] **Step 1: Write the generation script**

`scripts/build_reference_data.py`:

```python
#!/usr/bin/env python3
"""Build bundled airports.json + airlines.json for Arc.
Airports: mwgg/Airports (has IATA, ICAO, name, city, country, lat, lon, IANA tz).
Airlines: OpenFlights airlines.dat (IATA, ICAO, name, callsign, country, active).
Run once; commit the JSON outputs.
"""
import json, urllib.request, csv, io, os

OUT = os.path.join(os.path.dirname(__file__), "..", "Arc", "Resources")
os.makedirs(OUT, exist_ok=True)

# --- Airports ---
AIRPORTS_URL = "https://raw.githubusercontent.com/mwgg/Airports/master/airports.json"
raw = json.load(urllib.request.urlopen(AIRPORTS_URL))
airports = []
for icao, a in raw.items():
    iata = (a.get("iata") or "").strip()
    if len(iata) != 3:      # keep only real IATA-coded airports
        continue
    airports.append({
        "iata": iata,
        "icao": (a.get("icao") or "").strip(),
        "name": a.get("name") or "",
        "city": a.get("city") or "",
        "country": a.get("country") or "",   # ISO-2
        "lat": round(float(a.get("lat", 0)), 5),
        "lon": round(float(a.get("lon", 0)), 5),
        "tz": a.get("tz") or "",              # IANA, e.g. "Europe/Zurich"
    })
airports.sort(key=lambda x: x["iata"])
with open(os.path.join(OUT, "airports.json"), "w") as f:
    json.dump(airports, f, ensure_ascii=False, separators=(",", ":"))
print(f"airports: {len(airports)}")

# --- Airlines ---
AIRLINES_URL = "https://raw.githubusercontent.com/jpatokal/openflights/master/data/airlines.dat"
data = urllib.request.urlopen(AIRLINES_URL).read().decode("utf-8", "replace")
airlines = []
seen = set()
for row in csv.reader(io.StringIO(data)):
    # id,name,alias,iata,icao,callsign,country,active
    if len(row) < 8:
        continue
    name, iata, icao, callsign, country, active = row[1], row[3], row[4], row[5], row[6], row[7]
    iata = (iata or "").strip()
    if len(iata) != 2 or iata in ("-", "") or active != "Y":
        continue
    if iata in seen:        # first active wins
        continue
    seen.add(iata)
    airlines.append({
        "iata": iata,
        "icao": (icao or "").strip(),
        "name": name or "",
        "callsign": (callsign or "").strip(),
        "country": country or "",
    })
airlines.sort(key=lambda x: x["iata"])
with open(os.path.join(OUT, "airlines.json"), "w") as f:
    json.dump(airlines, f, ensure_ascii=False, separators=(",", ":"))
print(f"airlines: {len(airlines)}")
```

- [ ] **Step 2: Run it**

Run:
```bash
cd /Users/carl/Downloads/Arc && python3 scripts/build_reference_data.py
```
Expected: prints `airports: <~6000-7500>` and `airlines: <~1300-1600>`, creates the two JSON files. Sanity-check ZRH exists:
```bash
python3 -c "import json;d=json.load(open('Arc/Resources/airports.json'));z=[a for a in d if a['iata']=='ZRH'][0];print(z['city'],z['tz'])"
```
Expected: `Zürich Europe/Zurich` (or `Zurich Europe/Zurich`).

- [ ] **Step 3: Ensure the JSON is bundled — regenerate and confirm no build break**

The `Arc` target already sources `path: Arc`, so `Arc/Resources/*.json` is picked up as a bundle resource by xcodegen. Run:
```bash
cd /Users/carl/Downloads/Arc && xcodegen generate && \
xcodebuild -project Arc.xcodeproj -scheme Arc \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "data: generate bundled airports.json + airlines.json"
```

---

## Task 3: Reference models + loader with search index (TDD)

**Files:**
- Create: `Arc/Models/ReferenceModels.swift`
- Create: `Arc/Services/ReferenceData.swift`
- Test: `ArcTests/ReferenceDataTests.swift`

- [ ] **Step 1: Write the models**

`Arc/Models/ReferenceModels.swift`:

```swift
import Foundation
import CoreLocation

struct AirportRef: Codable, Hashable, Identifiable {
    let iata: String
    let icao: String
    let name: String
    let city: String
    let country: String
    let lat: Double
    let lon: Double
    let tz: String
    var id: String { iata }
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

struct AirlineRef: Codable, Hashable, Identifiable {
    let iata: String
    let icao: String
    let name: String
    let callsign: String
    let country: String
    var id: String { iata }
}
```

- [ ] **Step 2: Write the loader**

`Arc/Services/ReferenceData.swift`:

```swift
import Foundation

/// Loads bundled airport + airline reference data and answers prefix searches
/// used by Add-Flight typeahead. Loaded once, cached in memory.
final class ReferenceData {
    static let shared = ReferenceData()

    private(set) var airports: [AirportRef] = []
    private(set) var airlines: [AirlineRef] = []
    private var airportByIATA: [String: AirportRef] = [:]
    private var airlineByIATA: [String: AirlineRef] = [:]

    private init() { load() }

    /// Test seam: load from explicit arrays instead of the bundle.
    init(airports: [AirportRef], airlines: [AirlineRef]) {
        self.airports = airports
        self.airlines = airlines
        index()
    }

    private func load() {
        airports = Self.decode("airports.json") ?? []
        airlines = Self.decode("airlines.json") ?? []
        index()
    }

    private func index() {
        airportByIATA = Dictionary(airports.map { ($0.iata, $0) }, uniquingKeysWith: { a, _ in a })
        airlineByIATA = Dictionary(airlines.map { ($0.iata, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private static func decode<T: Decodable>(_ name: String) -> T? {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: base, withExtension: ext),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func airport(_ iata: String) -> AirportRef? { airportByIATA[iata.uppercased()] }
    func airline(_ iata: String) -> AirlineRef? { airlineByIATA[iata.uppercased()] }
    func timezone(_ iata: String) -> TimeZone? {
        guard let tz = airport(iata)?.tz, let z = TimeZone(identifier: tz) else { return nil }
        return z
    }

    /// Airports matching a query by IATA / city / name prefix. IATA-exact first.
    func searchAirports(_ query: String, limit: Int = 12) -> [AirportRef] {
        let q = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard q.count >= 1 else { return [] }
        func rank(_ a: AirportRef) -> Int {
            if a.iata == q { return 0 }
            if a.iata.hasPrefix(q) { return 1 }
            if a.city.uppercased().hasPrefix(q) { return 2 }
            if a.name.uppercased().contains(q) || a.city.uppercased().contains(q) { return 3 }
            return 99
        }
        return airports.map { ($0, rank($0)) }.filter { $0.1 < 99 }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.iata < $1.0.iata }
            .prefix(limit).map { $0.0 }
    }

    /// Airlines matching a query by IATA / ICAO / name prefix.
    func searchAirlines(_ query: String, limit: Int = 12) -> [AirlineRef] {
        let q = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard q.count >= 1 else { return [] }
        func rank(_ a: AirlineRef) -> Int {
            if a.iata == q { return 0 }
            if a.icao == q { return 1 }
            if a.name.uppercased().hasPrefix(q) { return 2 }
            if a.name.uppercased().contains(q) { return 3 }
            return 99
        }
        return airlines.map { ($0, rank($0)) }.filter { $0.1 < 99 }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.name < $1.0.name }
            .prefix(limit).map { $0.0 }
    }
}
```

- [ ] **Step 3: Write failing tests**

`ArcTests/ReferenceDataTests.swift`:

```swift
import XCTest
@testable import Arc

final class ReferenceDataTests: XCTestCase {
    private func fixture() -> ReferenceData {
        let airports = [
            AirportRef(iata: "ZRH", icao: "LSZH", name: "Zurich Airport", city: "Zurich",
                       country: "CH", lat: 47.4647, lon: 8.5492, tz: "Europe/Zurich"),
            AirportRef(iata: "ZAG", icao: "LDZA", name: "Zagreb Airport", city: "Zagreb",
                       country: "HR", lat: 45.743, lon: 16.0688, tz: "Europe/Zagreb"),
            AirportRef(iata: "JFK", icao: "KJFK", name: "John F Kennedy", city: "New York",
                       country: "US", lat: 40.6413, lon: -73.7781, tz: "America/New_York"),
        ]
        let airlines = [
            AirlineRef(iata: "LX", icao: "SWR", name: "Swiss", callsign: "SWISS", country: "CH"),
            AirlineRef(iata: "U2", icao: "EZY", name: "easyJet", callsign: "EASY", country: "GB"),
        ]
        return ReferenceData(airports: airports, airlines: airlines)
    }

    func testAirportLookupByIATA() {
        XCTAssertEqual(fixture().airport("zrh")?.city, "Zurich")
    }

    func testTimezoneResolves() {
        XCTAssertEqual(fixture().timezone("JFK")?.identifier, "America/New_York")
    }

    func testAirportSearchRanksExactIATAFirst() {
        let r = fixture().searchAirports("ZA")   // ZAG prefix, not ZRH
        XCTAssertEqual(r.first?.iata, "ZAG")
    }

    func testAirportSearchByCity() {
        XCTAssertEqual(fixture().searchAirports("New York").first?.iata, "JFK")
    }

    func testAirlineSearchByCode() {
        XCTAssertEqual(fixture().searchAirlines("LX").first?.name, "Swiss")
    }

    func testAirlineSearchByName() {
        XCTAssertEqual(fixture().searchAirlines("easy").first?.iata, "U2")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
cd /Users/carl/Downloads/Arc && xcodegen generate && \
xcodebuild -project Arc.xcodeproj -scheme Arc \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test 2>&1 | tail -20
```
Expected: `Test Suite 'ReferenceDataTests' passed`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: reference-data loader with airport/airline search"
```

---

## Task 4: Adaptive theme tokens

**Files:**
- Create: `Arc/DesignSystem/ArcTheme.swift`
- Modify: `Arc/DesignSystem/ArcDesign.swift`

- [ ] **Step 1: Write the theme**

`Arc/DesignSystem/ArcTheme.swift`:

```swift
import SwiftUI

/// Flighty-parity design tokens. Built on semantic system colors + materials so
/// light/dark tracks the system automatically.
enum ArcTheme {
    // Status
    static let onTime = Color(red: 0.20, green: 0.78, blue: 0.35)   // #34C759
    static let late   = Color(red: 1.00, green: 0.23, blue: 0.19)   // #FF3B30
    static let action = Color(red: 0.04, green: 0.52, blue: 1.00)   // #0A84FF
    static let gate   = Color(red: 1.00, green: 0.80, blue: 0.00)   // #FFCC00

    static func timeColor(late: Bool) -> Color { late ? Self.late : Self.onTime }

    // Type scale (system SF Pro)
    static let screenTitle = Font.system(size: 34, weight: .heavy)
    static let sheetTitle  = Font.system(size: 22, weight: .bold)
    static let bigTime     = Font.system(size: 40, weight: .regular)
    static let iata        = Font.system(size: 16, weight: .bold)
    static let cityPair    = Font.system(size: 22, weight: .semibold)
    static let bodyEmph    = Font.system(size: 15, weight: .semibold)
    static let caption     = Font.system(size: 13, weight: .regular)
    static let captionEmph = Font.system(size: 13, weight: .semibold)
    static let tag         = Font.system(size: 13, weight: .medium)
    static let countdownNum = Font.system(size: 30, weight: .heavy)
    static let countdownUnit = Font.system(size: 11, weight: .bold)

    // Metrics
    static let sheetCorner: CGFloat = 22
    static let cardCorner: CGFloat = 14
    static let gatePillCorner: CGFloat = 8
    static let screenPad: CGFloat = 20
}

/// Yellow gate pill used in flight detail (`↗ C8`).
struct GatePill: View {
    let arrow: String   // "arrow.up.right" or "arrow.down.right"
    let gate: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: arrow).font(.system(size: 11, weight: .bold))
            Text(gate).font(.system(size: 17, weight: .bold))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(ArcTheme.gate, in: RoundedRectangle(cornerRadius: ArcTheme.gatePillCorner))
    }
}
```

- [ ] **Step 2: Re-point the legacy tokens to adaptive values**

Replace the entire body of `Arc/DesignSystem/ArcDesign.swift` (keep the enum names so frozen screens compile, but make them adaptive and non-dark):

```swift
import SwiftUI

/// Legacy token names retained for the (frozen) Friends/Settings screens.
/// New work should use `ArcTheme`. These now resolve to adaptive system colors.
enum ArcColor {
    static let accent = ArcTheme.action
    static let accentDim = ArcTheme.action.opacity(0.3)
    static let bg = Color(.systemBackground)
    static let card = Color(.secondarySystemBackground)
    static let text = Color(.label)
    static let textMuted = Color(.secondaryLabel)
    static let textDim = Color(.tertiaryLabel)
    static let border = Color(.separator)

    static let onTime = ArcTheme.onTime
    static let delayed = Color(red: 1.0, green: 0.58, blue: 0.0)
    static let cancelled = ArcTheme.late
    static let landed = ArcTheme.onTime

    static func statusColor(for status: FlightStatus, delay: Int = 0) -> Color {
        switch status {
        case .scheduled: delay > 0 ? delayed : onTime
        case .active: delay > 15 ? delayed : onTime
        case .landed: onTime
        case .cancelled: cancelled
        case .diverted: delayed
        }
    }
}

enum ArcType {
    static let heroLarge = Font.system(size: 34, weight: .heavy, design: .rounded)
    static let heroSmall = Font.system(size: 24, weight: .bold, design: .rounded)
    static let title = Font.system(size: 18, weight: .bold)
    static let body = Font.system(size: 15, weight: .regular)
    static let bodyEmph = Font.system(size: 15, weight: .semibold)
    static let caption = Font.system(size: 12, weight: .regular)
    static let captionEmph = Font.system(size: 12, weight: .semibold)
    static let mono = Font.system(size: 16, weight: .semibold, design: .monospaced)
    static let monoSmall = Font.system(size: 13, weight: .medium, design: .monospaced)
    static let data = Font.system(size: 28, weight: .heavy, design: .rounded)
}

enum ArcRadius {
    static let card: CGFloat = 16
    static let button: CGFloat = 12
    static let small: CGFloat = 8
}

enum ArcSpace {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let screen: CGFloat = 16
}
```

- [ ] **Step 3: Build (frozen screens must still compile)**

Run:
```bash
cd /Users/carl/Downloads/Arc && xcodebuild -project Arc.xcodeproj -scheme Arc \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`. (Note: `FlightDetailView`/`PassportStatsView` use `.glassEffect(...)`; that still compiles on iOS 26. They get replaced in later plans.)

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: adaptive light/dark theme tokens (ArcTheme)"
```

---

## Task 5: Airline branding + aircraft image mapping (TDD)

**Files:**
- Create: `Arc/Services/AirlineBranding.swift`
- Create: `Arc/Services/AircraftImage.swift`
- Create: `Arc/Components/AirlineLogoView.swift`
- Test: `ArcTests/BrandingTests.swift`

- [ ] **Step 1: Write branding + aircraft mapping**

`Arc/Services/AirlineBranding.swift`:

```swift
import SwiftUI

/// Maps an airline IATA code to a bundled logo asset (if present) and a
/// deterministic tail color + initials for the fallback chip.
enum AirlineBranding {
    /// Asset-catalog name for a bundled logo, or nil to use the fallback chip.
    static func logoAssetName(iata: String) -> String? {
        let key = iata.uppercased()
        return UIImage(named: "airline-\(key)") != nil ? "airline-\(key)" : nil
    }

    /// Deterministic tail color derived from the IATA code (stable per airline).
    static func tailColor(iata: String) -> Color {
        let palette: [Color] = [
            .red, .blue, .orange, .green, .purple, .pink, .teal, .indigo
        ]
        let sum = iata.uppercased().unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }

    static func initials(iata: String) -> String { String(iata.uppercased().prefix(2)) }
}
```

`Arc/Services/AircraftImage.swift`:

```swift
import Foundation

/// Maps a free-text aircraft type/model to a bundled side-silhouette asset name.
enum AircraftImage {
    static func assetName(for type: String?) -> String {
        guard let t = type?.uppercased() else { return "aircraft-generic" }
        let map: [(String, String)] = [
            ("A321", "aircraft-a321"), ("A320", "aircraft-a320"), ("A319", "aircraft-a320"),
            ("A318", "aircraft-a320"), ("A330", "aircraft-a330"), ("A350", "aircraft-a350"),
            ("A340", "aircraft-a340"), ("A380", "aircraft-a380"),
            ("777", "aircraft-b777"), ("787", "aircraft-b787"), ("767", "aircraft-b767"),
            ("757", "aircraft-b757"), ("737", "aircraft-b737"), ("747", "aircraft-b747"),
            ("E19", "aircraft-e190"), ("E17", "aircraft-e190"), ("E75", "aircraft-e190"),
            ("CRJ", "aircraft-crj"), ("AT7", "aircraft-atr"), ("DH8", "aircraft-atr"),
        ]
        for (needle, asset) in map where t.contains(needle) { return asset }
        return "aircraft-generic"
    }
}
```

- [ ] **Step 2: Write the fallback logo view**

`Arc/Components/AirlineLogoView.swift`:

```swift
import SwiftUI

/// Renders a bundled airline logo if available, else a tail-color initials chip.
struct AirlineLogoView: View {
    let iata: String
    var size: CGFloat = 28

    var body: some View {
        if let asset = AirlineBranding.logoAssetName(iata: iata) {
            Image(asset).resizable().scaledToFit().frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(AirlineBranding.tailColor(iata: iata))
                .frame(width: size, height: size)
                .overlay(
                    Text(AirlineBranding.initials(iata: iata))
                        .font(.system(size: size * 0.4, weight: .heavy))
                        .foregroundStyle(.white)
                )
        }
    }
}
```

- [ ] **Step 3: Write failing tests**

`ArcTests/BrandingTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import Arc

final class BrandingTests: XCTestCase {
    func testTailColorIsDeterministic() {
        XCTAssertEqual(AirlineBranding.tailColor(iata: "LX"), AirlineBranding.tailColor(iata: "lx"))
    }

    func testInitials() {
        XCTAssertEqual(AirlineBranding.initials(iata: "u2"), "U2")
    }

    func testAircraftMapping() {
        XCTAssertEqual(AircraftImage.assetName(for: "Airbus A321neo"), "aircraft-a321")
        XCTAssertEqual(AircraftImage.assetName(for: "Boeing 737-800"), "aircraft-b737")
        XCTAssertEqual(AircraftImage.assetName(for: nil), "aircraft-generic")
        XCTAssertEqual(AircraftImage.assetName(for: "Unknown Type"), "aircraft-generic")
    }
}
```

- [ ] **Step 4: Run tests**

Run:
```bash
cd /Users/carl/Downloads/Arc && xcodegen generate && \
xcodebuild -project Arc.xcodeproj -scheme Arc \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test 2>&1 | tail -15
```
Expected: `Test Suite 'BrandingTests' passed`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: airline branding + aircraft image mapping with fallbacks"
```

---

## Task 6: Geo math for great-circle routes + fit region (TDD)

**Files:**
- Create: `Arc/Map/GeoMath.swift`
- Test: `ArcTests/GeoMathTests.swift`

- [ ] **Step 1: Write the geo helpers**

`Arc/Map/GeoMath.swift`:

```swift
import Foundation
import CoreLocation
import MapKit

enum GeoMath {
    /// Samples `samples` intermediate points along the great circle from a to b
    /// (inclusive of both endpoints) so a MapPolyline renders a curved arc.
    static func greatCircle(from a: CLLocationCoordinate2D,
                            to b: CLLocationCoordinate2D,
                            samples: Int = 64) -> [CLLocationCoordinate2D] {
        let n = max(2, samples)
        let lat1 = a.latitude * .pi / 180, lon1 = a.longitude * .pi / 180
        let lat2 = b.latitude * .pi / 180, lon2 = b.longitude * .pi / 180
        let dLat = lat2 - lat1, dLon = lon2 - lon1
        let hav = sin(dLat/2)*sin(dLat/2) + cos(lat1)*cos(lat2)*sin(dLon/2)*sin(dLon/2)
        let d = 2 * asin(min(1, sqrt(hav)))
        guard d > 1e-9 else { return [a, b] }
        var pts: [CLLocationCoordinate2D] = []
        for i in 0...n {
            let f = Double(i) / Double(n)
            let A = sin((1-f)*d) / sin(d)
            let B = sin(f*d) / sin(d)
            let x = A*cos(lat1)*cos(lon1) + B*cos(lat2)*cos(lon2)
            let y = A*cos(lat1)*sin(lon1) + B*cos(lat2)*sin(lon2)
            let z = A*sin(lat1) + B*sin(lat2)
            let lat = atan2(z, sqrt(x*x + y*y))
            let lon = atan2(y, x)
            pts.append(.init(latitude: lat*180/(.pi), longitude: lon*180/(.pi)))
        }
        return pts
    }

    /// A region that fits all given coordinates with padding, clamped to sane spans.
    static func region(fitting coords: [CLLocationCoordinate2D],
                       paddingFactor: Double = 1.4) -> MKCoordinateRegion? {
        guard !coords.isEmpty else { return nil }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        let center = CLLocationCoordinate2D(latitude: (minLat+maxLat)/2, longitude: (minLon+maxLon)/2)
        let span = MKCoordinateSpan(
            latitudeDelta: max(2, (maxLat-minLat) * paddingFactor),
            longitudeDelta: max(2, (maxLon-minLon) * paddingFactor)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}
```

- [ ] **Step 2: Write failing tests**

`ArcTests/GeoMathTests.swift`:

```swift
import XCTest
import CoreLocation
@testable import Arc

final class GeoMathTests: XCTestCase {
    func testGreatCircleEndpointsPreserved() {
        let a = CLLocationCoordinate2D(latitude: 47.46, longitude: 8.55)   // ZRH
        let b = CLLocationCoordinate2D(latitude: 40.64, longitude: -73.78) // JFK
        let pts = GeoMath.greatCircle(from: a, to: b, samples: 32)
        XCTAssertEqual(pts.count, 33)
        XCTAssertEqual(pts.first!.latitude, a.latitude, accuracy: 0.01)
        XCTAssertEqual(pts.last!.longitude, b.longitude, accuracy: 0.01)
    }

    func testGreatCircleBowsNorthOnTransatlantic() {
        let a = CLLocationCoordinate2D(latitude: 47.46, longitude: 8.55)
        let b = CLLocationCoordinate2D(latitude: 40.64, longitude: -73.78)
        let pts = GeoMath.greatCircle(from: a, to: b, samples: 32)
        let mid = pts[16]
        // The arc midpoint sits north of the straight-line latitude average (~44).
        XCTAssertGreaterThan(mid.latitude, 47.0)
    }

    func testRegionFitsCoordinates() {
        let region = GeoMath.region(fitting: [
            .init(latitude: 47.46, longitude: 8.55),
            .init(latitude: 40.64, longitude: -73.78),
        ])!
        XCTAssertEqual(region.center.latitude, 44.05, accuracy: 0.5)
        XCTAssertGreaterThan(region.span.longitudeDelta, 80)
    }

    func testRegionNilForEmpty() {
        XCTAssertNil(GeoMath.region(fitting: []))
    }
}
```

- [ ] **Step 3: Run tests**

Run:
```bash
cd /Users/carl/Downloads/Arc && xcodegen generate && \
xcodebuild -project Arc.xcodeproj -scheme Arc \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test 2>&1 | tail -15
```
Expected: `Test Suite 'GeoMathTests' passed`.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: great-circle sampling + fit-region geo math"
```

---

## Task 7: Map controller + shared map view (replaces GlobeView)

**Files:**
- Create: `Arc/Map/MapController.swift`
- Create: `Arc/Map/ArcMapView.swift`
- Delete: `Arc/Globe/GlobeView.swift`

- [ ] **Step 1: Write the controller**

`Arc/Map/MapController.swift`:

```swift
import SwiftUI
import MapKit

@MainActor
@Observable
final class MapController {
    var position: MapCameraPosition = .automatic
    var style: MapStyleKind = .standard

    enum MapStyleKind { case standard, hybrid }

    /// Frame the camera to fit all given flights' routes.
    func fitAll(_ flights: [Flight]) {
        var coords: [CLLocationCoordinate2D] = []
        for f in flights where f.departureLat != 0 && f.arrivalLat != 0 {
            coords.append(.init(latitude: f.departureLat, longitude: f.departureLon))
            coords.append(.init(latitude: f.arrivalLat, longitude: f.arrivalLon))
        }
        if let region = GeoMath.region(fitting: coords) {
            withAnimation(.easeInOut(duration: 0.6)) { position = .region(region) }
        } else {
            position = .automatic
        }
    }

    /// Frame the camera on a single flight's route.
    func focus(on flight: Flight) {
        let coords = GeoMath.greatCircle(
            from: .init(latitude: flight.departureLat, longitude: flight.departureLon),
            to: .init(latitude: flight.arrivalLat, longitude: flight.arrivalLon))
        if let region = GeoMath.region(fitting: coords, paddingFactor: 1.8) {
            withAnimation(.easeInOut(duration: 0.6)) { position = .region(region) }
        }
    }

    /// Follow a live plane position (used in-flight).
    func follow(lat: Double, lon: Double) {
        withAnimation(.easeInOut(duration: 0.8)) {
            position = .region(MKCoordinateRegion(
                center: .init(latitude: lat, longitude: lon),
                span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 30)))
        }
    }
}
```

- [ ] **Step 2: Write the shared map view**

`Arc/Map/ArcMapView.swift`:

```swift
import SwiftUI
import MapKit

/// The single shared map. Renders each flight's great-circle route, airport pins,
/// and (for active flights) the live plane. Camera driven by `MapController`.
struct ArcMapView: View {
    let flights: [Flight]
    @Bindable var controller: MapController

    var body: some View {
        Map(position: $controller.position) {
            ForEach(flights) { flight in
                if flight.departureLat != 0 && flight.arrivalLat != 0 {
                    let dep = CLLocationCoordinate2D(latitude: flight.departureLat, longitude: flight.departureLon)
                    let arr = CLLocationCoordinate2D(latitude: flight.arrivalLat, longitude: flight.arrivalLon)

                    MapPolyline(coordinates: GeoMath.greatCircle(from: dep, to: arr))
                        .stroke(ArcTheme.action, style: StrokeStyle(lineWidth: 3, lineCap: .round))

                    Annotation("", coordinate: dep) { endpointDot }
                    Annotation("", coordinate: arr) { endpointDot }

                    if flight.isActive, let lat = flight.liveLat, let lon = flight.liveLon {
                        Annotation("", coordinate: .init(latitude: lat, longitude: lon)) {
                            Image(systemName: "airplane")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(.white)
                                .rotationEffect(.degrees((flight.liveHeading ?? 0) - 90))
                                .shadow(radius: 2)
                        }
                    }
                }
            }
        }
        .mapStyle(controller.style == .hybrid ? .hybrid(elevation: .realistic) : .standard(elevation: .realistic))
        .mapControlVisibility(.hidden)
    }

    private var endpointDot: some View {
        Circle().fill(.white).frame(width: 10, height: 10)
            .overlay(Circle().stroke(ArcTheme.action, lineWidth: 3))
    }
}
```

- [ ] **Step 3: Delete GlobeView and fix references**

`GlobeView` is used in `FlightsHomeView` and `PassportStatsView`, both of which get replaced in later plans. For now, remove the file and temporarily point those two screens at `ArcMapView` so the project compiles:

```bash
git rm Arc/Globe/GlobeView.swift
```

In `Arc/Features/Flights/FlightsHomeView.swift`, replace `GlobeView(flights: allFlights)` (line ~21) with:
```swift
ArcMapView(flights: allFlights, controller: MapController())
```
In `Arc/Features/Passport/PassportStatsView.swift`, replace `GlobeView(flights: completedFlights)` (line ~59) with:
```swift
ArcMapView(flights: completedFlights, controller: MapController())
```

(These two screens are fully rebuilt in the My Flights and Passport plans; this is only to keep the build green.)

- [ ] **Step 4: Build**

Run:
```bash
cd /Users/carl/Downloads/Arc && xcodegen generate && \
xcodebuild -project Arc.xcodeproj -scheme Arc \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: shared MapController + ArcMapView (retire GlobeView)"
```

---

## Task 8: Custom draggable bottom sheet

**Files:**
- Create: `Arc/Components/BottomSheet.swift`

- [ ] **Step 1: Write the component**

`Arc/Components/BottomSheet.swift`:

```swift
import SwiftUI

/// A draggable, multi-detent bottom sheet that sits in a ZStack over the map,
/// so a floating tab bar can be layered above it. Detents are fractions of height.
struct BottomSheet<Content: View>: View {
    enum Detent: CaseIterable { case small, medium, large
        var fraction: CGFloat { switch self { case .small: 0.30; case .medium: 0.58; case .large: 0.92 } }
    }

    @Binding var detent: Detent
    @ViewBuilder var content: () -> Content
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let target = h * detent.fraction
            let offset = max(h * 0.08, min(h * 0.92, target - drag))

            VStack(spacing: 0) {
                Capsule().fill(Color(.tertiaryLabel))
                    .frame(width: 36, height: 5).padding(.top, 8).padding(.bottom, 6)
                content()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: h)
            .background(.regularMaterial,
                        in: UnevenRoundedRectangle(topLeadingRadius: ArcTheme.sheetCorner,
                                                   topTrailingRadius: ArcTheme.sheetCorner))
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: ArcTheme.sheetCorner,
                                       topTrailingRadius: ArcTheme.sheetCorner)
                    .stroke(Color(.separator).opacity(0.5), lineWidth: 0.5)
                    .frame(height: h)
            }
            .offset(y: h - offset)
            .gesture(
                DragGesture()
                    .updating($drag) { value, state, _ in state = -value.translation.height }
                    .onEnded { value in snap(to: value.predictedEndTranslation.height, height: h) }
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: detent)
        }
        .ignoresSafeArea()
    }

    private func snap(to predicted: CGFloat, height: CGFloat) {
        let current = height * detent.fraction - predicted
        let nearest = Detent.allCases.min {
            abs($0.fraction * height - current) < abs($1.fraction * height - current)
        } ?? .medium
        detent = nearest
    }
}
```

- [ ] **Step 2: Build**

Run:
```bash
cd /Users/carl/Downloads/Arc && xcodegen generate && \
xcodebuild -project Arc.xcodeproj -scheme Arc \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: custom draggable multi-detent BottomSheet"
```

---

## Task 9: Floating pill tab bar

**Files:**
- Create: `Arc/Components/ArcTabBar.swift`

- [ ] **Step 1: Write the component**

`Arc/Components/ArcTabBar.swift`:

```swift
import SwiftUI

enum ArcTab: CaseIterable {
    case myFlights, friends, passport
    var title: String { switch self { case .myFlights: "My Flights"; case .friends: "Friends"; case .passport: "Passport" } }
    var icon: String { switch self { case .myFlights: "airplane"; case .friends: "person.2.fill"; case .passport: "book.pages.fill" } }
}

/// Flighty-style floating pill: 3 tabs in a capsule + a separate circular search button.
struct ArcTabBar: View {
    @Binding var selection: ArcTab
    var onSearch: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(ArcTab.allCases, id: \.self) { tab in
                    Button { selection = tab } label: { item(tab) }
                        .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color(.separator).opacity(0.4), lineWidth: 0.5))

            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 54, height: 54)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().stroke(Color(.separator).opacity(0.4), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    private func item(_ tab: ArcTab) -> some View {
        let active = selection == tab
        return VStack(spacing: 2) {
            Image(systemName: tab.icon).font(.system(size: 18, weight: .semibold))
            Text(tab.title).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(active ? ArcTheme.action : Color(.secondaryLabel))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(active ? ArcTheme.action.opacity(0.12) : .clear, in: Capsule())
    }
}
```

- [ ] **Step 2: Build**

Run:
```bash
cd /Users/carl/Downloads/Arc && xcodebuild -project Arc.xcodeproj -scheme Arc \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: floating pill ArcTabBar (3 tabs + search)"
```

---

## Task 10: Root coordinator + stub sheets + wire the app

**Files:**
- Create: `Arc/Features/Root/ArcRootView.swift`
- Create: `Arc/Features/Root/StubSheets.swift`
- Modify: `Arc/ArcApp.swift`
- Delete: `Arc/Features/Flights/RootTabView.swift`

- [ ] **Step 1: Write temporary stub sheet bodies**

`Arc/Features/Root/StubSheets.swift` (these are replaced by real screens in later plans; they exist so the shell runs and each tab shows something real):

```swift
import SwiftUI
import SwiftData

struct MyFlightsSheet: View {
    @Query(sort: \Flight.scheduledDeparture) private var flights: [Flight]
    var onSelect: (Flight) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("My Flights").font(ArcTheme.screenTitle)
            if flights.isEmpty {
                Text("No flights yet — tap search to add one.")
                    .font(ArcTheme.caption).foregroundStyle(.secondary)
            } else {
                ForEach(flights) { f in
                    Button { onSelect(f) } label: {
                        HStack {
                            AirlineLogoView(iata: String(f.flightNumber.prefix(2)))
                            Text("\(f.departureIATA) → \(f.arrivalIATA)").font(ArcTheme.bodyEmph)
                            Spacer()
                            Text(f.flightNumber).font(ArcTheme.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(.horizontal, ArcTheme.screenPad)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FriendsSheet: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("Friends").font(ArcTheme.screenTitle)
            Text("Social is deferred — coming after core screens.")
                .font(ArcTheme.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, ArcTheme.screenPad)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PassportSheet: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("Passport").font(ArcTheme.screenTitle)
            Text("Stats coming in the Passport screen plan.")
                .font(ArcTheme.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, ArcTheme.screenPad)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 2: Write the root coordinator**

`Arc/Features/Root/ArcRootView.swift`:

```swift
import SwiftUI
import SwiftData

struct ArcRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Flight.scheduledDeparture) private var allFlights: [Flight]

    @State private var controller = MapController()
    @State private var tab: ArcTab = .myFlights
    @State private var detent: BottomSheet<AnyView>.Detent = .medium
    @State private var showAdd = false
    @State private var detailFlight: Flight?

    var body: some View {
        ZStack(alignment: .bottom) {
            ArcMapView(flights: mapFlights, controller: controller)
                .ignoresSafeArea()

            BottomSheet(detent: $detent) { sheetContent }

            ArcTabBar(selection: $tab, onSearch: { showAdd = true })
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $showAdd) {
            AddFlightStubSheet()
                .presentationDetents([.large])
        }
        .sheet(item: $detailFlight) { flight in
            FlightDetailStubSheet(flight: flight)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .onChange(of: allFlights.map(\.id)) { controller.fitAll(mapFlights) }
        .onChange(of: detailFlight) { _, f in if let f { controller.focus(on: f) } }
        .onAppear { controller.fitAll(mapFlights) }
    }

    private var mapFlights: [Flight] { allFlights.filter { $0.isUpcoming || $0.isActive } }

    @ViewBuilder private var sheetContent: some View {
        switch tab {
        case .myFlights: MyFlightsSheet { detailFlight = $0 }
        case .friends: FriendsSheet()
        case .passport: PassportSheet()
        }
    }
}

// Temporary detail/add stubs (real versions arrive in later plans).
struct AddFlightStubSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            HStack { Text("Add Flight").font(ArcTheme.screenTitle); Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 28)).foregroundStyle(.secondary) } }
            Text("Search flow arrives in the Add-Flight plan.").font(ArcTheme.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(20)
    }
}

struct FlightDetailStubSheet: View {
    let flight: Flight
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(flight.departureIATA) → \(flight.arrivalIATA)").font(ArcTheme.sheetTitle)
            Text(flight.flightNumber).font(ArcTheme.caption).foregroundStyle(.secondary)
            Text("Full detail arrives in the Flight-Detail plan.").font(ArcTheme.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

Note: `BottomSheet<AnyView>.Detent` in the `@State` line is only to name the enum type; `Detent` is generic-independent, so this compiles. If the compiler objects, change the state to `@State private var detent: BottomSheet<EmptyView>.Detent = .medium` — the enum is the same regardless of `Content`.

- [ ] **Step 3: Point the app at the new root**

Replace `Arc/ArcApp.swift` body's `RootTabView()` with `ArcRootView()`:

```swift
import SwiftUI
import SwiftData

@main
struct ArcApp: App {
    @StateObject private var tracker = FlightTracker.shared
    var body: some Scene {
        WindowGroup {
            ArcRootView()
                .onAppear { ArcNotifications.requestPermission() }
        }
        .modelContainer(for: [Flight.self, Airport.self])
    }
}
```

- [ ] **Step 4: Delete the old root (removes duplicate Add-Flight entry + 4-tab model)**

```bash
git rm Arc/Features/Flights/RootTabView.swift
```

- [ ] **Step 5: Build**

Run:
```bash
cd /Users/carl/Downloads/Arc && xcodegen generate && \
xcodebuild -project Arc.xcodeproj -scheme Arc \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -8
```
Expected: `** BUILD SUCCEEDED **`. If `detent` type inference fails, apply the `EmptyView` note from Step 2.

- [ ] **Step 6: Boot the simulator, install, screenshot (light + dark)**

Run:
```bash
cd /Users/carl/Downloads/Arc
DEV=$(xcrun simctl list devices available | grep -m1 'iPhone 17 Pro (' | grep -oE '[0-9A-F-]{36}')
xcrun simctl boot "$DEV" 2>/dev/null; sleep 3
APP=$(xcodebuild -project Arc.xcodeproj -scheme Arc -destination "id=$DEV" -showBuildSettings 2>/dev/null | awk '/TARGET_BUILD_DIR/{d=$3} /WRAPPER_NAME/{w=$3} END{print d"/"w}')
xcrun simctl install "$DEV" "$APP"
xcrun simctl launch "$DEV" com.arc.flighttracker; sleep 4
xcrun simctl ui "$DEV" appearance light; sleep 1
xcrun simctl io "$DEV" screenshot /tmp/arc-foundation-light.png
xcrun simctl ui "$DEV" appearance dark; sleep 1
xcrun simctl io "$DEV" screenshot /tmp/arc-foundation-dark.png
echo "shots: /tmp/arc-foundation-light.png /tmp/arc-foundation-dark.png"
```
Expected: two screenshots showing the shared map, a bottom sheet with "My Flights", and the floating pill (light sheet in light mode, dark frosted sheet in dark mode).

- [ ] **Step 7: Read the screenshots and verify**

Use the Read tool on `/tmp/arc-foundation-light.png` and `/tmp/arc-foundation-dark.png`. Confirm: map fills the screen; pill has 3 tabs + a circular search button; the sheet is frosted-white in light and frosted-dark in dark; tapping the search button opens the Add stub; tapping a flight opens the detail stub. Fix layout issues before committing.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat: ArcRootView shell — shared map + bottom sheet + pill tab bar"
```

---

## Self-review — spec coverage

- Adaptive light/dark theme → Task 4 (`ArcTheme` + adaptive legacy tokens), verified light+dark in Task 10 Step 6–7. ✓
- Bundled offline airport/airline data + instant search → Tasks 2, 3. ✓
- Curated logos + aircraft silhouettes (mapping + fallback; art dropped in later screen plans) → Task 5. ✓
- One shared map + camera controller (globe when zoomed out is native MapKit) → Tasks 6, 7. ✓
- Custom draggable bottom sheet (fixes fixed-height issue) → Task 8. ✓
- Floating pill tab bar, 3 tabs + search (fixes 4-tab model) → Task 9. ✓
- Root coordinator; Detail + Add as presented sheets over the map (fixes pushed-detail + duplicate Add entry) → Task 10. ✓
- Retire GlobeView / RootTabView (consolidation) → Tasks 7, 10. ✓

**Deferred to later plans (intentional):** real My Flights cards, full Flight Detail, multi-step Add Flight, Passport cards + list, in-flight live tracking, widgets/Live Activity, AeroDataBox Worker wiring. Stubs stand in so the shell runs.

**Type consistency:** `MapController` methods `fitAll`/`focus`/`follow` used consistently in Task 7 & 10. `BottomSheet.Detent` referenced in Task 10 matches Task 8. `AirlineLogoView`, `AirlineBranding`, `AircraftImage` names consistent across Tasks 5 & 10. `ReferenceData` init seam used in Task 3 tests matches the class in Task 3. No undefined references.
