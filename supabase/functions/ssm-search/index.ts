/**
 * ssm-search
 *
 * Looks a company up in SSM's register by name or registration number,
 * so a contact's name and BRN are what the registry says rather than
 * what somebody read off a letterhead. `registration_no` is what
 * MyInvois validates a party against, and a transposed digit is a
 * submission rejected or attributed to another company.
 *
 * POST { "action": "search", "query": "…", "type_id"?, "page"?, "per_page"? }
 *   -> { ok, provider, cached, items: [...], total, page, per_page }
 *
 * Other actions: `entity_types`, and for a platform administrator
 * `status`, `test_login`, `probe`, `clear_session`, `clear_cache`.
 *
 * `probe` asks ssmsearch.com which of a short list of paths are routes,
 * sending no credentials, because the paths this shipped with were a
 * guess and the first live sign-in proved them wrong. See
 * `probeRoutes`.
 *
 * ---------------------------------------------------------------------
 * Who is asking, and why that is not the service role
 *
 * This function holds the service-role key, because `ssm_session`, the
 * cache and the log are all service-role only — nothing a tenant may
 * read. So it builds TWO clients: the service-role one for those
 * tables, and a caller-scoped one carrying the request's own
 * `Authorization` header, which is what decides whether the caller is
 * signed in at all and whether they are a platform administrator.
 *
 * `app.is_platform_admin()` is asked through the CALLER's client. Asking
 * through the service role would answer about the service role, which
 * is to say yes, always, to anybody who can reach this URL.
 *
 * ---------------------------------------------------------------------
 * Secrets, none of which are in the repository or the database
 *
 *   SSMSEARCH_EMAIL     the platform's ssmsearch.com login
 *   SSMSEARCH_PASSWORD  its password
 *
 * Set in the Supabase dashboard, like `OCR_KEY_*` and `RESEND_API_KEY`.
 * Without them every search answers `SSM_NOT_CONFIGURED`, which the app
 * shows as "not set up yet" rather than as a failure somebody should
 * try again.
 *
 * Optional: SSM_CACHE_TTL_HOURS (24), SSM_RATE_LIMIT_PER_MIN (30).
 *
 * ---------------------------------------------------------------------
 * The caution
 *
 * The interim provider reaches ssmsearch.com in a way their terms of
 * service prohibit. See `provider.ts` and `docs/ssm-lookup.md`. The
 * cache and the rate limit are part of keeping this modest, not
 * optimisations to tune away.
 */
import { createClient } from "jsr:@supabase/supabase-js@2.117.0";
import { serveFunction } from "../_shared/cors.ts";
import {
  DEFAULT_ROUTES,
  probeRoutes,
  type Routes,
  SsmError,
  SsmSearchWeb,
} from "./provider.ts";
import {
  apiClientFromEnv,
  chosenProvider,
  SsmSearchApi,
} from "./api_provider.ts";
import {
  BarDirectoryWeb,
  type BarRoutes,
  DEFAULT_BAR_ROUTES,
  probeBar,
} from "./bar_provider.ts";

/**
 * The body shape, and NOT the CORS headers.
 *
 * `serveFunction` answers the preflight and stamps the cross-origin
 * headers onto every response on the way out, which is why this
 * function no longer carries a `CORS` constant of its own. The one it
 * had allowed `authorization, content-type` and nothing else, and
 * supabase-js sends `x-client-info` and `apikey` on every call — so
 * the browser's preflight was refused and the app showed
 * "ClientException: Load failed" with no status and no body to read.
 * `_shared/cors.ts` has the full list, and is also where
 * `ALLOWED_ORIGINS` is honoured.
 */
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function fail(code: string, message: string, status: number): Response {
  return json({ ok: false, error: { code, message } }, status);
}

function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`${name} is not set`);
  return v;
}

