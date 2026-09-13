-- "Anna is at ZRH too", said by the cron rather than by the next app open.
--
-- The last device-only social alert. Announced once per viewer, friend and
-- airport, exactly as the device deduped it; rows expire a few days on so a
-- later rendezvous at the same airport can announce again.
create table if not exists public.overlap_alerts (
    user_id uuid not null references public.profiles(id) on delete cascade,
    friend_id uuid not null references public.profiles(id) on delete cascade,
    airport text not null,
    my_flight_id uuid,
    announced_at timestamptz not null default now(),
    primary key (user_id, friend_id, airport)
);
alter table public.overlap_alerts enable row level security;
create index if not exists idx_overlap_alerts_announced on public.overlap_alerts(announced_at);
