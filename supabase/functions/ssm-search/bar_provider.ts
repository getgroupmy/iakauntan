/**
 * The Malaysian Bar's legal directory, read the way a browser reads it.
 *
 * ---------------------------------------------------------------------
 * Read this before changing anything here
 *
 * The Bar Council publishes no API. This reaches
 * `legaldirectory.malaysianbar.org.my` — its public register of
 * advocates and solicitors holding a valid practising certificate, and
 * of registered law firms — by asking for its search page and reading
 * the HTML that comes back.
 *
 * That is scraping somebody's website, and this repository already has
 * a position on doing it: `provider.ts` says so at length about
 * ssmsearch.com and keeps a cache and a per-minute limit as the
 * difference between a modest volume and a conspicuous one. The same
 * applies here and for the same reason. Removing them changes what
 * this is.
 *
 * It is running while proper access is arranged, the same as the SSM
 * one. The clean way in is the Bar Council granting it.
 *
 * ---------------------------------------------------------------------
 * THE SHAPE BELOW IS A GUESS
 *
 * Nobody has seen this site's HTML from a machine that could also run
 * this code: the network the repository is edited on refuses the host
 * outright, with a 403 from its own egress proxy. So every selector,
 * every parameter name and the search path itself are inferences from
 * the site's public URLs and nothing stronger.
 *
 * `0589` made exactly this mistake against ssmsearch.com — "the paths
 * this shipped with were a guess and the first live sign-in proved
 * them wrong" — and the fix it arrived at is the one used here:
 *
 *   * every route is overridable by a secret, so an operator who can
 *     see the real thing corrects it without a deploy;
 *   * `probeBar` reports what the site actually answers, so finding
 *     the truth is one button rather than an afternoon;
 *   * the reader tries several plausible shapes rather than one, and
 *     returns nothing rather than guessing when it recognises none.
 *
 * Until a live probe has corrected them, treat a working search here
 * as luck.
 */
import { type SearchResult, SsmError, type SsmEntity } from "./provider.ts";

/** Anything with `.from()` and `.rpc()`; the service-role client. */
// deno-lint-ignore no-explicit-any
type Db = any;

export interface BarRoutes {
  /** `https://legaldirectory.malaysianbar.org.my` */
  root: string;
  /** The results page. `/v/search-result` is what the public URLs show. */
  searchPath: string;
  /**
   * The query parameter the search reads.
   *
   * A guess, and the most likely to be wrong. `probeBar` reports which
   * of the candidates below produced rows.
   */
  queryParam: string;
}

export const DEFAULT_BAR_ROUTES: BarRoutes = {
  root: "https://legaldirectory.malaysianbar.org.my",
  searchPath: "/v/search-result",
  queryParam: "name",
};

/**
 * Parameter names worth trying, commonest first.
 *
 * Used by the probe rather than by a search: a search sends the one
 * configured name, because trying five of them per lookup is five
 * times the volume against somebody else's server.
 */
export const BAR_QUERY_CANDIDATES = [
  "name",
  "q",
  "search",
  "keyword",
  "lawyer",
  "s",
];

export class BarDirectoryWeb {
  readonly name = "bar_web";

