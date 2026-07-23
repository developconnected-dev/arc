-- Flight track points — actual positions collected during flight via OpenSky ADS-B.
-- Stored as JSONB array for efficient retrieval of the entire track at once.
-- Uploaded after landing, fetched on demand when viewing past flight details.

create table public.flight_tracks (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references public.profiles(id) on delete cascade,
    flight_number text not null,
    departure_iata text not null,
    arrival_iata text not null,
    flight_date date not null,
    track_points jsonb not null default '[]',  -- [{lat, lon, timestamp, altitude}, ...]
    created_at timestamptz not null default now(),

    -- One track per flight per user
    unique (user_id, flight_number, flight_date)
);

alter table public.flight_tracks enable row level security;

create policy "Users can manage own tracks"
    on public.flight_tracks for all
    using (auth.uid() = user_id);

create policy "Friends can view tracks"
    on public.flight_tracks for select
    using (
        exists (
            select 1 from public.friendships f
            where f.status = 'accepted'
            and (
                (f.requester_id = auth.uid() and f.addressee_id = flight_tracks.user_id) or
                (f.addressee_id = auth.uid() and f.requester_id = flight_tracks.user_id)
            )
        )
    );

create index idx_flight_tracks_user on public.flight_tracks(user_id);
create index idx_flight_tracks_date on public.flight_tracks(flight_date);
