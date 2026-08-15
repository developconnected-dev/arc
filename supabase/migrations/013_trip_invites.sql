-- "We're on this one together."
--
-- Sharing a trip lets a friend SEE it in their feed. This is the other verb:
-- the sender says a friend is travelling with them, and the friend gets an
-- invitation to add the very same journey to their own list — after which it
-- is their trip in every respect (Live Activity, widget, notifications,
-- passport). Nothing lands in anyone's list without them tapping Accept.
--
-- The journey travels as a JSON snapshot rather than a foreign key into the
-- sender's rows, on purpose: the recipient's copy must materialise even if the
-- sender deletes theirs a minute later, and it must NOT carry the sender's
-- booking code, seat or notes — those identify a booking, not a journey.

create table public.trip_invites (
    id uuid primary key default gen_random_uuid(),
    from_user uuid not null references public.profiles(id) on delete cascade,
    to_user uuid not null references public.profiles(id) on delete cascade,

    -- Natural key of the journey, duplicated out of the snapshot so re-adding
    -- the same trip re-invites idempotently instead of stacking cards.
    flight_number text not null,
    scheduled_departure timestamptz not null,

    -- The trimmed journey (same keys as user_flights, minus the private ones).
    flight jsonb not null,

    status text not null default 'pending'
        check (status in ('pending', 'accepted', 'declined')),
    created_at timestamptz not null default now(),
    responded_at timestamptz,

    check (from_user <> to_user),
    unique (from_user, to_user, flight_number, scheduled_departure)
);

alter table public.trip_invites enable row level security;

-- Both parties can read the invite: the recipient to act on it, the sender to
-- see whether it was taken up.
create policy "Parties can see their trip invites"
    on public.trip_invites for select
    using (auth.uid() = from_user or auth.uid() = to_user);

-- Only an accepted friend can be invited. Enforced here rather than in the
-- app, so nobody can push trips into a stranger's list through PostgREST.
create policy "Users can invite accepted friends"
    on public.trip_invites for insert
    with check (
        auth.uid() = from_user
        and exists (
            select 1 from public.friendships f
            where f.status = 'accepted'
            and (
                (f.requester_id = auth.uid() and f.addressee_id = trip_invites.to_user) or
                (f.addressee_id = auth.uid() and f.requester_id = trip_invites.to_user)
            )
        )
    );

-- The recipient answers. (They could also rewrite the snapshot, which is
-- harmless — it only ever becomes their own copy.)
create policy "Recipients can respond to trip invites"
    on public.trip_invites for update
    using (auth.uid() = to_user)
    with check (auth.uid() = to_user);

-- The sender withdraws (deleting the trip pulls its invitations); the
-- recipient can clear one they've already answered.
create policy "Parties can delete their trip invites"
    on public.trip_invites for delete
    using (auth.uid() = from_user or auth.uid() = to_user);

create index trip_invites_to_user_idx on public.trip_invites (to_user, status);
create index trip_invites_from_user_idx on public.trip_invites (from_user, status);
