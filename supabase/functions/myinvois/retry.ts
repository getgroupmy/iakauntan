/**
 * How many times a document that LHDN will not accept is sent again.
 *
 * `einvoice_documents.retry_count` has existed since `0007`, beside
 * `last_attempt_at` and the index `(org_id, status, last_attempt_at)`
 * that is the retry picker. `submit.ts` and `consolidations.ts` wrote
 * the timestamp at every failure site and never touched the count, so
 * nothing counted attempts and nothing could give up.
 *
 * What that means in practice: the bulk picker selects
 * `status in ('queued', 'draft', 'failed', 'invalid')`, and `invalid`
 * is the status of a document MyInvois has REJECTED. A rejection is
 * almost never transient -- a buyer TIN that does not exist, a
 * classification code LHDN does not have, a total that does not
 * reconcile -- so the same document is rendered, signed and submitted
 * on every sweep, for ever, against an API that is rate-limited and
 * counts submissions per taxpayer.
 *
 * ## The ceiling stops the SWEEP, never a person
 *
 * `submit` takes `einvoice_ids`, `sales_document_id` or
 * `purchase_document_id` when somebody presses Submit on a document,
 * and nothing when the sweep sends everything queued. The ceiling
 * applies to the second only.
 *
 * That asymmetry is the whole design. Exhausting the attempts must not
 * make a document unsendable, because the reason it failed five times
 * is usually something a person is about to fix -- and a document
 * nobody can submit is an e-Invoice LHDN never receives, which is the
 * worse failure of the two by a distance. So a person may always try
 * again, and the sweep stops.
 *
 * ## Five
 *
 * Enough that a genuine transport failure -- MyInvois down for an
 * afternoon, a token that expired mid-batch -- is ridden out without
 * anybody noticing, and few enough that a poison document is not
 * re-signed a thousand times before somebody looks at the list.
 *
 * There is no backoff here and it is not needed: `last_attempt_at` is
 * what paces the sweep, and the sweep's own interval is the backoff.
 */

/** Attempts the bulk sweep will make before it leaves a document alone. */
export const MAX_ATTEMPTS = 5;

/**
 * `retry_count` after one more attempt.
 *
 * Clamped, because the column is a `smallint` and a person forcing a
 * submission is never refused -- so the count on a document somebody
 * keeps retrying by hand has no natural ceiling. Stopping the number
 * at the limit also makes "exhausted" one state rather than a range.
 */
export function nextAttempt(count: number | null | undefined): number {
  const now = typeof count === "number" && count > 0 ? count : 0;
  return Math.min(now + 1, MAX_ATTEMPTS);
}

/** Whether the bulk sweep should leave this document alone. */
export function isExhausted(count: number | null | undefined): boolean {
  return typeof count === "number" && count >= MAX_ATTEMPTS;
}

/**
 * What to say beside a document the sweep has stopped sending.
 *
 * Said rather than implied. A document that quietly stops being
 * retried looks exactly like a document that is fine, and the whole
 * point of stopping is that somebody has to go and look at it.
 */
export function exhaustedNote(count: number | null | undefined): string | null {
  if (!isExhausted(count)) return null;
  return `Not sent again automatically after ${MAX_ATTEMPTS} attempts. ` +
    `Fix what MyInvois objected to and submit it from the document.`;
}
