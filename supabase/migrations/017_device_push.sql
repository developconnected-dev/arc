-- Alerts that arrive when the app is closed.
--
-- Every notification Arc sent until now was a LOCAL one, scheduled on the
-- device by FlightTracker — which means it only ever fired while the app was
-- awake. A gate change at 05:00, a cancellation the evening before, an
-- inbound aircraft going 90 minutes late: all discovered by the cron, none
-- deliverable. The Live Activity push channel covers the last three hours
-- before departure (push-to-start opens a card, and its updates carry an
-- alert); this table covers everything earlier.
--
-- One row per device, not per user: a person with a phone and an iPad should
-- hear it on both, and APNs answers 410 for a token that has gone away.
create table if not exists public.device_tokens (
    token text primary key,
    user_id uuid not null references public.profiles(id) on delete cascade,
    -- Which APNs host this token belongs to. A sandbox token sent to the
    -- production host is rejected with BadDeviceToken, and vice versa.
    apns_env text not null default 'production',
    updated_at timestamptz not null default now()
);
alter table public.device_tokens enable row level security;
create index if not exists idx_device_tokens_user on public.device_tokens(user_id);

-- What the watcher has already looked at, and already said.
--
-- `watch_state` holds the last values an alert was sent for, so a delay that
-- stays at 40 minutes is announced once rather than every hour. Kept on the
-- flight row rather than in a separate table because it is worthless without
-- the flight, and cascades away with it.
alter table public.user_flights
  add column if not exists watch_checked_at timestamptz,
  add column if not exists watch_state jsonb not null default '{}'::jsonb;

create index if not exists idx_user_flights_watch
  on public.user_flights(scheduled_departure, watch_checked_at);
