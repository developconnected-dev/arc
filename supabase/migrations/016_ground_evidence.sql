-- Ground evidence: what the aircraft is actually doing, from ADS-B.
--
-- Airlines publish gate times; nobody publishes the taxi. A friend watching
-- a shared flight wants "taxiing for 24 min", and a phone that went dark at
-- the door wants the server to have seen wheels-up. The cron watches the
-- aircraft (airplanes.live, by registration / Mode-S) and records here.
alter table public.shared_flights
  add column if not exists aircraft_registration text,
  add column if not exists aircraft_icao24 text,
  -- at_gate | taxiing | airborne, from the last ADS-B sample
  add column if not exists ground_state text,
  add column if not exists ground_observed_at timestamptz,
  -- first sample that showed the aircraft rolling
  add column if not exists taxi_started_at timestamptz,
  -- the provider's own estimated wheels-up (AeroDataBox runwayTime while unconfirmed)
  add column if not exists est_takeoff timestamptz,
  -- who wrote live_lat/live_lon last: 'device' (the traveller's phone) or 'adsb'
  add column if not exists live_source text;

-- Observed taxi-out durations (taxi start → wheels-up) per departure airport,
-- so the grace Arc gives a departure before assuming it is airborne is the
-- airport's own p85 rather than a constant. Same shape as gate_observations:
-- one row per flight per day, Worker service-key only.
create table if not exists public.taxi_observations (
    id uuid primary key default gen_random_uuid(),
    departure_iata text not null,
    flight_number text not null,
    flight_date date not null,
    hour_utc int not null,
    taxi_minutes int not null,
    observed_at timestamptz not null default now(),
    unique (flight_number, departure_iata, flight_date)
);
alter table public.taxi_observations enable row level security;
create index if not exists idx_taxi_obs_airport
  on public.taxi_observations(departure_iata, observed_at desc);
