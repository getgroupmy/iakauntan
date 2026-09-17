/**
 * Talking to ssmsearch.com, and the one shape the rest of this cares
 * about.
 *
 * ---------------------------------------------------------------------
 * Read this before changing anything here
 *
 * This signs in to ssmsearch.com the way its own website does and calls
 * its search endpoint from a server. Their terms of service prohibit
 * reaching the service "on another website or server … through … any
 * other technological means", and prohibit sharing login credentials.
 * It is running while the official SSM Corporate API is arranged, and
 * `docs/ssm-lookup.md` says so where an operator will read it rather
 * than only here.
 *
 * That is why the cache and the per-user limit are not optimisations.
 * They are the difference between a modest volume and a conspicuous
 * one, and removing them changes what this is.
 *
 * ---------------------------------------------------------------------
 * Switching to the real API later
 *
 * Everything above `search()` is the contract: a query in, `SsmEntity[]`
 * out. When Infomina supply the entity-search endpoint, a second class
 * implementing the same two methods is the whole change, chosen by
 * `SSM_PROVIDER`. Deliberately not stubbed here — an unimplemented
 * class that type-checks is a thing somebody switches on by accident.
 */

export interface SsmEntity {
  ssm_id: number | null;
  name: string;
  slug: string | null;
  reg_no: string | null;
  reg_no_old: string | null;
  entity_type_id: number | null;
  entity_type: string | null;
}

export interface SearchResult {
  items: SsmEntity[];
  total: number;
  page: number;
  per_page: number;
}

/** The four kinds SSM registers, by the id its search uses. */
export const ENTITY_TYPES: Record<number, string> = {
  1: "Company",
  2: "Business",
  3: "Audit Firm",
  25: "Limited Liability Partnership",
};

export class SsmError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly status = 502,
  ) {
    super(message);
  }
}

interface SessionRow {
  token: string | null;
  logged_in_as: string | null;
  obtained_at: string | null;
  upstream_user: UpstreamUser | null;
}

/**
 * What ssmsearch.com said about the account at sign-in. Their website
 * sends these back as `_user_id`, `_org_id`, `_org_role` and `_role_id`
 * in the body of EVERY call, alongside the Bearer token -- the token on
 * its own is answered with `is_not_logged_in: true` and no rows.
 */
export interface UpstreamUser {
  id: unknown;
  orgId: unknown;
  orgRole: unknown;
  roleId: unknown;
}

/**
 * Where ssmsearch.com's own website sends its requests.
 *
 * Read off their front-end on 14 Sep 2026 (the Nuxt runtime config and
 * the API wrapper in its main bundle), and confirmed against the live
 * host with no credentials:
 *
 *   FE_ROOT   https://ssmsearch.com        the website (Nuxt)
 *   API_ROOT  https://api.ssmsearch.com    the API (Fastify)
 *
 * The first version of this pointed at `https://ssmsearch.com/api`, and
 * every path under it answered `Page not found: /api/...` -- that is
 * the WEBSITE's catch-all 404 page, not an API saying the path is
 * wrong. `/user/login` was right all along; only the host was not.
 *
 * Every call is a POST with a JSON body. Sign-in is
 * `POST /user/login {email, password, recaptchaToken: ""}` (their own
 * login form sends the empty token) and answers the user record with
 * `token` in it; a wrong password is a 400 `{"message": "Email or
 * password is invalid"}`. Search is `POST /company/search` with
 * `Authorization: Bearer <token>` -- see `call`.
 *
 * Each piece is still overridable by an edge-function secret, so a
 * change on their side is a secret change rather than a deploy:
 *
 *   SSMSEARCH_API_ROOT      https://api.ssmsearch.com
 *   SSMSEARCH_LOGIN_PATH    /user/login
 *   SSMSEARCH_SEARCH_PATH   /company/search
 *
 * They are endpoints and not credentials — nothing secret about a URL —
 * but they live beside the login because that is where this function's
 * configuration is, and one place beats two.
 */
export interface Routes {
  apiRoot: string;
  loginPath: string;
  searchPath: string;
}

export const DEFAULT_ROUTES: Routes = {
  apiRoot: "https://api.ssmsearch.com",
  loginPath: "/user/login",
  searchPath: "/company/search",
};

/** Anything with `.from()` and `.rpc()`; the service-role client. */
// deno-lint-ignore no-explicit-any
type Db = any;

export class SsmSearchWeb {
  readonly name = "ssmsearch_web";

  constructor(
    private readonly db: Db,
    private readonly email: string,
    private readonly password: string,
    private readonly routes: Routes = DEFAULT_ROUTES,
    private readonly fetchImpl: typeof fetch = fetch,
    private readonly sleep = (ms: number) =>
      new Promise<void>((r) => setTimeout(r, ms)),
  ) {}

