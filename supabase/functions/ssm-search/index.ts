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
 * `status`, `test_login`, `clear_session`, `clear_cache`.
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
import { createClient } from "jsr:@supabase/supabase-js@2";
import { SsmError, SsmSearchWeb } from "./provider.ts";

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, content-type",
  "access-control-allow-methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "content-type": "application/json" },
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

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
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
          configured: Boolean(
            Deno.env.get("SSMSEARCH_EMAIL") && Deno.env.get("SSMSEARCH_PASSWORD"),
          ),
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

function provider(admin: ReturnType<typeof createClient>): SsmSearchWeb {
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
  return new SsmSearchWeb(admin, email, password);
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

  const key = [
    "ssmsearch_web",
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
      provider: "ssmsearch_web",
      cached: true,
      result_count: (hit.payload?.items ?? []).length,
    });
    return json({ ok: true, provider: "ssmsearch_web", cached: true, ...hit.payload });
  }

  let result;
  try {
    result = await provider(admin).search(query, typeId, page, perPage);
  } catch (e) {
    await admin.from("ssm_search_log").insert({
      searched_by: userId,
      query,
      provider: "ssmsearch_web",
      cached: false,
      error_code: e instanceof SsmError ? e.code : "INTERNAL",
    });
    throw e;
  }

  const hours = Number(Deno.env.get("SSM_CACHE_TTL_HOURS") ?? 24);
  await admin.from("ssm_search_cache").upsert({
    cache_key: key,
    provider: "ssmsearch_web",
    payload: result,
    expires_at: new Date(Date.now() + hours * 3_600_000).toISOString(),
  });
  await admin.from("ssm_search_log").insert({
    searched_by: userId,
    query,
    provider: "ssmsearch_web",
    cached: false,
    result_count: result.items.length,
  });

  return json({ ok: true, provider: "ssmsearch_web", cached: false, ...result });
}
