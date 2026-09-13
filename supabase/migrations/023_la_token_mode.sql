-- Which kind of journey a Live Activity token belongs to.
--
-- The cron treated every token as an airline flight: a ferry's card was
-- refreshed by asking AeroDataBox about a flight called "BLUE STAR DELOS",
-- a budget-guarded call that could only ever miss, and its stale-date was
-- pointed at an airport taxi the ferry never takes. With the mode on the row
-- the cron leaves the provider alone for rail and sea and lets the clock —
-- the only source those legs have — decide.
alter table public.live_activity_tokens
    add column if not exists mode text not null default 'air';
