-- The Settings notification toggles, where the Worker can read them.
--
-- "Delays" and "Gate changes" only ever gated the LOCAL alerts; the
-- watcher's pushes and the Live Activity banner ignored them. The device
-- mirrors the toggles here on every flip. Absent keys mean on.
alter table public.profiles
    add column if not exists notify_prefs jsonb not null default '{}'::jsonb;

-- The Worker's silent nudge: a background push that wakes the app for the
-- refresh only the device can do, in the last hours before departure. Once
-- per half hour per device, remembered here.
alter table public.device_tokens
    add column if not exists nudged_at timestamptz;
