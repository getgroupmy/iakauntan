/**
 * The decisions `platform-users` makes before it touches the service
 * role key, in a file with no imports.
 *
 * Separated from `index.ts` for the reason `ask/wire.ts` is:
 * `index.ts` imports `jsr:@supabase/supabase-js`, and `jsr.io` is
 * unreachable from some of the machines this gets worked on, so a test
 * that had to import it would be a test only CI could run. Everything
 * here is a pure function over what arrived in the body.
 *
 * These are the checks that decide whether an account is created, a
 * password replaced, or somebody locked out. None of them is a
 * formality.
 */

/** Short enough to type, long enough not to be guessed in an afternoon. */
export const MIN_PASSWORD = 10;

/**
 * A field out of a JSON body, trimmed, or the empty string.
 *
 * Anything that is not a string is the empty string rather than
 * `String(value)`: a client sending `{"email": {}}` must not have it
 * become the address `[object Object]`.
 */
export function text(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

/**
 * The address an account is created under: trimmed and lower-cased.
 *
 * GoTrue treats addresses case-insensitively, so leaving the case alone
 * would let `Aisyah@example.com` look like a second person in the
 * console's list while being the same account underneath.
 */
export function normalizeEmail(value: unknown): string {
  return text(value).toLowerCase();
}

/**
 * Why this password will not do, or null.
 *
 * The long sentence is for the create case on purpose: somebody typing
 * another person's password should be told what it is standing in front
 * of. The short one is for a reset, where the account already exists
 * and the administrator has been through this once.
 */
export function passwordProblem(
  password: string,
  { creating = false }: { creating?: boolean } = {},
): string | null {
  if (password.length >= MIN_PASSWORD) return null;
  if (!creating) {
    return `A password needs at least ${MIN_PASSWORD} characters.`;
  }
  return `A password needs at least ${MIN_PASSWORD} characters. ` +
    "This one is being typed by somebody other than its owner, so " +
    "it is the only thing standing in front of their books.";
}

/**
 * What GoTrue is told to do about signing in.
 *
 * It takes a DURATION and has no unbounded value, so a hundred years is
 * this API's way of saying "until somebody says otherwise". `"none"` is
 * how a ban is lifted — NOT `"0h"`, which some versions accept as a ban
 * of no length and others reject.
 */
export function banDuration(suspended: boolean): string {
  return suspended ? "876000h" : "none";
}

/**
 * Why this suspension will not do, or null.
 *
 * Suspending oneself locks the administrator out of the console that is
 * the only place the suspension can be undone. Letting oneself back in
 * is allowed and needs no guard: it cannot be reached, because somebody
 * suspended cannot sign in to ask.
 */
export function suspendProblem(
  userId: string,
  callerId: string,
  suspended: boolean,
): string | null {
  if (!userId) return "Which person?";
  if (suspended && userId === callerId) return "You cannot suspend yourself.";
  return null;
}

/** The three actions, and nothing else. */
export type Action = "create" | "password" | "suspend";

/**
 * Which action was asked for, or null.
 *
 * A closed list rather than a lookup on the body's own string: this is
 * the function that holds the service role key, and "call the method
 * named in the request" is how that key gets used for something nobody
 * wrote.
 */
export function action(value: unknown): Action | null {
  switch (text(value)) {
    case "create":
      return "create";
    case "password":
      return "password";
    case "suspend":
      return "suspend";
    default:
      return null;
  }
}