serveFunction("ssm-search", async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return fail("METHOD", "POST only", 405);

  const auth = req.headers.get("Authorization");
  if (!auth) return fail("UNAUTHENTICATED", "Sign in first.", 401);

  const url = env("SUPABASE_URL");
  // The caller's own client. Everything this can see is what RLS lets
  // THEM see, which is the whole reason it exists.
  const userClient = createClient(url, env("SUPABASE_ANON_KEY"), {
    global: { headers: { Authorization: auth } },
  });
  const admin = createClient(url, env("SUPABASE_SERVICE_ROLE_KEY"));

  const { data: userData } = await userClient.auth.getUser();
  const user = userData?.user;
  if (!user) return fail("UNAUTHENTICATED", "Sign in first.", 401);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return fail("BAD_REQUEST", "Expected a JSON body.", 400);
  }
  const action = String(body.action ?? "search");

  // Asked of the caller's client, never the service role's. See the
  // header: the service role is a platform administrator by definition,
  // so asking it is asking the wrong question.
  const isAdmin = async (): Promise<boolean> => {
    const { data } = await userClient.rpc("am_i_platform_admin");
    return data === true;
  };

  try {
    switch (action) {
      case "entity_types": {
        const { data, error } = await userClient
          .from("ssm_entity_types").select("id, title, title_my")
          // Said out loud: supabase-js defaults ascending to true
          // and postgrest-dart defaults it to false, so an order
          // with no direction means the opposite in the two halves
          // of this application.
          .order("id", { ascending: true });
        if (error) return fail("DB_ERROR", error.message, 500);
        return json({ ok: true, items: data ?? [] });
      }

      case "status": {
        if (!await isAdmin()) {
          return fail("FORBIDDEN", "Platform staff only.", 403);
        }
        const { data: session } = await admin.from("ssm_session")
          .select("provider, logged_in_as, obtained_at, last_used_at, " +
            "last_error, last_error_at").eq("id", 1).maybeSingle();
        const { count: cached } = await admin.from("ssm_search_cache")
          .select("cache_key", { count: "exact", head: true });
        const since = new Date(Date.now() - 86_400_000).toISOString();
        const { count: searches } = await admin.from("ssm_search_log")
          .select("id", { count: "exact", head: true }).gte("created_at", since);
        return json({
          ok: true,
          configured: configured(),
          // Which of the two is switched on. The console shows it
          // because every other line on that page -- the session, the
          // routes, the last error -- means something different
          // depending on the answer.
          chosen_provider: providerName(),
          // Endpoints, not credentials. On the page because the
          // defaults are a guess and "which URL did it actually ask
          // for" is the first question a failed sign-in raises -- and
          // one an operator cannot answer from the repository once
          // these are overridable.
          routes: routes(),
          session: session ?? null,
          cache_rows: cached ?? 0,
          searches_24h: searches ?? 0,
        });
      }

      case "test_login": {
        if (!await isAdmin()) {
          return fail("FORBIDDEN", "Platform staff only.", 403);
        }
        const who = await provider(admin).testLogin();
        return json({ ok: true, ...who });
      }

      case "probe": {
        if (!await isAdmin()) {
          return fail("FORBIDDEN", "Platform staff only.", 403);
        }
        // No credentials are sent; see `probeRoutes`. It does not need
        // the login to be configured either, which is the point --
        // this is what somebody reaches for when the configured path
        // is the thing that is wrong.
        const found = await probeRoutes(fetch, routes().apiRoot);
        return json({ ok: true, api_root: routes().apiRoot, ...found });
      }

      case "bar_probe": {
        if (!await isAdmin()) {
          return fail("FORBIDDEN", "Platform staff only.", 403);
        }
        // The answer to "the Bar's routes are a guess". One press from
        // somebody who can reach the site reports which parameter
        // produced rows, and that goes into `BAR_QUERY_PARAM`.
        //
        // No credentials are sent because there are none: the
        // directory is public. This is one page per candidate against
        // somebody else's server, which is why it is behind the
        // platform-admin check rather than on a user's screen.
        const hits = await probeBar(fetch, barRoutes());
        return json({ ok: true, routes: barRoutes(), hits });
      }

      case "clear_session": {
        if (!await isAdmin()) {
          return fail("FORBIDDEN", "Platform staff only.", 403);
        }
        await admin.from("ssm_session").update({
          token: null,
          obtained_at: null,
          refresh_lock_at: null,
        }).eq("id", 1);
        return json({ ok: true });
      }

      case "clear_cache": {
        if (!await isAdmin()) {
          return fail("FORBIDDEN", "Platform staff only.", 403);
        }
        await admin.from("ssm_search_cache").delete().neq("cache_key", "");
        return json({ ok: true });
      }

      case "search":
        return await search(req, admin, user.id, body);

      default:
        return fail("BAD_REQUEST", `Unknown action ${action}.`, 400);
    }
  } catch (e) {
    if (e instanceof SsmError) return fail(e.code, e.message, e.status);
    console.error("ssm-search", e);
    return fail("INTERNAL", "Something went wrong.", 500);
  }
});

