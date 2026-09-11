# The Row Becomes the Detail — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A My Trips row tap morphs the row's elements into the flight detail inside the same bottom sheet, with a spring bounce, and the X plays it in reverse.

**Architecture:** `ArcRootView.detailFlight` stays the source of truth. Each tab's `BottomSheet` content becomes an if/else: the tab content when no detail is open, `FlightDetailView` when one is. Row and detail elements share `matchedGeometryEffect` ids in one namespace handed down through the environment, so the if/else switch under a spring animation is the morph. A small value type owns the detent bookkeeping.

**Tech Stack:** SwiftUI (iOS 26 target), SwiftData, XCTest. Build/test with `xcodegen generate` then `xcodebuild test -scheme Arc -destination 'platform=iOS Simulator,id=03AC5F6B-176A-43E3-AFD2-925EC03B47CB' -derivedDataPath ~/Library/Developer/ArcSimBuild`. Run `xcodegen generate` after adding any file.

Spec: `docs/superpowers/specs/2026-09-11-detail-morph-design.md`.

---

## File map

- Create `Arc/Features/Root/DetailPresentation.swift` — detent bookkeeping value type.
- Create `Arc/Components/Morph.swift` — `MorphElement`, environment key for the namespace, `.morph(...)` view modifier, `ArcTheme.morph` spring.
- Create `ArcTests/DetailPresentationTests.swift`, `ArcTests/MorphTests.swift`.
- Modify `Arc/Components/BottomSheet.swift` — programmatic detent changes animate.
- Modify `Arc/Features/Flights/FlightRowCard.swift` — tag five elements.
- Modify `Arc/Features/Detail/FlightDetailView.swift` — tag counterparts, `onClose`, sections rise in, pull-down close.
- Modify `Arc/Features/Root/ArcRootView.swift` — delete the detail sheet, render the detail in `tabSurface`, `openDetail`/`closeDetail`.

---

### Task 1: Detent bookkeeping

**Files:**
- Create: `Arc/Features/Root/DetailPresentation.swift`
- Test: `ArcTests/DetailPresentationTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Arc

/// Opening a detail raises the sheet to large and remembers where it was;
/// closing puts it back. A second open on top of the first keeps the
/// ORIGINAL height, so closing after a crossfade returns to where the user
/// started, not to "large".
final class DetailPresentationTests: XCTestCase {
    func testOpenRaisesToLargeAndRemembersTheStart() {
        var p = DetailPresentation()
        XCTAssertEqual(p.open(from: .medium), .large)
        XCTAssertEqual(p.close(), .medium)
    }

    func testCloseWithoutOpenRestoresNothing() {
        var p = DetailPresentation()
        XCTAssertNil(p.close())
    }

    func testReplacingAnOpenDetailKeepsTheFirstRememberedHeight() {
        var p = DetailPresentation()
        _ = p.open(from: .small)
        _ = p.open(from: .large)
        XCTAssertEqual(p.close(), .small)
    }

    func testOpeningFromLargeRestoresLarge() {
        var p = DetailPresentation()
        XCTAssertEqual(p.open(from: .large), .large)
        XCTAssertEqual(p.close(), .large)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodegen generate -q && xcodebuild test ... -only-testing:ArcTests/DetailPresentationTests -quiet 2>&1 | grep error:`
Expected: `error: cannot find 'DetailPresentation' in scope`

- [ ] **Step 3: Implement**

```swift
/// The sheet's height around a flight detail: opening raises it to large
/// and remembers the height it had, closing restores that height. Replacing
/// one open detail with another keeps the first memory, so a crossfade
/// between two flights still closes back to where the user started.
struct DetailPresentation: Equatable {
    private(set) var detentBefore: SheetDetent?

    mutating func open(from current: SheetDetent) -> SheetDetent {
        if detentBefore == nil { detentBefore = current }
        return .large
    }

    mutating func close() -> SheetDetent? {
        defer { detentBefore = nil }
        return detentBefore
    }
}
```

- [ ] **Step 4: Run to verify it passes** — expected 4 passed.
- [ ] **Step 5: Commit** — `git add Arc/Features/Root/DetailPresentation.swift ArcTests/DetailPresentationTests.swift Arc.xcodeproj/project.pbxproj && git commit -m "The sheet remembers its height around a detail"`

---

### Task 2: Morph vocabulary

**Files:**
- Create: `Arc/Components/Morph.swift`
- Test: `ArcTests/MorphTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Arc

/// Every row tags the same five elements, so the ids must carry the flight:
/// two rows must never share a geometry group.
final class MorphTests: XCTestCase {
    func testIdsAreDistinctPerFlightAndPerElement() {
        let a = Flight(flightNumber: "LX14", date: .now)
        let b = Flight(flightNumber: "LX14", date: .now)
        XCTAssertNotEqual(MorphElement.logo.id(for: a), MorphElement.logo.id(for: b))
        XCTAssertNotEqual(MorphElement.logo.id(for: a), MorphElement.cities.id(for: a))
        XCTAssertEqual(MorphElement.route.id(for: a), MorphElement.route.id(for: a))
    }
}
```

