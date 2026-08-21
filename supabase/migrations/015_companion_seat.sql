-- Seat, for companions.
--
-- The friends feed deliberately excludes booking identifiers — but the seat
-- is the one piece of a booking that matters to someone ON the same journey:
-- "we're on this flight together, where are you sitting?" It surfaces in the
-- companions card and on the shared Live Activity, both RLS-gated to the
-- flight's audience like every other column here.

alter table public.shared_flights
    add column if not exists seat text;
