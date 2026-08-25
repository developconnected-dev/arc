-- Measuring the one claim Arc can honestly make about speed.
--
-- Arc cannot beat an airline to a gate assignment or a filed delay: the airline
-- creates those, and Arc reads a downstream aggregator. What Arc can do is say
-- a flight will be late BEFORE the airline admits it, because the aircraft that
-- becomes your flight is already late and cannot turn around in time — physics
-- the airline knows too, and holds while operations tries to recover it.
--
-- That is a claim, and a claim wants a number. This table holds the two
-- timestamps that produce one: when Arc first said it, and when the airline's
-- own published delay caught up. The difference is the lead time, and until it
-- is measured nobody should put it on a landing page.
--
-- Written by the traveller's device (through the Worker's service key) at the
-- moment of prediction; resolved by the cron, which sees the airline's number
-- on its own schedule whether the app is running or not. Resolving on-device
-- would have measured how often the app was open, not how early Arc knew.
create table if not exists delay_predictions (
    id uuid primary key default gen_random_uuid(),
    user_id uuid,
    flight_number text not null,
    scheduled_departure timestamptz not null,
    -- What Arc said, and what the airline had published at that moment. The
    -- second is what makes the first meaningful: a prediction that merely
    -- restates a delay already filed is not a lead, it is an echo.
    predicted_minutes int not null,
    official_minutes_at_prediction int not null default 0,
    reason text,
    predicted_at timestamptz not null default now(),
    -- Null until the airline's own number reaches it. Stays null when the
    -- prediction was simply wrong, which is a result worth keeping: a lead
    -- time averaged over only the predictions that came true is not a lead
    -- time, it is a survivorship bias with a decimal point.
    confirmed_at timestamptz,
    official_minutes_at_confirmation int,
    -- One row per flight per traveller: the FIRST prediction is the one whose
    -- timestamp means anything, so later ones must not overwrite it.
    unique (flight_number, scheduled_departure, user_id)
);

-- The cron reads only the unresolved ones, every tick.
create index if not exists delay_predictions_open_idx
    on delay_predictions (predicted_at)
    where confirmed_at is null;

-- Enabled with no policies, deliberately, exactly like device_tokens: every
-- read and write goes through the Worker's service key, which bypasses RLS.
-- A policy here would widen access to measurement data for no reason.
alter table delay_predictions enable row level security;
