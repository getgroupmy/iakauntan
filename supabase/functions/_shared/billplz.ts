/**
 * Billplz, and the one thing that has to be right
 *
 * Billplz is a Malaysian payment gateway: you create a bill, send the
 * payer to its URL, and Billplz posts back when they have paid. The
 * posting back is the part with money in it, and it arrives from the
 * public internet at a function that cannot require a JWT — Billplz's
 * servers have no session with us. What proves the message is theirs is
 * an HMAC over its own fields, keyed by a secret only they and we hold.
 *
 * So the signature is the whole security boundary of the callback path,
 * and it is the reason this module exists separately from the function
 * that uses it: `_shared/*_test.ts` is run by CI, while the functions
 * themselves are only type-checked. Logic that decides whether a
 * stranger may mark an invoice paid belongs on the side that is run.
 *
 * ## The source string
 *
 * Billplz signs its callbacks by taking every parameter except
 * `x_signature`, sorting them by key, joining each key immediately to
 * its own value, and putting `|` between the pairs:
 *
 *     amount500|collection_idinbmmepb|idW_break|paidtrue|statepaid
 *
 * The redirect back to the browser carries the same fields under
 * `billplz[...]` names, and signs the flattened form — `billplz[id]`
 * signs as `billplzid`.
 *
 * ## What a mistake here does
 *
 * `www.billplz.com` was unreachable from the environment this was
 * written in, so the rule above is from the published specification
 * rather than a page fetched at the time. That matters less than it
 * looks, because of which way it fails: if the construction is wrong,
 * the signature we compute never equals the one Billplz sent, every
 * callback is rejected, and invoices stay unpaid. Visible, and safe. It
 * cannot fail the other way — accepting a forged callback still needs
 * the key. Confirm the ordering against Billplz's documentation before
 * going live; do not "fix" it by weakening the comparison.
 */

/** The pairs a signature is computed over, already flattened. */
export type SignedParams = Record<string, string>;

/**
 * Everything but the signature itself, sorted, `key` then `value`,
 * joined by `|`.
 *
 * Sorting by code unit rather than by locale, deliberately: every key
 * Billplz sends is ASCII, and a locale-aware collation would put
 * `paid_amount` and `paid_at` in whichever order the runtime's locale
 * happened to prefer.
 */
export function billplzSourceString(params: SignedParams): string {
  return Object.keys(params)
    .filter((k) => k !== "x_signature")
    .sort()
    .map((k) => `${k}${params[k]}`)
    .join("|");
}

/**
 * Turn the redirect's `billplz[id]` names into the ones it signs.
 *
 * Anything not shaped like `billplz[...]` is dropped rather than passed
 * through: the redirect URL is under the payer's control, and a query
 * parameter they appended is not something to feed into a signature
 * check.
 */
export function flattenRedirectParams(params: URLSearchParams): SignedParams {
  const out: SignedParams = {};
  for (const [key, value] of params.entries()) {
    const match = key.match(/^billplz\[([a-z0-9_]+)\]$/i);
    if (match) out[`billplz${match[1]}`] = value;
  }
  return out;
}

async function hmacSha256Hex(key: string, message: string): Promise<string> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    cryptoKey,
    new TextEncoder().encode(message),
  );
  return Array.from(new Uint8Array(signature))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * The signature Billplz should have sent for these parameters.
 *
 * Refuses an empty key by name. WebCrypto refuses it too — `importKey`
 * throws `DataError: Key length is zero` — but that arrives from three
 * frames down with nothing in it about which secret was missing, and a
 * function that cannot sign because nobody set its key should say so.
 */
export function billplzSignature(
  params: SignedParams,
  key: string,
): Promise<string> {
  if (!key || key.length === 0) {
    throw new Error("BILLPLZ_XSIGNATURE_KEY is not set; cannot sign or verify");
  }
  return hmacSha256Hex(key, billplzSourceString(params));
}

/**
 * Compares without an early exit, the same way `scheduler.ts` does and
 * for the same reason: how long the comparison takes must not say how
 * much of the value was right.
 */
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/**
 * Is this callback Billplz's?
 *
 * Refuses an empty key outright. Without that, a function deployed
 * before anybody set `BILLPLZ_XSIGNATURE_KEY` would compute an HMAC
 * under the empty key and happily accept a callback from anyone who
 * worked out that it had — which is the entire failure this function
 * exists to not have, so it is the first thing checked. Same for an
 * absent signature: no signature is not a signature that matched.
 */
export async function verifyBillplzSignature(
  params: SignedParams,
  supplied: string | null | undefined,
  key: string | null | undefined,
): Promise<boolean> {
  if (!key || key.length === 0) return false;
  if (!supplied || supplied.length === 0) return false;
  const expected = await billplzSignature(params, key);
  return safeEqual(expected.toLowerCase(), supplied.trim().toLowerCase());
}

/** Sandbox and live are different hosts, not a flag on the request. */
export function billplzApiBase(mode: string): string {
  return mode === "live"
    ? "https://www.billplz.com/api/v3"
    : "https://www.billplz-sandbox.com/api/v3";
}

/**
 * Ringgit as Billplz counts them.
 *
 * Cents, as an integer. `Math.round` rather than a truncation because
 * 12.34 is not exactly representable and `12.34 * 100` is
 * 1233.9999999999998 — truncating that undercharges by a sen, on every
 * invoice whose amount happens to land badly.
 */
export function toSen(amount: number): number {
  return Math.round(amount * 100);
}

export interface BillplzBill {
  id: string;
  url: string;
  state: string;
  amount: number;
}

/**
 * Create a bill and hand back where to send the payer.
 *
 * The secret key is the HTTP Basic username with an empty password,
 * which is Billplz's scheme. It is read by the caller from an Edge
 * Function secret and passed in; nothing here reads the environment, so
 * this stays testable and the secret has exactly one place it lives.
 */
export async function createBillplzBill(opts: {
  apiBase: string;
  secretKey: string;
  collectionId: string;
  email: string;
  name: string;
  amountSen: number;
  description: string;
  callbackUrl: string;
  redirectUrl?: string;
  reference?: string;
}): Promise<BillplzBill> {
  const form = new URLSearchParams({
    collection_id: opts.collectionId,
    email: opts.email,
    name: opts.name,
    amount: String(opts.amountSen),
    // Billplz truncates the description; the invoice number is the part
    // that has to survive, so it goes first.
    description: opts.description.slice(0, 200),
    callback_url: opts.callbackUrl,
  });
  if (opts.redirectUrl) form.set("redirect_url", opts.redirectUrl);
  if (opts.reference) {
    form.set("reference_1_label", "Invoice");
    form.set("reference_1", opts.reference);
  }

  const res = await fetch(`${opts.apiBase}/bills`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${btoa(`${opts.secretKey}:`)}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: form.toString(),
  });

  const text = await res.text();
  if (!res.ok) {
    // The body may name the collection or quote the key back; it goes
    // to the caller's log, never to the browser.
    throw new Error(`Billplz refused the bill (${res.status}): ${text}`);
  }
  const bill = JSON.parse(text) as BillplzBill;
  if (!bill?.id || !bill?.url) {
    throw new Error("Billplz accepted the bill but returned no id or url");
  }
  return bill;
}
