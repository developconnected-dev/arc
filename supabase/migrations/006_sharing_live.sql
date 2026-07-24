-- Friends + live-share hardening.
--
-- 1. shared_flights gets a natural upsert key: the writer (FlightTracker)
--    fires on every poll, so "insert or update my current state of this
--    flight" must be one idempotent call, not tracked ids.
-- 2. Route coordinates + display fields the share page and friends map need
--    (a viewer without the app has no airport database to resolve IATA
--    codes against, so the row must carry its own geometry).
-- 3. shared_journeys default expiry: share links die after 48h unless the
--    sharer keeps them alive (matches the in-app copy).

alter table public.shared_flights
    add column if not exists departure_lat double precision not null default 0,
    add column if not exists departure_lon double precision not null default 0,
    add column if not exists arrival_lat double precision not null default 0,
    add column if not exists arrival_lon double precision not null default 0,
    add column if not exists estimated_arrival timestamptz,
    add column if not exists actual_departure timestamptz,
    add column if not exists actual_arrival timestamptz,
    add column if not exists departure_terminal text,
    add column if not exists arrival_terminal text;

create unique index if not exists idx_shared_flights_upsert
    on public.shared_flights (user_id, flight_number, scheduled_departure);

alter table public.shared_journeys
    alter column expires_at set default now() + interval '48 hours';
