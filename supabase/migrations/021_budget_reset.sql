-- When RapidAPI's quota window rolls over, from the
-- x-ratelimit-requests-reset header (seconds until reset) that rides every
-- AeroDataBox response. The one question a "100% reached" email raises —
-- when am I back? — had no answer anywhere: the Worker recorded the
-- remaining header and threw this one away. /health now reports it.
alter table public.api_budget
    add column if not exists adb_reset_at timestamptz;

-- The bump RPC (migration 014) grows a reset parameter. Replaced rather than
-- overloaded: an overload set makes PostgREST's named-parameter dispatch
-- ambiguous, and the new default keeps an old Worker's three-argument call
-- working through the same function.
drop function if exists public.bump_api_budget(text, text, int);

create or replace function public.bump_api_budget(
    p_month text,
    p_field text,
    p_remaining int default null,
    p_reset_at timestamptz default null
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
        'update public.api_budget set %I = %I + 1, '
        || 'adb_remaining = coalesce($1, adb_remaining), '
        || 'adb_reset_at = coalesce($2, adb_reset_at) '
        || 'where month = $3',
        p_field, p_field)
        using p_remaining, p_reset_at, p_month;
end;
$$;

revoke all on function public.bump_api_budget(text, text, int, timestamptz)
    from public, anon, authenticated;
