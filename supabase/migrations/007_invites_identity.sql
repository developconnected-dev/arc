-- Frictionless identity: anonymous sessions + invite links.
--
-- Email sign-in is gone from the app. Identity = an anonymous Supabase user
-- created silently on first use; the person just types a name (and picks a
-- passport nationality, Flighty-style). Friending happens via capability
-- links: /f/<code> — knowing an unexpired code is the permission.

alter table public.profiles
    add column if not exists nationality text;   -- ISO region code ("CH")

create table public.friend_invites (
    code text primary key,
    inviter uuid not null references public.profiles(id) on delete cascade,
    created_at timestamptz not null default now(),
    expires_at timestamptz not null default now() + interval '48 hours'
);

alter table public.friend_invites enable row level security;

create policy "Users create own invites"
    on public.friend_invites for insert
    with check (auth.uid() = inviter);

-- Any signed-in user may look up an invite BY CODE (the code is the secret;
-- there is no listing endpoint in the app). The web landing page reads via
-- the service key instead.
create policy "Signed-in users can read invites"
    on public.friend_invites for select
    to authenticated
    using (true);