- [ ] **Step 2: Run to verify it fails** — expected `cannot find 'MorphElement' in scope`.

- [ ] **Step 3: Implement**

```swift
import SwiftUI

/// The elements a My Trips row and the flight detail have in common. Each
/// pair shares a geometry id, so switching from list to detail under a
/// spring animation moves the element from its row frame to its detail
/// frame — the row becomes the detail.
enum MorphElement: String {
    case logo, number, cities, route, status

    func id(for flight: Flight) -> String { "\(rawValue)-\(flight.id.uuidString)" }

    /// Text steps up in size between row and detail; animating its frame
    /// would re-wrap it every frame, so text only travels, and the two sizes
    /// crossfade. The logo and the status block resize cleanly.
    var properties: MatchedGeometryProperties {
        switch self {
        case .logo, .status: .frame
        case .number, .cities, .route: .position
        }
    }
}

private struct MorphNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// Set once at the sheet; nil (previews, tests, friend sheets) means no morph.
    var morphNamespace: Namespace.ID? {
        get { self[MorphNamespaceKey.self] }
        set { self[MorphNamespaceKey.self] = newValue }
    }
}

private struct MorphModifier: ViewModifier {
    @Environment(\.morphNamespace) private var namespace
    let element: MorphElement
    let flight: Flight

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: element.id(for: flight), in: namespace,
                                          properties: element.properties, anchor: .leading)
        } else {
            content
        }
    }
}

extension View {
    func morph(_ element: MorphElement, for flight: Flight) -> some View {
        modifier(MorphModifier(element: element, flight: flight))
    }
}

extension ArcTheme {
    /// The one spring every part of the row-to-detail moment rides: the
    /// elements' travel, the sheet's rise, the sections' arrival. Damping
    /// under 1 is the small bounce on landing.
    static let morph: Animation = .spring(response: 0.42, dampingFraction: 0.72)
}
```

Check `ArcTheme` is a caseless enum or struct that accepts a static extension (`grep -n "enum ArcTheme\|struct ArcTheme" Arc`).

- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `git commit -m "The morph vocabulary: five shared elements, one spring"`

---

### Task 3: Programmatic detent changes animate

**Files:**
- Modify: `Arc/Components/BottomSheet.swift` (SheetChrome `.onChange(of: detent)`)

No unit test: pure view behaviour. Verified on the simulator in Task 7.

- [ ] **Step 1: Change the onChange**

Replace
```swift
        .onChange(of: detent) { _, newValue in
            guard dragBaseline == nil else { return }   // don't fight an active drag
            liveHeight = h * newValue.fraction
        }
```
with
```swift
        .onChange(of: detent) { _, newValue in
            guard dragBaseline == nil else { return }   // don't fight an active drag
            // A drag's snap already set liveHeight before assigning detent,
            // so this is a no-op for it. A PROGRAMMATIC detent — a detail
            // opening, a gate view lowering the sheet — is the one that
            // moves here, and it rides the morph spring so the sheet rises
            // with the elements rather than jumping ahead of them.
            withAnimation(ArcTheme.morph) { liveHeight = h * newValue.fraction }
        }
```
Update the `SheetChrome` doc comment's "no animation anywhere" sentence to say drag snapping is instant and programmatic detent changes animate.

- [ ] **Step 2: Build** — `xcodebuild build ... -quiet 2>&1 | grep error:` expected empty.
- [ ] **Step 3: Commit** — `git commit -m "A programmatic detent rides the morph spring"`

---

### Task 4: The row tags its elements

**Files:**
- Modify: `Arc/Features/Flights/FlightRowCard.swift`

- [ ] **Step 1: Tag five elements**

In `body`:
- `countdownBlock.frame(width: 52)` → `countdownBlock.frame(width: 52).morph(.status, for: flight)`
- `TripLogoView(...)` → append `.morph(.logo, for: flight)`
- wrap the `ViewThatFits { ... }` (three `numberText` variants) with `.morph(.number, for: flight)`
- `cityPair` → `cityPair.morph(.cities, for: flight)`
- `routeRow.padding(.top, 2)` → `routeRow.padding(.top, 2).morph(.route, for: flight)`

- [ ] **Step 2: Build; run `ArcTests/FlightDisplayTests` to confirm nothing about display changed** — expected pass.
- [ ] **Step 3: Commit** — `git commit -m "The row names the five elements it shares with the detail"`

---

### Task 5: The detail tags its counterparts, closes through a callback, rises its sections