/**
 * The service-role client, loosely typed on purpose.
 *
 * `createClient()`'s return carries the schema it was built for in its
 * type parameters, and `SsmSearchWeb` only ever calls `.from()` and
 * `.rpc()` on it. Naming the full generic here made `deno check` reject
 * the call — `"public"` is not assignable to `never` — while tsc, which
 * resolves the stub rather than the real package, was perfectly happy.
 * Exactly the gap `check_locally.sh` warns about in its own output.
 */
/**
 * Which register, and therefore which provider.
 *
 * `register` defaults to `ssm`, so every caller that predates Entity
 * Search (0606) goes on meaning what it meant.
 *
 * The Bar is a SCRAPER over a public directory, with the same
 * terms-of-service position `provider.ts` records about ssmsearch.com
 * and the same cache and per-minute limit for the same reason. Its
 * routes are a GUESS -- nobody has seen that site's HTML from a
 * machine that could run this -- which is why `bar_probe` exists.
 */
// deno-lint-ignore no-explicit-any
function providerFor(
  admin: any,
  register: string,
): SsmSearchWeb | SsmSearchApi | BarDirectoryWeb {
  if (register === "bar") return new BarDirectoryWeb(admin, barRoutes());
  if (register !== "ssm") {
    throw new SsmError(
      "SSM_NOT_CONFIGURED",
      `Nothing here knows how to search ${register}. Its register opens ` +
        "instead.",
      503,
    );
  }
  return provider(admin);
}

/**
 * Where to send the Bar's requests.
 *
 * Overridable for the reason `routes()` below is: the defaults are a
 * guess, and an operator who can watch their own browser's network tab
 * corrects one here and the next search uses it, with no deploy.
 */
function barRoutes(): BarRoutes {
  return {
    root: Deno.env.get("BAR_DIRECTORY_ROOT") || DEFAULT_BAR_ROUTES.root,
    searchPath: Deno.env.get("BAR_SEARCH_PATH") ||
      DEFAULT_BAR_ROUTES.searchPath,
    queryParam: Deno.env.get("BAR_QUERY_PARAM") ||
      DEFAULT_BAR_ROUTES.queryParam,
  };
}

// deno-lint-ignore no-explicit-any
function provider(admin: any): SsmSearchWeb | SsmSearchApi {
  if (chosenProvider(Deno.env.get("SSM_PROVIDER")) === "api") {
    return new SsmSearchApi(admin, apiClientFromEnv());
  }
  const email = Deno.env.get("SSMSEARCH_EMAIL");
  const password = Deno.env.get("SSMSEARCH_PASSWORD");
  if (!email || !password) {
    throw new SsmError(
      "SSM_NOT_CONFIGURED",
      "The SSM lookup is not set up yet. Set SSMSEARCH_EMAIL and " +
        "SSMSEARCH_PASSWORD in the Supabase dashboard.",
      503,
    );
  }
  return new SsmSearchWeb(admin, email, password, routes());
}

/**
 * The name the cache and the log are keyed on.
 *
 * Read from the chosen provider rather than written out, because the
 * two must never share a cache row. ssmsearch.com's answer handed back
 * as SSM's own would be the wrong kind of fact under a field the app
 * shows as verified — and the switch is a dashboard secret, so the day
 * it flips there are already rows under the other name.
 */
function providerName(): string {
  return chosenProvider(Deno.env.get("SSM_PROVIDER")) === "api"
    ? "ssm_api"
    : "ssmsearch_web";
}

/**
 * Whether the chosen provider has what it needs.
 *
 * Two providers, two pairs of secrets, and `status` must answer about
 * the one that is switched on rather than about the one this shipped
 * with.
 */
function configured(): boolean {
  return chosenProvider(Deno.env.get("SSM_PROVIDER")) === "api"
    ? Boolean(
      Deno.env.get("SSMSEARCH_API_KEY") && Deno.env.get("SSMSEARCH_API_SECRET"),
    )
    : Boolean(
      Deno.env.get("SSMSEARCH_EMAIL") && Deno.env.get("SSMSEARCH_PASSWORD"),
    );
}

