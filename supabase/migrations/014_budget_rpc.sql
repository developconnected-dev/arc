-- Atomic budget increments.
--
-- The Worker used to read the month's counters and PATCH back `current + 1`.
-- Concurrent isolates (a search fans out up to 8 provider calls without
-- awaiting each other) read the same value and wrote the same value — eight
-- calls counted as one. An SQL-side increment can't lose updates.
--
-- SECURITY DEFINER with the service role as the only caller (RLS on the
-- table, no policies): same trust model as the direct writes it replaces.

create or replace function public.bump_api_budget(
    p_month text,
    p_field text,
    p_remaining int default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_field not in ('adb_cron', 'adb_interactive', 'airlabs_calls') then
        raise exception 'unknown budget field %', p_field;
    end if;
    insert into public.api_budget (month) values (p_month)
        on conflict (month) do nothing;
    execute format(
        'update public.api_budget set %I = %I + 1, adb_remaining = coalesce($1, adb_remaining) where month = $2',
        p_field, p_field)
        using p_remaining, p_month;
end;
$$;

revoke all on function public.bump_api_budget(text, text, int) from public, anon, authenticated;