**Files:**
- Modify: `Arc/Features/Detail/FlightDetailView.swift`

- [ ] **Step 1: `onClose` beside `dismiss`**

Add after `var onOpenFlight`:
```swift
    /// Inside the tab sheet the detail is not a presentation, so there is
    /// nothing for `dismiss` to dismiss: the root clears `detailFlight` and
    /// the morph plays in reverse. A friend's read-only preview is still a
    /// real sheet and falls back to `dismiss`.
    var onClose: (() -> Void)? = nil
```
and a helper:
```swift
    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
```
Replace both `dismiss()` calls (the header X and the delete confirmation) with `close()`.

- [ ] **Step 2: Tag counterparts**

In `header`: `TripLogoView(... size: 34)` → `.morph(.logo, for: flight)`; the `Text("\(flight.flightNumberSpaced) • \(flight.headerDateText)")` → `.morph(.number, for: flight)`; `cityPair` → `cityPair.morph(.cities, for: flight)`.
In `statusBanner`: `Text(flight.bannerHeadline)...contentTransition(.opacity)` → append `.morph(.status, for: flight)`.
In `body`: `endpointsCard` → `endpointsCard.morph(.route, for: flight)`.

- [ ] **Step 3: Sections rise in after the elements land**

Add state `@State private var sectionsIn = false`. In `body`, wrap everything in the `VStack(spacing: 18)` AFTER `statusBanner` in a `Group { ... }` and give it
```swift
                    .opacity(sectionsIn ? 1 : 0)
                    .offset(y: sectionsIn ? 0 : 16)
```
Add to the ScrollView:
```swift
            .onAppear {
                // The elements land first; the sections arrive just behind
                // them, so the eye follows the travel and then reads down.
                withAnimation(ArcTheme.morph.delay(0.08)) { sectionsIn = true }
            }
```
(keep the existing onAppear body for `-detailBottom` args inside the same closure).

- [ ] **Step 4: Pull-down closes**

On the ScrollView add:
```swift
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, overscroll in
                // Pulling the detail down past its top is the sheet-dismiss
                // habit; honour it with the same reverse the X plays. Only
                // when this detail is hosted in the tab sheet (onClose set):
                // a presented sheet already dismisses on its own drag.
                guard onClose != nil, overscroll < -60, !pulledClosed else { return }
                pulledClosed = true
                close()
            }
```
with `@State private var pulledClosed = false`.

Remove `.presentationDragIndicator(.visible)` (no presentation to indicate).

- [ ] **Step 5: Build, run the full suite** — expected all pass.
- [ ] **Step 6: Commit** — `git commit -m "The detail names its counterparts and closes through the root"`

---

### Task 6: The root hosts the detail in the sheet

**Files:**
- Modify: `Arc/Features/Root/ArcRootView.swift`

- [ ] **Step 1: State**

Replace `@State private var detailDetent: PresentationDetent = .large` with
```swift
    @State private var presentation = DetailPresentation()
    @Namespace private var morphNamespace
```

- [ ] **Step 2: Open and close go through two functions**

Add near `show(_:)`:
```swift
    /// The row becomes the detail: the same spring moves the elements,
    /// raises the sheet and, in `FlightDetailView`, brings the sections in.
    private func openDetail(_ flight: Flight) {
        withAnimation(ArcTheme.morph) {
            detailFlight = flight
            detent = presentation.open(from: detent)
        }
    }

    /// The exact reverse: elements travel back to the row, the sheet returns
    /// to the height it had before the tap. The ground view and gate marker
    /// belong to the detail and leave with it.
    private func closeDetail() {
        groundViewTask?.cancel()
        groundViewTask = nil
        controller.clearGateMarker()
        withAnimation(ArcTheme.morph) {
            detailFlight = nil
            if let restored = presentation.close() { detent = restored }
        }
        presentQueuedDetail()
    }
```

- [ ] **Step 3: Delete the detail sheet**

Remove the whole `.sheet(item: $detailFlight, onDismiss: {...}) { flight in ... }` block from `body`.

- [ ] **Step 4: Route every assignment**

- `show(_:)`: the branch `else if let current = detailFlight, current.id != flight.id { queuedDetail = flight; detailFlight = nil }` becomes part of the final `else { openDetail(flight) }` — delete the middle branch (a second flight crossfades over the first).
- `presentQueuedDetail`: `detailFlight = queued` → `openDetail(queued)`.
- `openDetailIfPending`: both `detailFlight = ...` → `openDetail(...)`.
- `MyFlightsView(onSelect: { detailFlight = $0 }, ...)` → `onSelect: { openDetail($0) }`.
- `PassportView { detailFlight = $0 }` → `PassportView { openDetail($0) }`.
- `showPlaneAtGate` and `showAirportView`: `detailDetent = .medium` → `withAnimation(ArcTheme.morph) { detent = .medium }`.
- `grep -n 'detailFlight = ' Arc/Features/Root/ArcRootView.swift` must show no remaining direct assignments.