/**
 * Where to send the requests.
 *
 * Overridable because the defaults are a GUESS -- see `Routes` in
 * `provider.ts`. An operator who can watch their own browser's network
 * tab can correct a path here and the next search uses it, with no
 * deploy of this repository and nobody to wait for.
 */
function routes(): Routes {
  return {
    apiRoot: Deno.env.get("SSMSEARCH_API_ROOT") || DEFAULT_ROUTES.apiRoot,
    loginPath: Deno.env.get("SSMSEARCH_LOGIN_PATH") ||
      DEFAULT_ROUTES.loginPath,
    searchPath: Deno.env.get("SSMSEARCH_SEARCH_PATH") ||
      DEFAULT_ROUTES.searchPath,
  };
}

async function search(
  _req: Request,
  // deno-lint-ignore no-explicit-any
  admin: any,
  userId: string,
  body: Record<string, unknown>,
): Promise<Response> {
  const query = String(body.query ?? "").trim();
  // Two characters finds half the register and is nobody's real search.
  if (query.length < 3) {
    return fail("QUERY_TOO_SHORT", "Type at least three characters.", 400);
  }

  const typeId = body.type_id === undefined || body.type_id === null
    ? null
    : Number(body.type_id);
  const page = Math.max(1, Number(body.page ?? 1) || 1);
  const perPage = Math.min(50, Math.max(1, Number(body.per_page ?? 20) || 20));
  // Per person and per minute. The point is not to protect this
  // function — it is that the account upstream is shared, and one
  // enthusiastic script is the whole platform's footprint.
  const limit = Number(Deno.env.get("SSM_RATE_LIMIT_PER_MIN") ?? 30);
  const minuteAgo = new Date(Date.now() - 60_000).toISOString();
  const { count } = await admin.from("ssm_search_log")
    .select("id", { count: "exact", head: true })
    .eq("searched_by", userId).gte("created_at", minuteAgo);
  if ((count ?? 0) >= limit) {
    return fail(
      "RATE_LIMITED",
      "That is a lot of searches in a minute. Try again shortly.",
      429,
    );
  }

  // Which register. Defaults to SSM so every caller that predates
  // Entity Search goes on meaning what it meant.
  const register = String(body.register ?? "ssm").trim().toLowerCase() ||
    "ssm";

  // Keyed on the provider that is switched on, so a cached answer from
  // ssmsearch.com is never served as an answer from SSM's own API --
  // and on the REGISTER, so an advocate is never handed back as a
  // company. Two registers sharing a cache row would be the worst
  // version of this: a plausible name under a field the app shows as
  // verified.
  const name = register === "ssm" ? providerName() : `${register}_web`;
  const key = [
    name,
    query.toLowerCase().replace(/\s+/g, " "),
    typeId ?? "",
    page,
    perPage,
  ].join("|");

  const { data: hit } = await admin.from("ssm_search_cache")
    .select("payload, expires_at").eq("cache_key", key).maybeSingle();
  if (hit && new Date(hit.expires_at) > new Date()) {
    await admin.from("ssm_search_log").insert({
      searched_by: userId,
      query,
      provider: name,
      cached: true,
      result_count: (hit.payload?.items ?? []).length,
    });
    return json({
      ok: true,
      provider: name,
      register,
      cached: true,
      ...hit.payload,
    });
  }

  let result;
  try {
    result = await providerFor(admin, register)
      .search(query, typeId, page, perPage);
  } catch (e) {
    await admin.from("ssm_search_log").insert({
      searched_by: userId,
      query,
      provider: name,
      cached: false,
      error_code: e instanceof SsmError ? e.code : "INTERNAL",
    });
    throw e;
  }

  const hours = Number(Deno.env.get("SSM_CACHE_TTL_HOURS") ?? 24);
  await admin.from("ssm_search_cache").upsert({
    cache_key: key,
    provider: name,
    payload: result,
    expires_at: new Date(Date.now() + hours * 3_600_000).toISOString(),
  });
  await admin.from("ssm_search_log").insert({
    searched_by: userId,
    query,
    provider: name,
    cached: false,
    result_count: result.items.length,
  });

  return json({
    ok: true,
    provider: name,
    register,
    cached: false,
    ...result,
  });
}
