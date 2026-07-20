# Setting up live flight data (AeroDataBox)

Arc's UI, offline typeahead, and manual flight entry all work with **zero
API keys**. This is only needed to light up **live search + live tracking**
(the `/flight` and `/inbound` endpoints in `backend/src/index.ts`).

There are two separate pieces, and they live in two different places:

1. **The AeroDataBox key** — a secret that lives server-side, on your
   Cloudflare Worker. It never touches the iOS app or gets typed into Arc.
2. **The Worker's URL** — goes into Arc → **Passport → avatar icon →
   Settings → Backend URL**. That's the *only* thing the app itself needs.

## 1. Get an AeroDataBox key (RapidAPI)

1. Go to [rapidapi.com](https://rapidapi.com) and create a free account.
2. Search for **AeroDataBox** in the RapidAPI marketplace (or go directly to
   its listing) and subscribe to the **Basic** plan — it's free, 600 API
   units/month, no card required for that tier.
3. On the API's "Endpoints" page, RapidAPI shows your personal
   `X-RapidAPI-Key` — copy it. (You do not need to hand-craft any requests;
   the Worker code already knows how to call every endpoint it needs.)
4. Optional, once you're tracking flights for real: upgrade to **Pro**
   (~$5.35/mo) for a much higher cap — the free tier is fine for testing but
   the app's periodic tracking loop can burn through 600 units quickly.

## 2. Deploy the Cloudflare Worker

Wrangler (Cloudflare's CLI) is already installed on this machine
(`wrangler 4.112.0`) and the Worker code is ready to go at `backend/`.

```bash
cd ~/Downloads/Arc/backend

# Log into YOUR Cloudflare account (opens a browser window)
wrangler login

# Store the RapidAPI key as a Worker secret — paste it when prompted.
# This is the ONLY place the key lives; it's encrypted at rest by Cloudflare
# and never shipped in the app binary or committed to git.
wrangler secret put RAPIDAPI_KEY

# Deploy
wrangler deploy
```

`wrangler deploy` prints the Worker's URL at the end, something like:

```
https://arc-backend.<your-cloudflare-subdomain>.workers.dev
```

**Note on the existing default URL:** Arc currently ships with
`https://arc-backend.owncalai.workers.dev` as a placeholder default in
Settings — that was a prior scaffold deployment, not necessarily one you
control, and it almost certainly doesn't have your `RAPIDAPI_KEY` secret set.
Deploy your own as above and use *that* URL instead.

## 3. Point Arc at your Worker

In the app: **Passport tab → avatar icon (top right) → Settings → API
section → Backend URL** — paste the URL from step 2, exactly as printed
(including `https://`, no trailing slash).

That's it. Search (Add Flight) and the periodic tracking loop
(`FlightTracker`) will now hit your Worker, which proxies to AeroDataBox
using the secret key. Nothing else in the app needs configuring.

## Verifying it worked

```bash
curl "https://<your-worker-url>/health"
# {"ok":true,"provider":"aerodatabox"}   ← key is configured
# {"ok":true,"provider":"unconfigured"}  ← secret didn't get set; re-run step 2
```

```bash
curl "https://<your-worker-url>/flight?number=LX1413&date=2026-07-25"
# a JSON array of matching flight legs, or [] if none scheduled that day
```

## What still works with no key at all

- Every screen's UI and light/dark theming
- Add Flight's offline airline/airport typeahead (bundled ~990 airlines /
  ~7,900 airports)
- **Manual flight entry** (the "Enter flight manually" path in Add Flight) —
  the only way to log *past* flights anyway, since AeroDataBox's live-status
  endpoint doesn't carry historical schedules
- Passport stats, widgets, and Live Activities, all computed from whatever
  flights are in the local SwiftData store

## Optional: Supabase (Friends / Shared Journeys)

Unrelated to flight data — this powers the deferred social features
(Friends, Shared Journeys, Watchers). Skip it entirely for now; when you're
ready: create a free project at [supabase.com](https://supabase.com), run
`supabase/migrations/001_initial.sql` against it, then put the project URL
and anon key into Settings → "Social (Supabase)" and as Worker secrets
(`wrangler secret put SUPABASE_URL`, `wrangler secret put SUPABASE_ANON_KEY`)
for the `/journey/:code` shared-journey page.
