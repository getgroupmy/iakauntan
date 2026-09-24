/**
 * What the reader actually said, kept for somebody to read later.
 *
 * Asked for from the console: "all scanning activities should be logged
 * and all error or reply by models should be logged in raw as this is
 * to be used for troubleshooting".
 *
 * What the console could show until now was `ocr_scans.error` -- one
 * sentence, written by us, from whichever field of the vendor's JSON we
 * thought to reach for. When a reader starts answering something the
 * code did not anticipate, that sentence is `HTTP 400` and the body
 * that would have explained it is gone: it was read once, inside the
 * reader, and thrown away.
 *
 * So the raw body is kept. Every call, not only the failures -- a
 * reading that came back wrong is the case where the reply matters
 * most, and by definition it did not fail.
 *
 * ## What is NOT kept
 *
 * The request. Not its headers and not its body, and that is the whole
 * of the key question: `x-api-key`, `Authorization: Bearer`, and
 * Gemini's `?key=` in the QUERY STRING, which is why [safeEndpoint]
 * strips the query rather than trusting that nobody put a secret in
 * one. Nothing here can leak a credential because nothing here is ever
 * handed one.
 *
 * The document's own bytes are not in the request we keep either, which
 * is the other reason not to keep it: a base64 receipt is a megabyte of
 * log per scan.
 */

/** One call to a reader, as it happened. */
export interface Exchange {
  /**
   * The reader this call went to, as a catalog code.
   *
   * Stamped by `runReader` after the fact rather than passed down into
   * five readers with no other use for it: this file knows the endpoint
   * and the answer, and only the caller knows whose they were.
   */
  provider?: string;
  /** Scheme, host and path. Never the query, never a credential. */
  endpoint: string;
  /** The HTTP status, or 0 where nothing answered at all. */
  status: number;
  /** How long it took, in milliseconds. */
  ms: number;
  ok: boolean;
  /** The response body verbatim, up to [MAX_BODY]. */
  body: string;
  truncated: boolean;
}

/**
 * How much of a body is kept.
 *
 * A reader's refusal is a few hundred bytes and a reading is a few
 * thousand. 16k keeps both whole and puts a bound on the one that is
 * neither -- an HTML error page from a proxy, which is the answer least
 * worth storing in full and the one most likely to be enormous.
 */
export const MAX_BODY = 16 * 1024;

/**
 * The endpoint, with anything secret taken off it.
 *
 * The query string goes ENTIRELY. Gemini's key travels in `?key=`, and
 * a rule that removed the parameters we know about would be a rule that
 * keeps the next vendor's. Nothing in a query string is worth a
 * credential in a log.
 *
 * Credentials in the authority (`https://user:pass@host`) go with it.
 * A string that is not a URL at all comes back as the empty string
 * rather than being passed through: an endpoint this cannot parse is an
 * endpoint it cannot promise to have cleaned.
 */
export function safeEndpoint(url: string): string {
  try {
    const u = new URL(url);
    return `${u.protocol}//${u.host}${u.pathname}`;
  } catch {
    return "";
  }
}

/** A body cut to [MAX_BODY], and whether it was cut. */
export function clip(text: string): { body: string; truncated: boolean } {
  if (text.length <= MAX_BODY) return { body: text, truncated: false };
  return { body: text.slice(0, MAX_BODY), truncated: true };
}

/**
 * Calls a reader and keeps what it said.
 *
 * A drop-in for `fetch` at the five call sites in `index.ts`: the
 * response handed back reads exactly like the real one, because the
 * body is read here ONCE as text and a fresh response is built from
 * that text. Reading it twice is not possible -- a body is a stream --
 * and this is the reason the recording happens here rather than beside
 * each `response.json()`.
 *
 * A fetch that THROWS is recorded too, at status 0, because "nothing
 * answered" is a different fault from "answered no" and the console
 * could not previously tell them apart. It is then rethrown unchanged.
 *
 * [fetcher] is for the tests. Nothing else passes it.
 */
export async function record(
  rec: Exchange[],
  url: string,
  init: RequestInit,
  fetcher: typeof fetch = fetch,
): Promise<Response> {
  const began = Date.now();
  let response: Response;
  try {
    response = await fetcher(url, init);
  } catch (e) {
    rec.push({
      endpoint: safeEndpoint(url),
      status: 0,
      ms: Date.now() - began,
      ok: false,
      body: e instanceof Error ? `${e.name}: ${e.message}` : String(e),
      truncated: false,
    });
    throw e;
  }

  const text = await response.text().catch(() => "");
  const { body, truncated } = clip(text);
  rec.push({
    endpoint: safeEndpoint(url),
    status: response.status,
    ms: Date.now() - began,
    ok: response.ok,
    body,
    truncated,
  });

  // A 204, 205 or 304 may not carry a body, and constructing one that
  // does throws. No reader answers with those, and a crash inside the
  // logging would be this file costing a scan it was only watching.
  const bodyless = response.status === 204 || response.status === 205 ||
    response.status === 304;
  return new Response(bodyless ? null : text, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  });
}
