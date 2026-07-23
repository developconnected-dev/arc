-- Gate data, two purposes — both designed to stay far inside the free tier:
--
-- 1. gate_observations: the gate-prediction flywheel. ONE row per flight per
--    day (upserted on conflict, never appended per poll), ~200 bytes each.
--    Even ten tracked flights a day for five years ≈ 18k rows ≈ < 5 MB
--    against the 500 MB free tier.
--
-- 2. airport_gates: cached OpenStreetMap gate coordinates per airport,
--    fetched once per airport per ~90 days. A large hub has ~100-200 gates
--    (~60 bytes each) and only airports actually visited are ever cached.
--
-- Both are written/read by the Worker with the service-role key only: RLS
-- enabled with zero policies blocks all anon PostgREST access.

create table public.gate_observations (
    id uuid primary key default gen_random_uuid(),
    flight_number text not null,
    departure_iata text not null,
    arrival_iata text not null,
    flight_date date not null,
    dep_gate text,
    dep_terminal text,
    arr_gate text,
    arr_terminal text,
    updated_at timestamptz not null default now(),

    unique (flight_number, departure_iata, flight_date)
);

alter table public.gate_observations enable row level security;
create index idx_gate_obs_flight on public.gate_observations(flight_number, departure_iata);

create table public.airport_gates (
    iata text not null,
    ref text not null,
    lat double precision not null,
    lon double precision not null,
    fetched_at timestamptz not null default now(),

    primary key (iata, ref)
);

alter table public.airport_gates enable row level security;