  private url(path: string): string {
    return this.routes.apiRoot.replace(/\/+$/, "") +
      (path.startsWith("/") ? path : "/" + path);
  }

  async search(
    query: string,
    typeId: number | null,
    page: number,
    perPage: number,
  ): Promise<SearchResult> {
    let session = await this.session();
    let res = await this.call(session, query, typeId, page, perPage);

    // The token went stale. One fresh login and one retry — not a loop:
    // a second failure after a successful login is ssmsearch.com saying
    // no to this account, and retrying that is just asking again.
    if (this.rejected(res.status, res.body)) {
      session = await this.login("the token was rejected");
      res = await this.call(session, query, typeId, page, perPage);
      if (this.rejected(res.status, res.body)) {
        await this.noteError(
          `Search refused after a fresh sign-in: HTTP ${res.status} ${
            JSON.stringify(res.body).slice(0, 300)
          }`,
        );
        throw new SsmError(
          "SSM_AUTH_FAILED",
          "ssmsearch.com refused the search even after signing in again.",
        );
      }
    }

    if (res.status < 200 || res.status >= 300) {
      throw new SsmError(
        "SSM_UPSTREAM_ERROR",
        `ssmsearch.com answered ${res.status}.`,
      );
    }

    await this.db.from("ssm_session")
      .update({ last_used_at: new Date().toISOString() }).eq("id", 1);

    return normalise(res.body, page, perPage);
  }

  /** Sign in now and say who we are, for the admin page's Test login. */
  async testLogin(): Promise<{ logged_in_as: string | null }> {
    const s = await this.login("asked to test");
    return { logged_in_as: s.logged_in_as };
  }

  private async session(): Promise<SessionRow> {
    const { data } = await this.db.from("ssm_session")
      .select("token, logged_in_as, obtained_at, upstream_user").eq("id", 1).maybeSingle();
    if (data?.token) return data as SessionRow;
    return this.login("there was no session yet");
  }

  /**
   * Sign in, once across every instance.
   *
   * ssmsearch.com is ONE shared account, so two instances signing in
   * together can invalidate each other's token — which is a loop, not a
   * race. `ssm_session_try_lock` decides who goes; the loser waits for
   * the winner's token rather than signing in behind it.
   */
  private async login(reason: string): Promise<SessionRow> {
    const before = await this.db.from("ssm_session")
      .select("token, obtained_at").eq("id", 1).maybeSingle();

    const { data: gotLock } = await this.db.rpc("ssm_session_try_lock");
    if (!gotLock) {
      for (let i = 0; i < 4; i++) {
        await this.sleep(1200);
        const { data } = await this.db.from("ssm_session")
          .select("token, logged_in_as, obtained_at, upstream_user").eq("id", 1).maybeSingle();
        if (data?.token && data.obtained_at !== before.data?.obtained_at) {
          return data as SessionRow;
        }
      }
      // The holder died or is very slow. Going ahead is better than
      // refusing a search over a lock that expires in seconds anyway.
    }

    let res: Response;
    try {
      res = await this.fetchImpl(this.url(this.routes.loginPath), {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "accept": "application/json",
        },
        body: JSON.stringify({
          recaptchaToken: "",
          email: this.email,
          password: this.password,
        }),
      });
    } catch (e) {
      await this.noteError(`Could not reach ssmsearch.com: ${String(e)}`);
      throw new SsmError("SSM_UNREACHABLE", "Could not reach ssmsearch.com.");
    }

    const body = await asJson(res);
    const token = typeof body.token === "string" ? body.token : "";
    if (!res.ok || !token) {
      // Their words, not ours. A login refused for a reason only
      // ssmsearch.com knows is one only their message can explain.
      const said = typeof body.message === "string"
        ? body.message
        : `HTTP ${res.status}`;
      // The URL as well as their answer. "Page not found: /user/login"
      // is their words about a path, and the useful question is which
      // path THIS deployment asked for -- which is a secret now, and
      // therefore not something the reader of this log can assume.
      await this.noteError(
        `Sign-in failed (${reason}): ${said} [POST ${
          this.url(this.routes.loginPath)
        }]`,
      );
      throw new SsmError(
        "SSM_LOGIN_FAILED",
        `ssmsearch.com would not sign in: ${said}`,
      );
    }