  constructor(
    private readonly db: Db,
    private readonly routes: BarRoutes = DEFAULT_BAR_ROUTES,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  private url(query: string, page: number): string {
    const root = this.routes.root.replace(/\/+$/, "");
    const path = this.routes.searchPath.startsWith("/")
      ? this.routes.searchPath
      : "/" + this.routes.searchPath;
    const u = new URL(root + path);
    u.searchParams.set(this.routes.queryParam, query);
    if (page > 1) u.searchParams.set("page", String(page));
    return u.toString();
  }

  async search(
    query: string,
    _typeId: number | null,
    page: number,
    perPage: number,
  ): Promise<SearchResult> {
    let res: Response;
    try {
      res = await this.fetchImpl(this.url(query, page), {
        headers: {
          // Asked for as a browser asks. Not a disguise — the site
          // serves HTML and will hand back something else, or nothing,
          // to a request that claims to want JSON.
          "accept": "text/html,application/xhtml+xml",
          "accept-language": "en-MY,en;q=0.9",
        },
      });
    } catch (e) {
      await this.noteError(`unreachable: ${(e as Error)?.message ?? e}`);
      throw new SsmError(
        "SSM_UNREACHABLE",
        "The Bar's directory is not answering. Try again shortly.",
        504,
      );
    }

    if (res.status === 403 || res.status === 429) {
      // Their server saying no, which is not the same as no results.
      // Said plainly because the answer is to stop for a while, not to
      // retype the name.
      await this.noteError(`refused with HTTP ${res.status}`);
      throw new SsmError(
        "SSM_RATE_LIMITED",
        "The Bar's directory refused the lookup. Try again later.",
        429,
      );
    }
    if (!res.ok) {
      await this.noteError(`HTTP ${res.status}`);
      throw new SsmError(
        "SSM_SEARCH_FAILED",
        `The Bar's directory answered HTTP ${res.status}.`,
        502,
      );
    }

    const html = await res.text();
    const items = readBarRows(html);
    return {
      items,
      // The directory does not say how many matches there are in any
      // form this can read, so `total` says "this page and possibly
      // more" rather than claiming a count it does not have.
      total: items.length < perPage
        ? (page - 1) * perPage + items.length
        : page * perPage + 1,
      page,
      per_page: items.length,
    };
  }

  /**
   * There is no session to establish — the directory is public — so
   * this asks for one page and reports whether anything came back that
   * looks like a row.
   *
   * Which is the honest version of "does the configuration work",
   * given the routes are a guess.
   */
  async testLogin(): Promise<{ logged_in_as: string | null }> {
    const out = await this.search("LEE", null, 1, 20);
    return {
      logged_in_as: `bar:${out.items.length} row(s) for a common surname`,
    };
  }

  /**
   * The same row the web provider writes its failures to, so the admin
   * page shows the last error whichever provider produced it.
   */
  private async noteError(message: string): Promise<void> {
    try {
      await this.db.from("ssm_session").update({
        last_error: `bar: ${message}`.slice(0, 500),
        last_error_at: new Date().toISOString(),
      }).eq("id", 1);
    } catch { /* logging must never break the call */ }
  }
}

// ---------------------------------------------------------------------
// Reading the page
// ---------------------------------------------------------------------

/**
 * Rows out of the directory's HTML.
 *
 * Deliberately not a DOM parse: Deno has no DOM, and pulling one in for
 * this would be a dependency to keep current for somebody else's
 * markup. Two shapes are tried, both of which a directory of this age
 * plausibly emits, and anything else returns nothing rather than
 * inventing a person.
 *
 * Returning NOTHING is the safe direction and is why there is no
 * clever fallback: a name this recognised wrongly becomes a solicitor
 * on a client record, and an empty result reads as "not found", which
 * is recoverable.
 */
export function readBarRows(html: string): SsmEntity[] {
  const rows = readTableRows(html);
  if (rows.length > 0) return rows;
  return readCardRows(html);
}

/** `<table>` of `<tr><td>`, which is what most directories of this age are. */
function readTableRows(html: string): SsmEntity[] {
  const out: SsmEntity[] = [];
  for (const tr of matchAll(html, /<tr[^>]*>([\s\S]*?)<\/tr>/gi)) {
    const cells = [...matchAll(tr, /<t[dh][^>]*>([\s\S]*?)<\/t[dh]>/gi)]
      .map(stripTags);
    // A header row, or something that is not a row of results.
    if (cells.length < 2) continue;
    const name = cells[0];
    if (!name || looksLikeHeading(name)) continue;
    out.push(entity(name, cells.slice(1)));
  }
  return out;
}

/**
 * A list of `<div class="...card...">`, which is what a rebuild would
 * be.
 *
 * Sliced between opening tags rather than matched to a closing one.
 * A card contains `<div>`s, and a non-greedy match to the first
 * `</div>` stops at the end of the FIRST child — which took the name
 * and dropped everything after it, including the number. Caught by a
 * test asserting the number came through; the regex looked right and
 * was not.
 */
function readCardRows(html: string): SsmEntity[] {
  const opens = [
    ...html.matchAll(
      /<(?:div|li|article)[^>]*class="[^"]*(?:card|result|listing|entry)[^"]*"[^>]*>/gi,
    ),
  ];
  const out: SsmEntity[] = [];
  for (let i = 0; i < opens.length; i++) {
    const from = opens[i].index! + opens[i][0].length;
    const to = i + 1 < opens.length ? opens[i + 1].index! : html.length;
    const lines = stripTags(html.slice(from, to))
      .split("\n")
      .map((l) => l.trim())
      .filter(Boolean);
    if (lines.length === 0) continue;
    const name = lines[0];
    if (!name || looksLikeHeading(name)) continue;
    out.push(entity(name, lines.slice(1)));
  }
  return out;
}

/**
 * One advocate or firm as the rest of this already reads an entity.
 *
 * `ssm_id` and `slug` are null and honestly so — they are
 * ssmsearch.com's own handles and the Bar has neither. The enrolment
 * or firm number goes to `reg_no` where one can be recognised, because
 * that is the field a contact record keeps a registration in.
 */
function entity(name: string, rest: string[]): SsmEntity {
  const joined = rest.join(" · ");
  return {
    ssm_id: null,
    name: tidy(name),
    slug: null,
    reg_no: findNumber(joined),
    reg_no_old: null,
    entity_type_id: null,
    // Not a kind of business: what the Bar registers is a person or a
    // firm of them, and saying so beats leaving it null.
    entity_type: looksLikeFirm(name) ? "Law Firm" : "Advocate & Solicitor",
  };
}

/**
 * A membership or firm number, if one is in the row.
 *
 * Left null rather than guessed at: the directory shows telephone
 * numbers and postcodes too, and a postcode written into a contact's
 * registration number is worse than an empty field.
 */
function findNumber(text: string): string | null {
  const m = text.match(/\b(?:no\.?|number|enrolment)\s*[:.]?\s*([A-Z0-9/-]{4,20})\b/i);
  return m ? m[1] : null;
}

function looksLikeFirm(name: string): boolean {
  // No `\b` before the ampersand. `&` is not a word character, so
  // `\b&` asks for a word character immediately before it — and in
  // "ABC & CO" there is a space there, so it never matched and every
  // firm read as a person. A test on "ABC & CO" is what found it.
  return /(?:&|\band)\s+(?:co|partners|associates)\b|\bchambers\b|\bplt\b/i
    .test(name);
}

/** A table heading rather than a person. */
function looksLikeHeading(text: string): boolean {
  return /^(?:name|lawyer|advocate|firm|contact|state|no\.?|#)$/i.test(
    text.trim(),
  );
}

function stripTags(html: string): string {
  return decode(
    html
      .replace(/<(?:script|style)[\s\S]*?<\/(?:script|style)>/gi, " ")
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(/<\/(?:p|div|li|tr)>/gi, "\n")
      .replace(/<[^>]+>/g, " "),
  ).replace(/[ \t]+/g, " ").trim();
}

function decode(s: string): string {
  return s
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&quot;/gi, '"')
    .replace(/&#0?39;|&apos;/gi, "'")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">");
}

function tidy(s: string): string {
  return s.replace(/\s+/g, " ").trim();
}

function* matchAll(s: string, re: RegExp): Generator<string> {
  for (const m of s.matchAll(re)) yield m[1] ?? "";
}

// ---------------------------------------------------------------------
// Finding out what is actually there
// ---------------------------------------------------------------------
export interface BarProbeHit {
  param: string;
  url: string;
  status: number;
  rows: number;
  /** A short piece of what came back, for a person to read. */
  said: string;
}

/**
 * Ask the directory with each candidate parameter and report which
 * produced rows.
 *
 * This is the whole answer to "the shape is a guess". One press from
 * an operator who can reach the site turns every inference in this
 * file into a fact, and the winning parameter goes into a secret.
 *
 * Pure but for the fetch, which is passed in.
 */
export async function probeBar(
  fetchImpl: typeof fetch,
  routes: BarRoutes = DEFAULT_BAR_ROUTES,
  term = "LEE",
  params: string[] = BAR_QUERY_CANDIDATES,
): Promise<BarProbeHit[]> {
  const root = routes.root.replace(/\/+$/, "");
  const path = routes.searchPath.startsWith("/")
    ? routes.searchPath
    : "/" + routes.searchPath;

  const out: BarProbeHit[] = [];
  for (const param of params) {
    const u = new URL(root + path);
    u.searchParams.set(param, term);
    try {
      const res = await fetchImpl(u.toString(), {
        headers: { "accept": "text/html,application/xhtml+xml" },
      });
      const html = res.ok ? await res.text() : "";
      out.push({
        param,
        url: u.toString(),
        status: res.status,
        rows: html ? readBarRows(html).length : 0,
        said: stripTags(html).slice(0, 200),
      });
    } catch (e) {
      out.push({
        param,
        url: u.toString(),
        status: 0,
        rows: 0,
        said: (e as Error)?.message ?? "unreachable",
      });
    }
  }
  return out;
}
