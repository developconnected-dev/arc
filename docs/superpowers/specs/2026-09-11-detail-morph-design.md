# The row becomes the detail — design

Date: 2026-09-11. Status: implemented on `claude/detail-morph`; see "What the build taught" at the end.

## What changes for the user

Tapping a row in My Trips no longer swaps two sheets. Today the tab sheet
slides off the bottom of the screen while a system sheet rises with the
detail. After this change the tab sheet stays, its list fades, and the
tapped row's elements travel to their places at the top of the detail with a
small bounce as each lands. The sections below rise in beneath them while the
sheet grows to its large height. Closing plays the exact reverse and the sheet
returns to the height it had before the tap.

Nothing about the row or the detail *looks* different. This is a change in
how the detail appears and disappears, modelled on Soar's card expansion.

## Container and state

- `ArcRootView.detailFlight` stays the single source of truth for "which
  flight is open".
- The detail renders *inside* `BottomSheet`, above the tab content. The
  BottomSheet no longer slides away when `detailFlight` is set; it still
  slides away for the Add sheet (`showAdd`), unchanged.
- The tab content is faded to zero and hit-disabled while a detail is shown.
- The system `.sheet(item: $detailFlight)` in the root, the
  `detailDetent` state, and `FlightDetailView`'s use of `@Environment(\.dismiss)`
  are deleted. `FlightDetailView` gains an `onClose: () -> Void` that the X
  and the pull-down both call.
- Detent bookkeeping lives in a small value type (working name
  `DetailPresentation`): opening remembers the current `SheetDetent` and
  raises the sheet to `.large`; closing restores the remembered detent;
  opening another flight while one is open keeps the *originally* remembered
  detent. The gate and airport ground views, which today set
  `detailDetent = .medium`, set the tab sheet's detent to `.medium` instead.

## The morph

- One `Namespace` is created in the root and handed to `FlightRowCard` and
  `FlightDetailView` through the environment.
- Five element pairs share `matchedGeometryEffect` ids, each suffixed with
  the flight's id so rows never collide:
  1. airline logo (`TripLogoView`, 24 pt in the row, 34 pt in the header)
  2. flight number (row: "LX 14"; header: "LX 14 • Fri, 11 Sep")
  3. city pair (row 20 pt, detail 24 pt)
  4. route line (row "ZRH 14:09 → JFK 16:36") to the endpoints card
  5. countdown block to the status banner headline (the row's corner status
     has no counterpart and simply fades with the list)
- Only the *tapped* row is a source (`isSource: flight.id == detailFlight?.id`);
  every detail element is a source whenever the detail is shown.
- Animation: `.spring(response: 0.42, dampingFraction: 0.72)` on the state
  change. The damping below 1 is the bounce.
- The list fades out with `.easeOut(duration: 0.2)`.
- Sections below the header use `.transition(.opacity.combined(with: .offset(y: 16)))`
  on the same spring delayed by 0.08 s, so they arrive just after the
  elements settle.
- The sheet detent change to `.large` is inside the same `withAnimation`.

## Closing

- The X calls `onClose`; the root clears `detailFlight` inside the same
  spring. Because the state simply flips back, the reverse is automatic:
  sections fade and drop, elements travel back into the row (which is again
  the source), the list fades in, the detent restores.
- Pulling the detail's ScrollView more than 60 pt past its top also calls
  `onClose` (via `onScrollGeometryChange`). The spike must confirm that the
  BottomSheet's own drag gesture does not swallow this; if it does, the
  pull-down is dropped and only the X closes.

## Entry points without a row

Widget and notification taps, `arc://` links, the `-openDetail` launch
arguments, the Passport list, and "open the other leg" from a connection card
all set `detailFlight` exactly as they do today. With no matched source on
screen the elements spring into place without travelling and the sections
rise in the same way. Opening a second flight while one is open replaces it
directly (a crossfade between two detail instances with distinct ids) instead
of today's dismiss-then-queue; `queuedDetail` remains only for a flight that
arrives while the Add sheet is up.

Out of scope: friend trip previews (`FlightDetailView(isOwnFlight: false)` from
`MyFlightsView` and `FriendsView`). They are read-only, not the user's
flights, and keep their own system sheets.

## Map and camera

