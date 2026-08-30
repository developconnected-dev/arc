# Release checklist — the manual parts

The parts CI cannot do. Work top to bottom; each is safe to redo.

## Backend (once per release that touches `backend/` or `supabase/`)

- [ ] **Supabase migration 021** (`supabase/migrations/021_budget_reset.sql`)
      — adds `adb_reset_at` and the 4-arg `bump_api_budget` RPC. Apply in the
      Supabase SQL editor BEFORE deploying the Worker: the deployed Worker
      calls the 4-arg RPC and will log bump failures against the old 3-arg one.
- [ ] **Deploy the Worker**: `cd backend && npm test && npm run deploy`.
- [ ] **`ADSB_CONTACT` secret** (once, not per release):
      `cd backend && wrangler secret put ADSB_CONTACT` → an email address you
      monitor. It only goes into the outbound User-Agent toward the ADS-B
      aggregators; without it the server's own takeoff watch stays off
      (devices still witness — the flip is just slower).
- [ ] **Verify**: open `/health` — expect units-denominated budget numbers and
      `adb_resets_at` / `adb_resets_in_days` (null until the first bump after
      migration 021 records a reset header).

## App (per archive)

- [ ] **Regenerate the project first**: `xcodegen generate`. The committed
      .xcodeproj lags `project.yml` whenever files were added — this session
      added TakeoffSensor.swift, BoardingPass.swift, BoardingPassScanView.swift,
      BookingExtractor.swift and four Info.plist permission entries, none of
      which exist in a stale project.
- [ ] **Bump `CURRENT_PROJECT_VERSION`** in `project.yml` (App Store Connect
      rejects a build number it has already seen; last shipped: 33).
- [ ] Archive in Xcode (signing needs your Mac; CI already compiled and
      tested this exact code).

## On-phone validation (the paths CI structurally cannot reach)

- [ ] **Permission prompts on an UPGRADED install** — iOS never notifies users
      about new permissions; the prompts fire in-app at the moment of use:
      - Motion & Fitness + Location: appear together the first time a tracked
        flight enters its takeoff window while the app is open (T−15 min from
        off-block). Expect BOTH dialogs back to back at the gate. iOS later
        poses its own "Change to Always Allow?" question — Always is what
        lets the airport geofence relaunch a closed Arc, so the sensors work
        without opening the app on travel day; "Keep While Using" simply
        keeps the open-the-app behavior.
      - Camera: appears on first tap of the boarding-pass scan button.
      - Notifications: existing users keep their prior decision; nothing new.
- [ ] Scan a real boarding pass (paper PDF417 and a wallet Aztec/QR).
- [ ] Paste a booking on an Apple Intelligence device — the parse should
      answer in ~a second with no `/parse-booking` request in the Worker logs.
- [ ] Takeoff sensor on a real flight: card flips to confirmed In Air in
      airplane mode; blue location indicator only during the takeoff window.
- [ ] Battery after that flight (Settings → Battery → Arc): the acceptance
      test for the whole sensor pipeline. Expect roughly 5% attributable to
      Arc on a long-haul day — the coarse landing-watch heartbeat and the
      delay-aware GPS profile are designed for that number. Meaningfully
      more means CoreLocation isn't honoring Reduced accuracy in airplane
      mode and the heartbeat needs rethinking.

## Housekeeping

- [ ] Delete the stale `cursor/*` branches via the GitHub UI (the push proxy
      refuses remote deletions from CI sessions).
