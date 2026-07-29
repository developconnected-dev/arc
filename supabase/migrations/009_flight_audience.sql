-- Per-flight audience: not every flight should go to every friend.
--
-- NULL means "everyone I'm friends with" — exactly the behaviour before this
-- column existed, so every existing row and any older build keeps working.
-- A non-null array is an explicit allow-list of profile ids.
--
-- This is enforced in the policy rather than filtered in the app on purpose:
-- client-side filtering would still let a friend read a flight they were left
-- out of by querying PostgREST directly, which defeats the point.

alter table public.shared_flights
    add column if not exists audience uuid[];

drop policy if exists "Friends can view shared flights" on public.shared_flights;

create policy "Friends can view shared flights"
    on public.shared_flights for select
    using (
        exists (
            select 1 from public.friendships f
            where f.status = 'accepted'
            and (
                (f.requester_id = auth.uid() and f.addressee_id = shared_flights.user_id) or
                (f.addressee_id = auth.uid() and f.requester_id = shared_flights.user_id)
            )
        )
        and (
            shared_flights.audience is null
            or auth.uid() = any (shared_flights.audience)
        )
    );
