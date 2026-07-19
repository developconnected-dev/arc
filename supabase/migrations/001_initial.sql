-- Arc Social Schema
-- Run this in Supabase SQL Editor or via `supabase db push`

-- ── Users (extends Supabase auth.users) ──
create table public.profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    display_name text not null default '',
    handle text unique,  -- e.g. @carl
    avatar_url text,
    home_airport text,   -- IATA code
    created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "Public profiles are viewable by everyone"
    on public.profiles for select using (true);

create policy "Users can update own profile"
    on public.profiles for update using (auth.uid() = id);

create policy "Users can insert own profile"
    on public.profiles for insert with check (auth.uid() = id);

-- Auto-create profile on signup
create or replace function public.handle_new_user()
returns trigger as $$
begin
    insert into public.profiles (id, display_name)
    values (new.id, coalesce(new.raw_user_meta_data->>'full_name', ''));
    return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();

-- ── Friendships ──
create table public.friendships (
    id uuid primary key default gen_random_uuid(),
    requester_id uuid not null references public.profiles(id) on delete cascade,
    addressee_id uuid not null references public.profiles(id) on delete cascade,
    status text not null default 'pending' check (status in ('pending', 'accepted', 'blocked')),
    created_at timestamptz not null default now(),
    unique (requester_id, addressee_id)
);

alter table public.friendships enable row level security;

create policy "Users can see own friendships"
    on public.friendships for select
    using (auth.uid() = requester_id or auth.uid() = addressee_id);

create policy "Users can send friend requests"
    on public.friendships for insert
    with check (auth.uid() = requester_id);

create policy "Users can update friendships they're part of"
    on public.friendships for update
    using (auth.uid() = requester_id or auth.uid() = addressee_id);

create policy "Users can delete own friendships"
    on public.friendships for delete
    using (auth.uid() = requester_id or auth.uid() = addressee_id);

-- ── Shared Flights (synced from device) ──
create table public.shared_flights (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references public.profiles(id) on delete cascade,
    flight_number text not null,
    airline text not null default '',
    departure_iata text not null,
    arrival_iata text not null,
    departure_city text not null default '',
    arrival_city text not null default '',
    scheduled_departure timestamptz not null,
    scheduled_arrival timestamptz not null,
    status text not null default 'scheduled',
    delay_minutes int not null default 0,
    departure_gate text,
    arrival_gate text,
    baggage_claim text,
    aircraft_type text,
    live_lat double precision,
    live_lon double precision,
    live_altitude double precision,
    live_speed double precision,
    progress double precision not null default 0,
    updated_at timestamptz not null default now(),
    created_at timestamptz not null default now()
);

alter table public.shared_flights enable row level security;

create policy "Users can manage own flights"
    on public.shared_flights for all
    using (auth.uid() = user_id);

create policy "Friends can view shared flights"
    on public.shared_flights for select
    using (
        exists (
            select 1 from public.friendships f
            where f.status = 'accepted'
            and (
                (f.requester_id = auth.uid() and f.addressee_id = shared_flights.user_id) or
                (f.addressee_id = auth.uid() and f.requester_id = shared_flights.user_id)
            )
        )
    );

-- ── Shared Journeys (public live links) ──
create table public.shared_journeys (
    id uuid primary key default gen_random_uuid(),
    flight_id uuid not null references public.shared_flights(id) on delete cascade,
    user_id uuid not null references public.profiles(id) on delete cascade,
    share_code text unique not null,  -- short code for URL, e.g. "abc123"
    is_active boolean not null default true,
    expires_at timestamptz,
    created_at timestamptz not null default now()
);

alter table public.shared_journeys enable row level security;

create policy "Users can manage own journeys"
    on public.shared_journeys for all
    using (auth.uid() = user_id);

-- Public read for shared journeys (anyone with the link)
create policy "Anyone can view active shared journeys"
    on public.shared_journeys for select
    using (is_active = true);

-- ── Watchers (get notified about a friend's flight) ──
create table public.watchers (
    id uuid primary key default gen_random_uuid(),
    watcher_id uuid not null references public.profiles(id) on delete cascade,
    flight_id uuid not null references public.shared_flights(id) on delete cascade,
    notify_departure boolean not null default true,
    notify_landing boolean not null default true,
    notify_delay boolean not null default true,
    created_at timestamptz not null default now(),
    unique (watcher_id, flight_id)
);

alter table public.watchers enable row level security;

create policy "Users can manage own watches"
    on public.watchers for all
    using (auth.uid() = watcher_id);

-- ── Indexes ──
create index idx_friendships_requester on public.friendships(requester_id);
create index idx_friendships_addressee on public.friendships(addressee_id);
create index idx_shared_flights_user on public.shared_flights(user_id);
create index idx_shared_journeys_code on public.shared_journeys(share_code);
create index idx_watchers_flight on public.watchers(flight_id);

-- ── Realtime ──
-- Enable realtime on shared_flights so watchers get live updates
alter publication supabase_realtime add table public.shared_flights;
alter publication supabase_realtime add table public.shared_journeys;
