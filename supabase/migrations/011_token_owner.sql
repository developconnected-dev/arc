-- Live Activity tokens need an owner. Without one, the cron's push-to-start
-- cross-joined EVERY user's upcoming flights with EVERY registered start
-- token: user A's flight (number, cities, airline, seat) started a Live
-- Activity on user B's lock screen. The Worker now scopes starts to the
-- token owner's own flights and sends nothing for ownerless tokens.
alter table public.live_activity_tokens
    add column if not exists user_id uuid references public.profiles(id) on delete cascade;

create index if not exists live_activity_tokens_user_idx
    on public.live_activity_tokens (user_id);