Unchanged. `onChange(of: detailFlight?.id)` still focuses the camera; the
gate and airport views still lower the sheet to medium, now through the tab
sheet's detent.

## Testing

- Unit: `DetailPresentation` — open remembers and raises; close restores;
  replace keeps the first remembered detent; opening from `.large` restores
  `.large`. The morph-id helper produces distinct ids per flight.
- Simulator: the frame-burst capture (see working notes) on a row tap and on
  the X, at medium and at large starting detents; a widget-style open via
  `-openDetail`; opening the other leg of the seeded BEG→ZRH→ORD connection
  from inside the detail; gate view lowering the sheet to medium and the X
  restoring the pre-tap detent afterwards.
- Existing 507 tests stay green.

## Risks and the spike

Before the full build, a half-day spike on one row and one element pair:

1. `matchedGeometryEffect` from a `List` row to a sibling view in the sheet.
   List cells are hosted separately and the travel can stutter or skip. If it
   does, `MyFlightsView`'s List becomes a `ScrollView` + `LazyVStack`; that
   costs `.swipeActions` (delete) and `.refreshable`, both rebuilt with a
   custom swipe row and a top-of-scroll refresh.
2. BottomSheet drag vs the detail's ScrollView (see Closing).

Also: `ArcRootView.body`'s modifier chain sits at the type-checker limit. The
new hooks go into `tabSurface` and `fileprivate` ViewModifiers, following
`NotificationPrimerAlert` and `RevealCameraHandback`.

## What the build taught (2026-09-11)

- **Animations must be declared inside the sheet.** The tab content is hosted
  by UIKit's tab controller, and a `withAnimation` opened in the root never
  reaches that tree: the elements snapped and the sheet jumped. The spring
  now lives on the sheet's content as `.animation(ArcTheme.morph, value:
  detailFlight?.id)` and on `SheetChrome`'s height as `.animation(_, value:
  liveHeight)`, with drag snapping kept instant through a transaction that
  disables animation.
- **Sections are inserted after the elements land, not faded from zero.**
  Laying out the whole detail tree on the first frame cost ~200 ms on the
  main thread (Debug build) and froze the start of the morph. The two groups
  below the endpoints card are now inserted 0.32 s after the detail appears,
  with an opacity-and-rise transition.
- **The two fades are shaped, not re-timed.** Attaching a faster animation
  to a transition overrides the spring for that subtree (on close the
  elements stopped travelling). Instead a custom `Animatable` modifier rides
  the spring and shapes opacity: the list leaves as p³ and returns as p²,
  the detail arrives as 1−(1−p)³ and leaves as p². Open reads as one object
  moving; on close the travelling copies hand off to the row as they land.
- **Status travels by position only.** Animating the banner headline's frame
  re-wrapped it mid-flight ("Landi / ng in…"); only the logo animates its
  frame.
- **List scroll position resets on close.** The list is removed while the
  detail is up (that is what makes its row the morph source), so it comes
  back at the top. With a handful of trips this has not been noticeable.
- Pull-down close works: the BottomSheet's drag lives on its grabber only.

## Revised after review (2026-09-11, evening)

Carl's verdict on the matched-geometry version: the elements read as coming
in from the right with a bounce, and the close layered and looked laggy.
Both were inherent to `matchedGeometryEffect` here — the row's elements sit
right of the countdown block, so the travel is diagonal and the spring
overshoots sideways, and every pair keeps two copies on screen.

The geometry match is gone. The moment is now a rise: the list fades out
(0.16 s), then the header, banner, endpoints card and the two section groups
rise 44 pt into place from below, each 45 ms after the last, on the morph
spring. Close is the same animation played backwards — the same spring drops
each element with the turns reversed, so the header, first in, is last out —
and the list returns only after the last element has gone. The detail view
is inserted hidden a beat before the rise and removed a beat after the drop
(`Morph.listOut`, `elementsOut`, `closeTotal`), and the sheet's detent moves
with the elements. `RiseIn` in Arc/Components/Morph.swift is the whole
mechanism; `FlightDetailView.presented` drives it.

On the phone (2026-09-12): the sheet must NOT rise to large when a row is
tapped — it stays at whatever height it has — and pulling the detail down
past its top must not close it (it felt like an accidental close while
scrolling back up). Only the X closes. `DetailPresentation` and the
`onScrollGeometryChange` close are removed accordingly.