    const row: SessionRow = {
      token,
      logged_in_as: typeof body.email === "string" ? body.email : this.email,
      obtained_at: new Date().toISOString(),
      upstream_user: {
        id: body.id ?? null,
        orgId: body.orgId ?? null,
        orgRole: body.orgRole ?? null,
        roleId: body.roleId ?? null,
      },
    };
    await this.db.from("ssm_session").update({
      provider: this.name,
      ...row,
      last_error: null,
      last_error_at: null,
      refresh_lock_at: null,
      updated_at: new Date().toISOString(),
    }).eq("id", 1);
    return row;
  }

  /**
   * One search, the way their website makes it: a POST with a JSON body
   * to api.ssmsearch.com, the session as a Bearer token.
   *
   * `offset` is their name for the PAGE SIZE (their table offers 10, 25,
   * 50 and 100), not a row offset, and `sort` is an object, `{}` when
   * nothing is sorted. `type_id` is only sent when there is a filter,
   * as their site does. Without a valid token the same route answers
   * 200 with `is_not_logged_in: true` and no rows -- `rejected` reads
   * that as "sign in again", not as "no results".
   */
  private async call(
    session: SessionRow,
    query: string,
    typeId: number | null,
    page: number,
    perPage: number,
  ) {
    let res: Response;
    try {
      res = await this.fetchImpl(this.url(this.routes.searchPath), {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "accept": "application/json",
          ...(session.token ? { authorization: `Bearer ${session.token}` } : {}),
        },
        body: JSON.stringify({
          _user_id: session.upstream_user?.id ?? null,
          _org_id: session.upstream_user?.orgId ?? null,
          _org_role: session.upstream_user?.orgRole ?? null,
          _role_id: session.upstream_user?.roleId ?? null,
          search: query,
          ...(typeId !== null ? { type_id: typeId } : {}),
          page,
          offset: perPage,
          sort: {},
        }),
      });
    } catch (e) {
      throw new SsmError(
        "SSM_UNREACHABLE",
        `Could not reach ssmsearch.com: ${String(e)}`,
      );
    }
    return { status: res.status, body: await asJson(res) };
  }

  /** Their several ways of saying "sign in again". */
  private rejected(status: number, body: Record<string, unknown>): boolean {
    if (status === 401 || status === 403) return true;
    if (body.is_not_logged_in === true) return true;
    const code = body.code ?? body.error;
    return code === "is_not_logged_in";
  }

  private async noteError(message: string) {
    await this.db.from("ssm_session").update({
      last_error: message,
      last_error_at: new Date().toISOString(),
      refresh_lock_at: null,
    }).eq("id", 1);
  }
}

async function asJson(res: Response): Promise<Record<string, unknown>> {
  const text = await res.text();
  if (!text) return {};
  try {
    const v = JSON.parse(text);
    return typeof v === "object" && v !== null
      ? v as Record<string, unknown>
      : {};
  } catch {
    return {};
  }
}

/**
 * Their answer in the one shape the app knows.
 *
 * Written to survive their field names moving: every key is tried in
 * the several spellings their own frontend uses, and a row that yields
 * no name is dropped rather than shown as a blank line somebody might
 * pick.
 */
export function normalise(
  body: Record<string, unknown>,
  page: number,
  perPage: number,
): SearchResult {
  const raw = firstArray(body, ["data", "items", "results", "companies"]);
  const items: SsmEntity[] = [];

  for (const r of raw) {
    if (typeof r !== "object" || r === null) continue;
    const o = r as Record<string, unknown>;
    const name = str(o, ["name", "companyName", "title", "entityName"]);
    if (!name) continue;

    const typeId = num(o, [
      "typeId", "entityTypeId", "type_id", "entity_type_id", "type",
    ]);
    items.push({
      ssm_id: num(o, ["id", "companyId", "entityId"]),
      name,
      slug: str(o, ["slug", "handle"]),
      reg_no: str(o, ["regNo", "registrationNo", "newRegNo", "reg_no", "brn"]),
      reg_no_old: str(o, [
        "reg_no_old", "oldRegNo", "regNoOld", "oldRegistrationNo",
      ]),
      entity_type_id: typeId,
      entity_type: str(o, [
        "entity", "entity_type", "typeName", "entityType", "type_title",
      ]) ?? (typeId !== null ? ENTITY_TYPES[typeId] ?? null : null),
    });
  }

  const total = num(body, ["total", "totalCount", "count"]) ?? items.length;
  return { items, total, page, per_page: perPage };
}

function firstArray(o: Record<string, unknown>, keys: string[]): unknown[] {
  for (const k of keys) if (Array.isArray(o[k])) return o[k] as unknown[];
  // Some of their endpoints answer with the array at the top level.
  return [];
}

