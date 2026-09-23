/**
 * Asking a reader again when it said "not now".
 *
 * From a report: a scan came back
 *
 *     Nothing was read. The reader refused the document: HTTP 503
 *
 * A 503 is the vendor saying its model is at capacity. It is not about
 * the document, the account or the key, and the same request a second
 * later usually works. The scan was written off, refunded, and the
 * person was left looking at a failure that had nothing to do with
 * anything they could change.
 *
 * Nothing retried, because there was no retry anywhere in the scan
 * path: an overloaded vendor and an unreadable file were handled
 * identically.
 *
 * ## Which failures are worth asking again about
 *
 * The rule is the one the Anthropic and OpenAI SDKs both use, because
 * it is the rule the vendors document: 408, 409, 429 and anything 5xx.
 *
 * Everything else is a statement about THIS request and will be just as
 * true a second later -- a 400 is a malformed schema, a 401 is a dead
 * key, a 403 is a permission, a 413 is a file too big. Retrying those
 * spends another call and another second to be told the same thing, and
 * on a 429 it is worse than useless to retry the ones that are not
 * transient, because it is one more request against a limit that is
 * already the problem.
 */

/** A reader that answered, and said no. */
export class ReaderRefusal extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
    this.name = "ReaderRefusal";
  }
}

/**
 * Whether a status is the vendor saying "not now" rather than "no".
 *
 * `0` is not transient and is deliberately not treated as one: it is
 * what a status reads as when nothing answered at all, and a caller
 * that never got a response has a different problem from one that was
 * turned away.
 */
export function isTransient(status: number): boolean {
  if (status === 408 || status === 409 || status === 429) return true;
  return status >= 500 && status <= 599;
}

/** How long to wait before asking again. */
export const RETRY_PAUSE_MS = 1200;

/**
 * Runs [attempt], and runs it once more if the reader said "not now".
 *
 * ONE extra attempt, not a loop. An edge function answers a person
 * standing there holding a receipt, and a backoff that tries four times
 * over twenty seconds is a spinner they have already given up on. The
 * second attempt either works -- which is what a 503 usually does -- or
 * the scan fails the way it failed before this existed.
 *
 * [onRetry] is told what the first attempt said, so the caller can keep
 * it: a blip the person never saw is still a vendor having a bad
 * afternoon, and the row is the only place that would ever record it.
 */
export async function withOneRetry<T>(
  attempt: () => Promise<T>,
  options: {
    onRetry?: (failure: ReaderRefusal) => void;
    pauseMs?: number;
    sleep?: (ms: number) => Promise<void>;
  } = {},
): Promise<T> {
  try {
    return await attempt();
  } catch (e) {
    // Only a refusal carries a status. Anything else -- a file missing
    // from storage, a body that was not JSON, a type nothing reads --
    // is ours or the document's, and asking again cannot change it.
    if (!(e instanceof ReaderRefusal) || !isTransient(e.status)) throw e;

    options.onRetry?.(e);
    const pause = options.pauseMs ?? RETRY_PAUSE_MS;
    const sleep = options.sleep ??
      ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
    await sleep(pause);
    return await attempt();
  }
}
