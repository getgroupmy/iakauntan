/**
 * What to say when a pool of reader keys has nothing to give.
 *
 * Its own module, and not a function inside `index.ts`, for the reason
 * `places/parse.ts` is its own module: importing `index.ts` runs
 * `_shared/cors.ts`, which reads `ALLOWED_ORIGINS` at load, so a test
 * of one pure sentence would need `--allow-env` and would be importing
 * an HTTP handler to ask it a question about English.
 */

/**
 * Why a pool had nothing to give, in the words somebody reads.
 *
 * Three states that look identical from the scan's side — no key, no
 * scan — and are three different things to do next:
 *
 *   EMPTY      nobody has added a key. Somebody must.
 *   UNUSABLE   every key is switched off, or outside the hours it is
 *              allowed to run. Comes back at six, or when somebody
 *              switches one on.
 *   SPENT      every key is inside its window and over its cap. Comes
 *              back by itself when the minute, the day or the month
 *              rolls, and needs nobody.
 *
 * Getting this wrong is not cosmetic. It is the only sentence anybody
 * sees, and it is seen at the moment scanning has stopped — telling an
 * operator to add a key when the keys are merely busy is an hour spent
 * on the wrong thing at the worst time.
 */
export function poolProblem(keys: number, usable: number): string {
  if (keys <= 0) return "no keys have been added to it";
  if (usable <= 0) {
    return `all ${keys} of its keys are switched off or outside the hours ` +
      "they are allowed to run";
  }
  return `all ${keys} of its keys have spent their allowance; they come ` +
    "back when the minute, the day or the month rolls over";
}
