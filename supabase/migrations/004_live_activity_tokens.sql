-- APNs push tokens for remote-updated Live Activities.
--
-- Written and read ONLY by the Cloudflare Worker using the service-role key
-- (the app registers tokens through the Worker's /la/register endpoint, never
-- directly). RLS is enabled with NO policies on purpose: that blocks all
-- anon/authenticated PostgREST access completely, while the service role
-- bypasses RLS. A leaked token alone is useless without our APNs signing key,
-- but there's no reason to make them readable at all.

create table public.live_activity_tokens (
    id uuid primary key default gen_random_uuid(),
    token text not null unique,
    token_type text not null check (token_type in ('update', 'start')),
    apns_env text not null default 'sandbox' check (apns_env in ('sandbox', 'production')),

    -- Flight snapshot (update tokens only; start tokens have these null and
    -- the cron derives upcoming flights from user_flights instead).
    flight_number text,
    departure_iata text,
    arrival_iata text,
    departure_city text,
    arrival_city text,
    airline text,
    aircraft_type text,
    seat text,
    scheduled_departure timestamptz,
    scheduled_arrival timestamptz,

    -- Latest fetched provider data + bookkeeping, so the every-minute cron can
    -- push recomputed progress without hitting AeroDataBox every minute.
    last_state jsonb not null default '{}',

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table public.live_activity_tokens enable row level security;

create index idx_la_tokens_type on public.live_activity_tokens(token_type);