function str(o: Record<string, unknown>, keys: string[]): string | null {
  for (const k of keys) {
    const v = o[k];
    if (typeof v === "string" && v.trim() !== "") return v.trim();
    if (typeof v === "number") return String(v);
  }
  return null;
}

function num(o: Record<string, unknown>, keys: string[]): number | null {
  for (const k of keys) {
    const v = o[k];
    if (typeof v === "number" && Number.isFinite(v)) return v;
    if (typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v))) {
      return Number(v);
    }
  }
  return null;
}

// ---------------------------------------------------------------------
// Finding the endpoints, kept because it earned its place
// ---------------------------------------------------------------------
//
// The first version of this function pointed at the wrong host, and the
// first live sign-in answered `Page not found: /api/user/login` -- the
// website's 404 page, which read like an API answer. This probe is what
// makes that difference visible from the admin page: it asks the
// configured API root which of a short list of paths are routes, so an
// operator can tell a wrong host (everything 404) from a wrong path
// (some things answer) without a browser's developer tools.
//
// ## Nothing is signed in to
//
// Every probe sends an EMPTY JSON body. A login route answers a request
// with no credentials with 400, 401 or 422 -- it validates, or it
// refuses -- a search route answers 200 with `is_not_logged_in: true`,
// and a path that is not a route answers 404. That is the whole
// distinction being drawn, and it needs no password.
//
// Sending the real one to fifteen guessed paths would be spraying a
// working credential across a third party's URL space to learn
// something an empty body answers just as well.
//
// ## And it is fifteen requests, once
//
// Not a crawl. The list is short, deliberate, and shaped like the
// conventions of the framework their 404 message comes from; it runs
// when somebody presses a button, and the result names a path to put in
// a secret.

export const LOGIN_CANDIDATES = [
  "/user/login",
  "/login",
  "/auth/login",
  "/users/login",
  "/user/signin",
  "/signin",
  "/account/login",
  "/v1/user/login",
  "/v1/login",
  "/sanctum/token",
];

export const SEARCH_CANDIDATES = [
  "/company/search",
  "/companies/search",
  "/search",
  "/search/company",
  "/entity/search",
];

export interface ProbeHit {
  path: string;
  method: string;
  status: number;

  /** Whatever they said, trimmed to something a screen can hold. */
  said: string;

  /**
   * Whether this looks like a real route.
   *
   * 404 is the answer being ruled out. Everything else -- a validation
   * complaint, a refusal, a redirect, even a 500 -- means something is
   * listening at that path, which is exactly what is being looked for.
   */
  exists: boolean;
}

/**
 * Ask which of these paths are routes.
 *
 * Pure but for the fetch, which is passed in, so the classification
 * below can be asserted without a network.
 */
export async function probeRoutes(
  fetchImpl: typeof fetch,
  apiRoot: string,
  loginPaths: string[] = LOGIN_CANDIDATES,
  searchPaths: string[] = SEARCH_CANDIDATES,
): Promise<{ login: ProbeHit[]; search: ProbeHit[] }> {
  const root = apiRoot.replace(/\/+$/, "");

  const ask = async (
    path: string,
    method: "POST" | "GET",
  ): Promise<ProbeHit> => {
    const url = root + (path.startsWith("/") ? path : "/" + path) +
      (method === "GET" ? "?q=test" : "");
    try {
      const res = await fetchImpl(url, {
        method,
        headers: {
          "accept": "application/json",
          ...(method === "POST" ? { "content-type": "application/json" } : {}),
        },
        // Empty on purpose. See the header above.
        ...(method === "POST" ? { body: "{}" } : {}),
      });
      const text = (await res.text()).slice(0, 400);
      let said = text;
      try {
        const parsed = JSON.parse(text);
        if (parsed && typeof parsed.message === "string") said = parsed.message;
      } catch {
        // Not JSON. Their HTML error page is still a useful answer, and
        // the first 160 characters of it say which one it is.
        said = text.replace(/\s+/g, " ").slice(0, 160);
      }
      return {
        path,
        method,
        status: res.status,
        said: said.slice(0, 200),
        exists: res.status !== 404,
      };
    } catch (e) {
      return {
        path,
        method,
        status: 0,
        said: String(e).slice(0, 200),
        exists: false,
      };
    }
  };

  // In series rather than all at once. Ten parallel requests at a
  // third party from one IP is the shape of something being scanned,
  // and the whole point of this feature's caution is not to look like
  // that. Fifteen sequential requests take a couple of seconds.
  const login: ProbeHit[] = [];
  for (const p of loginPaths) login.push(await ask(p, "POST"));
  const search: ProbeHit[] = [];
  for (const p of searchPaths) search.push(await ask(p, "POST"));
  return { login, search };
}
