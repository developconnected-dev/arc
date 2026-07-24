-- API economy: shared response cache + monthly provider budget.
--
-- One AeroDataBox/AirLabs answer serves every consumer (each family device,
-- the Live Activity cron, share pages) for a phase-aware TTL, and a monthly
-- budget with an interactive reserve makes it impossible for the cron to
-- burn the whole plan again (July 2026: flat 5-min cron refresh + 60s
-- in-flight device polls killed the month's quota by the 24th).
--
-- Both tables are service-role only (RLS on, zero policies): the Worker is
-- the sole reader/writer.

create table public.flight_cache (
    key text primary key,               -- "flight|LX14|2026-07-24" / "reg|HBJHQ|2026-07-24"
    payload jsonb not null,             -- mapped legs (post-normalization, provider-agnostic)
    provider text not null,             -- 'adb' | 'airlabs'
    fetched_at timestamptz not null default now()
);
alter table public.flight_cache enable row level security;

create table public.api_budget (
    month text primary key,             -- '2026-08'
    adb_cron int not null default 0,
    adb_interactive int not null default 0,
    airlabs_calls int not null default 0
);
alter table public.api_budget enable row level security;