- [ ] **Step 5: The sheet hosts the detail**

In `tabSurface`, replace
```swift
            BottomSheet(detent: $detent) { built.padding(.bottom, 56) }
                .offset(y: (detailFlight != nil || showAdd) ? 1500 : 0)
                .animation(.spring(duration: 0.45), value: detailFlight != nil || showAdd)
```
with
```swift
            BottomSheet(detent: $detent) {
                // The detail lives IN the sheet: the tab content leaves and
                // the detail arrives under one spring, and the five shared
                // elements travel between the two — the row becomes the
                // detail. Removing the tab content (rather than hiding it)
                // is what lets the row's elements be the morph's source.
                ZStack {
                    if let flight = detailFlight {
                        FlightDetailView(flight: flight,
                                         onShowAtGate: { f in showPlaneAtGate(f) },
                                         onShowAirport: { f in showAirportView(f) },
                                         onOpenFlight: { other in _ = show(other) },
                                         onClose: { closeDetail() })
                            .id(flight.id)
                            .transition(.opacity)
                    } else {
                        built.transition(.opacity)
                    }
                }
                .padding(.bottom, 56)
                .environment(\.morphNamespace, morphNamespace)
            }
            .offset(y: showAdd ? 1500 : 0)
            .animation(.spring(duration: 0.45), value: showAdd)
```

- [ ] **Step 6: Build.** If `ArcRootView.body` hits "unable to type-check this expression in reasonable time", move the `tabSurface` ZStack body into a `fileprivate struct SheetSurface: View` and call it — see `NotificationPrimerAlert` for the precedent.
- [ ] **Step 7: Run the full suite** — expected all pass.
- [ ] **Step 8: Commit** — `git commit -m "The row becomes the detail, inside the one sheet"`

---

### Task 7: Simulator verification (the spike, folded into the build)

**Files:** none. Uses `xcrun simctl` and the burst script in the scratchpad (`#!/bin/zsh`, `setopt nonomatch`, 28 shots at ~0.24 s, tiled with ffmpeg).

- [ ] **Step 1: Fresh install** — terminate, uninstall, install, `launch ... -seedDemo -uiNoPrompt`, tap Don't Allow on the location prompt.
- [ ] **Step 2: Row tap at medium** — burst while tapping the LX 14 row (row centre ≈ (219, 523) pt). Expect: list fades, logo/number/cities/route/countdown travel up and settle with a small overshoot, sheet rises to large with them, sections rise in behind. No frame where the settled detail is drawn before the elements arrive.
- [ ] **Step 3: X at large** — burst while tapping the header X (≈ (369, 103) pt). Expect the reverse, sheet back at medium.
- [ ] **Step 4: Pull-down** — open a detail, swipe down from (200, 400) to (200, 700). Expect the same reverse. If the sheet grabber intercepts instead, note it and keep only the X (spec allows).
- [ ] **Step 5: Row tap at large** — drag the sheet to large first, tap a row, then X. Expect the sheet to stay large throughout and remain large after close.
- [ ] **Step 6: No-row entry** — relaunch with `-uiNoPrompt -openDetail`. Expect the detail present at large, elements faded in without travel.
- [ ] **Step 7: Other leg** — open LX 1413, tap the connection card's other leg. Expect a crossfade to LX 8 with no sheet swap; X returns to the list at the pre-tap height.
- [ ] **Step 8: Gate view** — open an upcoming flight with a gate, tap "Terminal Map"; expect the sheet to lower to medium with the spring; X restores the pre-tap height.
- [ ] **Step 9: Record findings in the commit message of any fix, or in the final report.**

If Step 2 shows the elements skipping (List cell hosting breaks the matched frame), fallback: convert `MyFlightsView`'s `List` to `ScrollView { LazyVStack }`, replace `.swipeActions` with a context-menu Delete, and `.refreshable` with a `ScrollView.refreshable` (still supported on ScrollView). Commit separately.

---

## Self-review

- Spec coverage: container/state → Task 6; morph → Tasks 2, 4, 5, 6; closing (X + pull-down) → Tasks 5, 6; entry points → Task 6 step 4; map/camera → unchanged, gate/airport detent → Task 6 step 4; testing → Tasks 1, 2, 7; risks → Task 7 fallback and Task 6 step 6.
- Placeholders: none.
- Names: `DetailPresentation.open(from:)/close()`, `MorphElement.id(for:)`, `.morph(_:for:)`, `ArcTheme.morph`, `\.morphNamespace`, `openDetail`, `closeDetail`, `onClose` — consistent across tasks.
