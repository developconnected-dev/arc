-- What RapidAPI itself says is left, recorded from the x-ratelimit-requests-
-- remaining header on every AeroDataBox response.
--
-- Our own counter tracks attempts we made; it has no idea what plan the key is
-- on. When the plan was upgraded, the counter stayed at its old ceiling and
-- kept blocking searches that would have succeeded — the provider's number is
-- the one that can actually settle "is there quota or not".
alter table public.api_budget
    add column if not exists adb_remaining integer;
