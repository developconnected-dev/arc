-- Trips that aren't flights: trains and ferries.
--
-- Arc stores all three in one local model, and both cloud tables mirror that
-- model, so both need to carry which kind of journey a row is. Without `mode`
-- a shared train arrives on a friend's phone indistinguishable from a flight —
-- it would be drawn with a plane, described as "In Air", and given a green
-- "On Time" badge that no ferry source ever published.
--
-- Every column is nullable or defaulted, so existing rows stay valid and an
-- older build of the app keeps writing and reading exactly as before.

-- ── private per-user mirror ────────────────────────────────────────────────

alter table public.user_flights
    -- 'air' | 'rail' | 'sea'. Defaulted, so every row already in the table is
    -- correctly described as a flight without a backfill.
    add column if not exists mode text not null default 'air',
    -- 'live' | 'scheduled' | 'manual' — how much the source actually knows.
    -- Existing rows are all provider-tracked flights, hence 'live'.
    add column if not exists data_tier text not null default 'live',

    -- The provider's own endpoint handles. Long and opaque (a MOTIS stop id, or
    -- a port name), and deliberately NOT the short display codes in
    -- departure_iata/arrival_iata, which stay three characters because the
    -- widget and Live Activity render them into fixed-width chips.
    add column if not exists departure_stop_id text,
    add column if not exists arrival_stop_id text,

    -- IANA zone per endpoint. The bundled airport table cannot answer for a
    -- station or a port — and worse, some derived codes collide with real
    -- airport codes and would return a confident wrong answer.
    add column if not exists departure_tz text,
    add column if not exists arrival_tz text,

    add column if not exists vessel_name text,
    add column if not exists vessel_mmsi text,
    add column if not exists operator_logo_url text,
    -- Operator prose about a sailing being moved or cancelled. Ferries publish
    -- no revised time per sailing anywhere, so this is the whole change signal.
    add column if not exists disruption_note text,
    add column if not exists booking_url text,
    -- MOTIS trip id: a fast path only. It embeds a per-import sequence the feed
    -- renumbers, so it is re-resolved from the departure board when it fails.
    add column if not exists rail_trip_id text;

-- ── the friends feed ───────────────────────────────────────────────────────
--
-- Only what a friend actually sees needs to cross. Stop ids, booking links and
-- trip ids stay private: they identify a booking rather than describe a journey,
-- and the feed is a trimmed subset by design.

alter table public.shared_flights
    add column if not exists mode text not null default 'air',
    add column if not exists data_tier text not null default 'live',
    add column if not exists departure_tz text,
    add column if not exists arrival_tz text,
    add column if not exists vessel_name text,
    add column if not exists operator_logo_url text,
    add column if not exists disruption_note text;

-- Guard the vocabulary at the edge. A typo'd mode would otherwise reach the app
-- and silently fall back to 'air', dressing a ferry up as a flight — the exact
-- failure this migration exists to prevent.
do $$ begin
    alter table public.user_flights
        add constraint user_flights_mode_check check (mode in ('air', 'rail', 'sea'));
exception when duplicate_object then null; end $$;

do $$ begin
    alter table public.shared_flights
        add constraint shared_flights_mode_check check (mode in ('air', 'rail', 'sea'));
exception when duplicate_object then null; end $$;

do $$ begin
    alter table public.user_flights
        add constraint user_flights_tier_check check (data_tier in ('live', 'scheduled', 'manual'));
exception when duplicate_object then null; end $$;

do $$ begin
    alter table public.shared_flights
        add constraint shared_flights_tier_check check (data_tier in ('live', 'scheduled', 'manual'));
exception when duplicate_object then null; end $$;

-- The friends feed is read by mode often enough to be worth an index once a
-- household has a few hundred journeys between them.
create index if not exists shared_flights_mode_idx on public.shared_flights (mode);
