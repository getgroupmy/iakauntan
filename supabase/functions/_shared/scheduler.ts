/**
 * Who is the scheduler?
 *
 * `fetch-rates` and `send-email` are called on a timer by GitHub Actions,
 * and both do something for *every* organization at once when they are:
 * fetching rates that price everybody's ledger, draining an outbox that
 * holds everybody's mail. That is not an action any one signed-in user
 * takes, so it needs a credential no signed-in user has.
 *
 * `verify_jwt` cannot be that credential on its own. It accepts any JWT
 * this project signed, and the publishable key ships inside the web
 * bundle — so it proves the caller reached the internet, and nothing
 * more.
 *
 * ---------------------------------------------------------------------
 * Two credentials, and why the second one exists
 *
 * The original answer was the service role key: the function compares
 * what was presented against its own copy. It works, and it means the
 * scheduler has to *hold* the service role key — full read and write
 * across every organization's ledger, payroll and LHDN credentials, RLS
 * bypassed. To run a timer.
 *
 * That is far more authority than the job needs. The functions already
 * have the service role key; the platform injects it. The caller only
 * has to prove it is the timer.
 *
 * So `SCHEDULER_SECRET` — any random string, set on the function and on
 * the caller. Someone who steals it can make the project fetch public
 * exchange rates and send mail that was already queued and already
 * authorised. Someone who steals the service role key owns the books.
 * The blast radius is the whole point.
 *
 * The service role key still works, because it legitimately identifies
 * the project's owner and because nothing should break the day this is
 * deployed. Prefer the secret.
 */

/**
 * Compares without an early exit, so how long the comparison takes says
 * nothing about how much of the secret was right. Length is compared
 * first and does leak — which is harmless for a random string, and the
 * alternative (hashing both sides) buys nothing here.
 */
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

/** The credentials a function will accept as proof it is the scheduler. */
export interface SchedulerKeys {
  /** `SCHEDULER_SECRET`, presented in the X-Scheduler-Secret header. */
  secret?: string | null;
  /** `SUPABASE_SERVICE_ROLE_KEY`, presented as the bearer token. */
  serviceKey?: string | null;
}

/**
 * True when this request came from the scheduler.
 *
 * Both comparisons refuse an empty configured value outright. Without
 * that, a function deployed with no `SCHEDULER_SECRET` set would treat
 * a caller who sends no header as matching "" — and every stranger on
 * the internet becomes the scheduler. That is the failure this function
 * exists to not have, so it is the first thing each branch checks.
 */
export function isSchedulerCall(req: Request, keys: SchedulerKeys): boolean {
  const secret = (keys.secret ?? "").trim();
  if (secret !== "") {
    const presented = (req.headers.get("x-scheduler-secret") ?? "").trim();
    if (presented !== "" && safeEqual(presented, secret)) return true;
  }

  const serviceKey = (keys.serviceKey ?? "").trim();
  if (serviceKey !== "") {
    const bearer = (req.headers.get("Authorization") ?? "")
      .replace(/^Bearer\s+/i, "").trim();
    if (bearer !== "" && safeEqual(bearer, serviceKey)) return true;
  }

  return false;
}
