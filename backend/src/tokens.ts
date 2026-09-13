/// Which Live Activity token rows are dead weight, as PostgREST DELETEs.
///
/// 280 of 284 rows were push-to-start tokens nothing would ever push to:
/// ownerless ones from signed-out installs, and tokens from devices that
/// had not opened Arc in months. They cost a full table read every minute
/// and, the day a flight comes into range, a subrequest each. A device that
/// comes back re-registers its token on launch, so sweeping is safe.

const DAY = 86_400_000;

export interface StaleTokenQuery {
  reason: "ownerless-start" | "silent-start" | "landed-update";
  path: string;
}

export function staleTokenQueries(now: number): StaleTokenQuery[] {
  const iso = (ms: number) => new Date(ms).toISOString();
  return [
    // Registered before sign-in and never claimed: the cron refuses to push
    // to it, and a launch after sign-in registers a fresh, owned one.
    { reason: "ownerless-start",
      path: `/live_activity_tokens?token_type=eq.start&user_id=is.null&updated_at=lt.${iso(now - DAY)}` },
    // A device silent for 45 days. iOS rotates start tokens across that
    // span anyway; the row is a rotation the device never named.
    { reason: "silent-start",
      path: `/live_activity_tokens?token_type=eq.start&updated_at=lt.${iso(now - 45 * DAY)}` },
    // An activity's own token, two days past its flight: the end push
    // deletes these, unless the end push itself failed.
    { reason: "landed-update",
      path: `/live_activity_tokens?token_type=eq.update&scheduled_arrival=lt.${iso(now - 2 * DAY)}` },
  ];
}
