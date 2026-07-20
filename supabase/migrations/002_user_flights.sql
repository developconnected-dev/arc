-- Private per-user flight backup/sync. Separate from `shared_flights` (which
-- exists for the Friends/social feature and only carries a trimmed-down
-- subset of fields meant for sharing) — this is a fuller mirror of the local
-- SwiftData store, readable and writable only by its own owner. `id` matches
-- the client-generated Flight.id so add/update/delete all key consistently.

create table public.user_flights (
    id uuid primary key,
    user_id uuid not null references public.profiles(id) on delete cascade,

    flight_number text not null default '',
    airline text not null default '',
    airline_icao text not null default '',

    departure_iata text not null default '',
    arrival_iata text not null default '',
    departure_city text not null default '',
    arrival_city text not null default '',
    departure_lat double precision not null default 0,
    departure_lon double precision not null default 0,
    arrival_lat double precision not null default 0,
    arrival_lon double precision not null default 0,

    scheduled_departure timestamptz not null,
    scheduled_arrival timestamptz not null,
    actual_departure timestamptz,
    actual_arrival timestamptz,
    estimated_arrival timestamptz,

    status text not null default 'scheduled',
    delay_minutes int not null default 0,

    departure_gate text,
    departure_terminal text,
    arrival_gate text,
    arrival_terminal text,
    baggage_claim text,

    aircraft_type text,
    aircraft_registration text,
    aircraft_icao24 text,

    booking_code text,
    seat text,
    notes text not null default '',

    added_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table public.user_flights enable row level security;

create policy "Users can manage their own flights"
    on public.user_flights for all
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

create index idx_user_flights_user on public.user_flights(user_id);
create index idx_user_flights_departure on public.user_flights(scheduled_departure);
