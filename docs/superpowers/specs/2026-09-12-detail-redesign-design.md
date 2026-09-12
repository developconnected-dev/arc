# The flight detail, rethought — design and plan

Date: 2026-09-12. Agreed in conversation over eight mockups.

## Why

The detail said the same facts up to four times (times, airports, gate,
status, duration), spent cards on trivia (airline codes, an empty route
history, "Tap to Edit" boxes), and mixed six visual grammars. Carl's brief:
clear at first view, few colours, few text sizes, an icon where possible,
easy to read, and the row must still glide into it — but not look like the
row repeated.

## Rules

- Three text sizes: 28 for the codes and the two times, 15 for everything
  read, 13 for pills, labels and context.
- One colour: the status pill. Yellow only for a gate (`GatePill`), and a
  time turns red only when it moved. Nothing else is tinted.
- One icon per fact. One row style below the header: icon, text, trailing
  value or chevron, hairline between rows, grouped in one card style.
- Nothing said twice. The header owns times, airports, terminals, gates,
  duration, date, status; nothing below repeats them.
- "On Time" is a quote, and Arc only starts asking the operator the day
  before (`Flight.isSoon`, 24 h). Further out the pill says "Scheduled" in
  grey; a published delay is news at any distance and stays red. Flighty
  draws the same line. (Revised after build 36: the pill read "On Time" in
  grey five days out, which looked like a colour had gone missing.)
- The grabber-row controls (menu, X) are 34 pt circles with 15 pt glyphs,
  the status pill is 15 pt text, and the top line sits `Morph.detailTopInset`
  (12 pt) below them. (Build 36's 28 pt controls were wedged against the pill.)
  The controls are centred on the grabber's capsule, which keeps 25 pt from
  the sheet's edge, so the circles have 8 pt above and 8 pt to the pill: one
  balanced band, not controls pinned to the edge over a title floating below.

## The header (`DetailHeader`)

1. Top line: airline logo + flight number + date, left; status pill, right.
2. Route strip: `ZRH` (28) over `Zurich` (13), a hairline with the mode's
   glyph and the duration in the middle, `ORD` over `Chicago` on the right.
   Under each code its pills: terminal (grey) and gate (`GatePill`, tappable
   when the plane can be shown); the arrival adds a belt pill when one is
   published.
3. Two tiles: "Departs ZRH" / time / context, and "ORD Arrives" (right
   aligned) / time / context. Departure context is the countdown or "Departed
   Xm ago"; arrival context is "HH:MM your time" when the arrival is in a
   different zone from the device, else the arrival's relative text. A moved
   time is red with the scheduled time struck through beside it.
4. Two equal buttons: Terminal map, My plane (the existing actions).

## Below the header

- **Status rows** (only those that apply): inbound aircraft line; connection
  ("55m layover in ZRH · Risky", expands to the existing `ConnectionCard`);
  weather / prediction (`DelayRiskCard`, already self-hiding); baggage belt;
  a friend at the same airport (`AirportOverlapRow`).
- **Your trip** (own flights): booking code, seat, notes as rows with the
  value or "Add"; when all three are empty, one row "Add booking code, seat
  or notes" with a menu. Travelling with / shared with rows (existing
  components) and the friends on this flight.
- **Aircraft**: one row "A340-300 · HB-JMB" with the inbound status as its
  context, expanding to the rotation legs as rows.
- **Menu** beside the X: share, copy flight number, delete.
- **Removed**: the status banner, endpoints card, airport-names line,
  timezone notes, Detailed Timetable, Airline card, Route History, Good to
  Know, Notes card, freshness pill, bottom action bar.

## The glide

Unchanged mechanism (`heroOverlay`), two changes: the travelling copy is a
`HeroCard` that crossfades the row layout (opacity 1 − p) into the header
(opacity p), and its target frame is the header's measured frame
(`heroFrames.detail`), so the card grows from the row's height to the
header's as it lands.

## Plan

1. Tests for `DetailHeaderModel` (pure labels and tints) and `TripGroup`
   emptiness. Red.
2. `DetailHeaderModel` + `DetailHeader` + `DetailRow`/`DetailGroup`. Green.
3. Rebuild `FlightDetailView.body`; delete the replaced sections.
4. `HeroCard` in the overlay; target = measured header frame.
5. Simulator: open/close glide at 60 fps; scheduled, active, landed,
   cancelled, rail; phone install.
