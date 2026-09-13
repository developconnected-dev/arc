-- Friend and invite news leaves the device.
--
-- "Anna is in the air", "Carl added a trip for you together": until now every
-- one of these was a LOCAL notification, diffed on the reader's phone against
-- what it last saw — so it fired the next time the app happened to run, hours
-- late and in a burst with everything else it had missed. The cron sees the
-- same rows every minute; these columns are what it needs to say them once.

-- What friends were last told about this flight (witnessed phase + delay),
-- so a takeoff is announced on the tick it is seen and never again. On the
-- row because it is worthless without it, and cascades away with it.
alter table public.shared_flights
    add column if not exists alert_state jsonb not null default '{}'::jsonb;

-- Set once the recipient has been pushed, so a second tick cannot repeat it.
alter table public.trip_invites
    add column if not exists announced_at timestamptz;

-- The per-friend "Off" level, mirrored from the device: the server must
-- know whose flights this person does not want to hear about. Written by
-- the owner through the existing "Users can update own profile" policy.
alter table public.profiles
    add column if not exists muted_friends uuid[] not null default '{}';
