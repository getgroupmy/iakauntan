/**
 * ssm-api
 *
 * The OFFICIAL SSM Search API (CIDP v1.0.1), all thirteen endpoints, on
 * one entry point selected by `action`. The key and the secret stay
 * here: they are edge-function secrets, they are never in this
 * repository, never in the database, and never in a response the app
 * can read.
 *
 * POST { "action": "<name>", "params": { … }, "org_id": "<uuid>" }
 *   -> { ok: true,  action, cached, client_ref_no, data }
 *   -> { ok: false, action, error: { kind, message, code, status, path,
 *                                    client_ref_no } }
 *
 * `params.force: true` bypasses the cache. Production calls are CHARGED
 * per call against a points balance, so the cache and the per-minute
 * limit are part of not spending somebody's money twice for the same
 * answer, not optimisations to tune away.
 *
 * ---------------------------------------------------------------------
 * Who is asking, and why that is not the service role
 *
 * This function holds the service-role key, because `ssm_api_log` and
 * `ssm_search_cache` are service-role only — nothing a tenant may read.
 * So it builds TWO clients: the service-role one for those tables, and
 * a caller-scoped one carrying the request's own `Authorization`
 * header.
 *
 * Membership is read through the CALLER's client, and that is the whole
 * check. The bundle this came from read `org_members` through the
 * service role, which is RLS-free: a forged `org_id` would have been
 * answered by the row it named. Read through the caller, a forged one
 * returns nothing. `status = 'active'` is asked as well, because an
 * invitation that was never accepted, and a membership that was
 * revoked, are both rows on that table. `_shared/context.ts` asks the
 * same question the same way.
 *
 * ---------------------------------------------------------------------
 * Secrets, none of which are in the repository or the database
 *
 *   SSMSEARCH_API_KEY       the platform's CIDP key
 *   SSMSEARCH_API_SECRET    its secret
 *   SSMSEARCH_API_BASE_URL  https://cidp.ssmsearch.com/ (dev, free) or
 *                           https://apigw.ssmsearch.com/gateway/CIDP/V1.1/
 *                           (production, charged)
 *
 * Set in the Supabase dashboard, like `SSMSEARCH_EMAIL`, `OCR_KEY_*`
 * and `RESEND_API_KEY`. Until SSM issues the key every call answers
 * `SSM_NOT_CONFIGURED`, which the app shows as "not set up yet" rather
 * than as a failure somebody should retry.
 *
 * Optional: SSM_API_RATE_LIMIT_PER_MIN (30), SSM_CACHE_TTL_SEARCH_SEC
 * (86400), SSM_CACHE_TTL_PROFILE_SEC (604800).
 *
 * ---------------------------------------------------------------------
 * The profile endpoints return personal data
 *
 * Directors', shareholders' and secretaries' identity numbers, dates of
 * birth and home addresses. The cache holds the raw payload for its
 * TTL, so `SSM_CACHE_TTL_PROFILE_SEC` is a retention setting and not a
 * performance one. It is separately settable from the search TTL for
 * that reason alone.
 */
import { createClient } from "jsr:@supabase/supabase-js@2";
import { serveFunction } from "../_shared/cors.ts";
import {
  normalizeSearchResults,
  SsmApiError,
  type SsmCallOptions,
  SsmSearchClient,
  type SsmRequestInfo,
} from "../_shared/ssm-search-client.ts";

const RATE_LIMIT_PER_MIN = Number(
  Deno.env.get("SSM_API_RATE_LIMIT_PER_MIN") ?? 30,
);
const TTL_SEARCH = Number(Deno.env.get("SSM_CACHE_TTL_SEARCH_SEC") ?? 86_400);
const TTL_PROFILE = Number(
  Deno.env.get("SSM_CACHE_TTL_PROFILE_SEC") ?? 604_800,
);

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/**
 * A refusal this function decided on, as opposed to one SSM returned.
 *
 * `kind` is the same vocabulary `SsmApiError` uses, so the Dart side
 * switches on one set of names rather than two.
 */
class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly kind = "validation",
  ) {
    super(message);
    this.name = "HttpError";
  }
}

// ---------------------------------------------------------------------
// The action table. Every documented endpoint is reachable, plus the
// three the search flow actually uses.
// ---------------------------------------------------------------------
type Params = Record<string, unknown>;
type ActionCtx = {
  client: SsmSearchClient;
  params: Params;
  call: SsmCallOptions;
};
type ActionDef = { ttl: number; run: (ctx: ActionCtx) => Promise<unknown> };

function str(p: Params, k: string, required = true): string {
  const v = p[k];
  if (v === undefined || v === null || v === "") {
    if (required) throw new HttpError(400, `params.${k} is required`);
    return "";
  }
  return String(v).trim();
}

function optStr(p: Params, k: string): string | undefined {
  return str(p, k, false) || undefined;
}

/**
 * A search needs something to search FOR.
 *
 * Both `name` and `regNo` are optional on the wire, so a body with
 * neither is a request for the whole register — which upstream answers
 * as a charged call returning nothing useful.
 */
function requireSomethingToSearchFor(
  body: { name?: string; regNo?: string },
): void {
  if (!body.name && !body.regNo) {
    throw new HttpError(400, "params.name or params.regNo is required");
  }
}

export const ACTIONS: Record<string, ActionDef> = {
  // ---- what the search flow uses -------------------------------------
  search: {
    ttl: TTL_SEARCH,
    run: async ({ client, params, call }) => {
      const body = {
        name: optStr(params, "name"),
        regNo: optStr(params, "regNo"),
        entityType: optStr(params, "entityType"),
        page: optStr(params, "page") ?? "1",
      };
      requireSomethingToSearchFor(body);
      const raw = await client.searchEntity(body, call);
      return {
        hits: normalizeSearchResults(raw),
        currentPage: raw.searchEntity?.currentPage ?? body.page,
        nextPage: raw.searchEntity?.nextPage ?? "",
        raw,
      };
    },
  },
  searchAll: {
    ttl: TTL_SEARCH,
    run: async ({ client, params, call }) => {
      const body = {
        name: optStr(params, "name"),
        regNo: optStr(params, "regNo"),
        entityType: optStr(params, "entityType"),
      };
      requireSomethingToSearchFor(body);
      // Every page is a charged call in production, so the ceiling is
      // low and is a ceiling rather than a suggestion.
      const maxPages = Math.min(
        Math.max(Number(params.maxPages ?? 3) || 3, 1),
        10,
      );
      return await client.searchAll(body, { ...call, maxPages });
    },
  },
  profile: {
    ttl: TTL_PROFILE,
    run: ({ client, params, call }) =>
      client.profileFor(
        str(params, "entityType"),
        {
          newRegNo: optStr(params, "newRegNo"),
          oldRegNo: optStr(params, "oldRegNo"),
        },
        call,
      ),
  },

  // ---- the thirteen, one for one -------------------------------------
  searchEntity: {
    ttl: TTL_SEARCH,
    run: ({ client, params, call }) =>
      client.searchEntity({
        name: optStr(params, "name"),
        regNo: optStr(params, "regNo"),
        entityType: optStr(params, "entityType"),
        page: optStr(params, "page"),
      }, call),
  },
  businessProfile: {
    ttl: TTL_PROFILE,
    run: ({ client, params, call }) =>
      client.businessProfile({ regNo: str(params, "regNo") }, call),
  },
  companyProfile: {
    ttl: TTL_PROFILE,
    run: ({ client, params, call }) =>
      client.companyProfile({ regNo: str(params, "regNo") }, call),
  },
  directorsOfficers: {
    ttl: TTL_PROFILE,
    run: ({ client, params, call }) =>
      client.directorsOfficers({ regNo: str(params, "regNo") }, call),
  },
  shareCapital: {
    ttl: TTL_PROFILE,
    run: ({ client, params, call }) =>
      client.shareCapital({ regNo: str(params, "regNo") }, call),
  },
  shareholders: {
    ttl: TTL_PROFILE,
    run: ({ client, params, call }) =>
      client.shareholders({ regNo: str(params, "regNo") }, call),
  },
  registeredAddressChanges: {
    ttl: TTL_PROFILE,
    run: ({ client, params, call }) =>
      client.registeredAddressChanges({ regNo: str(params, "regNo") }, call),
  },
  companySecretary: {
    ttl: TTL_PROFILE,
    run: ({ client, params, call }) =>
      client.companySecretary({ regNo: str(params, "regNo") }, call),
  },
  companyCharges: {
    ttl: TTL_PROFILE,
    run: ({ client, params, call }) =>
      client.companyCharges({ regNo: str(params, "regNo") }, call),
  },
  auditFirmProfile: {
    ttl: TTL_PROFILE,
    run: ({ client, params, call }) =>
      client.auditFirmProfile({ adtFirmNo: str(params, "adtFirmNo") }, call),
  },
  llpCurrentProfile: {
    ttl: TTL_PROFILE,
    run: ({ client, params, call }) =>
      client.llpCurrentProfile(
        { entityNoOldFormat: str(params, "entityNoOldFormat") },
        call,
      ),
  },
  imageView: {
    ttl: TTL_PROFILE,
    run: ({ client, params, call }) =>
      client.imageView({ regNo: str(params, "regNo") }, call),
  },
  image: {
    ttl: TTL_PROFILE,
    run: ({ client, params, call }) =>
      client.image(
        { regNo: str(params, "regNo"), verId: str(params, "verId") },
        call,
      ),
  },
};

/**
 * The names this function answers to.
 *
 * Exported so a test can assert the thirteen endpoints are all still
 * reachable. A method on the client that no action reaches is an
 * endpoint the app cannot call, and nothing else in the repository
 * would notice.
 */
export const ACTION_NAMES = Object.keys(ACTIONS);

function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`${name} is not set`);
  return v;
}

serveFunction("ssm-api", async (req: Request): Promise<Response> => {
  if (req.method !== "POST") {
    return json({
      ok: false,
      error: { kind: "validation", message: "POST only" },
    }, 405);
  }

  const url = env("SUPABASE_URL");
  const admin = createClient(url, env("SUPABASE_SERVICE_ROLE_KEY"));
  let action = "";

  try {
    const auth = req.headers.get("Authorization");
    if (!auth) throw new HttpError(401, "Sign in first.", "unauthorized");

    // The caller's own client. What it can see is what RLS lets THEM
    // see, which is the whole reason it exists.
    const userClient = createClient(url, env("SUPABASE_ANON_KEY"), {
      global: { headers: { Authorization: auth } },
    });
    const { data: userData } = await userClient.auth.getUser();
    const user = userData?.user;
    if (!user) throw new HttpError(401, "Sign in first.", "unauthorized");

    const body = (await req.json().catch(() => ({}))) as {
      action?: string;
      params?: Params;
      org_id?: string;
    };
    action = String(body.action ?? "");
    const def = ACTIONS[action];
    if (!def) {
      throw new HttpError(
        400,
        `Unknown action "${action}". One of: ${ACTION_NAMES.join(", ")}.`,
      );
    }
    const params: Params = body.params && typeof body.params === "object"
      ? body.params
      : {};

    const orgId = await resolveOrgId(userClient, user.id, body.org_id);
    await enforceRateLimit(admin, orgId);

    const force = params.force === true;
    const baseUrl = Deno.env.get("SSMSEARCH_API_BASE_URL") ?? "";
    const cacheKey = await cacheKeyFor(action, params, baseUrl);
    if (!force && def.ttl > 0) {
      const hit = await cacheGet(admin, cacheKey);
      if (hit !== null) {
        return json({
          ok: true,
          action,
          cached: true,
          client_ref_no: null,
          data: hit,
        });
      }
    }

    // The reference SSM echoes back. Prefixed with the organization so
    // a charged call on somebody's bill can be traced to the company
    // that asked for it.
    const clientRefNo = `${orgId}:${crypto.randomUUID()}`;
    const client = buildClient((info) =>
      logRequest(admin, {
        ...info,
        orgId,
        userId: user.id,
        action,
      })
    );
    const data = await def.run({ client, params, call: { clientRefNo } });

    if (def.ttl > 0) {
      await cachePut(admin, cacheKey, action, params, data, client.baseUrl, def.ttl);
    }
    return json({
      ok: true,
      action,
      cached: false,
      client_ref_no: clientRefNo,
      data,
    });
  } catch (e) {
    return errorResponse(e, action);
  }
});

/**
 * The client, or a refusal that says the secrets are not set.
 *
 * Not "something went wrong": until SSM approves the subscription there
 * is no key, and a screen that says "try again" about a thing nobody
 * can try again is worse than one that says who to ask.
 */
function buildClient(
  onRequest: (info: SsmRequestInfo) => void | Promise<void>,
): SsmSearchClient {
  const key = Deno.env.get("SSMSEARCH_API_KEY");
  const secret = Deno.env.get("SSMSEARCH_API_SECRET");
  if (!key || !secret) {
    throw new HttpError(
      503,
      "The SSM Search API is not set up yet. A platform administrator " +
        "sets SSMSEARCH_API_KEY and SSMSEARCH_API_SECRET.",
      "auth",
    );
  }
  return SsmSearchClient.fromEnv(Deno.env, { onRequest });
}

function errorResponse(e: unknown, action: string): Response {
  if (e instanceof HttpError) {
    return json({
      ok: false,
      action,
      error: { kind: e.kind, message: e.message, status: e.status },
    }, e.status);
  }
  if (e instanceof SsmApiError) {
    return json({ ok: false, action, error: ssmErrorBody(e) }, ssmStatus(e));
  }
  console.error("ssm-api", e);
  return json({
    ok: false,
    action,
    error: { kind: "internal", message: "Something went wrong." },
  }, 500);
}

/**
 * What a caller is told about an upstream failure.
 *
 * A 401 from SSM is OUR credential being wrong, not the caller's, so it
 * is never forwarded as a 401 — that would send the app to the sign-in
 * screen over a secret nobody signed in with. It becomes a 503 and says
 * who can fix it.
 */
export function ssmStatus(e: SsmApiError): number {
  if (e.kind === "auth") return 503;
  if (e.kind === "network") return 504;
  return 502;
}

export function ssmErrorBody(e: SsmApiError): Record<string, unknown> {
  return {
    kind: e.kind,
    message: e.kind === "auth"
      ? "The SSM Search API refused our key. A platform administrator " +
        "can check SSMSEARCH_API_KEY and SSMSEARCH_API_SECRET."
      : e.message,
    code: e.code,
    status: e.status,
    path: e.path,
    client_ref_no: e.clientRefNo,
  };
}

/**
 * Which organization is asking, read through the caller's own client.
 *
 * The membership row is the check. Asked through the service role it
 * would not be one: the service role sees every row, so a body naming
 * somebody else's organization would be answered by that
 * organization's row. `status = 'active'` is asked as well, because an
 * unaccepted invitation and a revoked membership are both rows here.
 */
async function resolveOrgId(
  // deno-lint-ignore no-explicit-any
  userClient: any,
  userId: string,
  requested?: string,
): Promise<string> {
  if (!requested) {
    throw new HttpError(400, "org_id is required.");
  }
  const { data } = await userClient
    .from("org_members")
    .select("status")
    .eq("org_id", requested)
    .eq("user_id", userId)
    .maybeSingle();
  if (!data || data.status !== "active") {
    throw new HttpError(
      403,
      "You are not a member of this company.",
      "forbidden",
    );
  }
  return requested;
}

/**
 * Per organization and per minute.
 *
 * The point is not to protect this function. Production calls are
 * charged against a points balance the whole platform shares, so one
 * enthusiastic loop is everybody's bill.
 */
async function enforceRateLimit(
  // deno-lint-ignore no-explicit-any
  admin: any,
  orgId: string,
): Promise<void> {
  if (RATE_LIMIT_PER_MIN <= 0) return;
  const since = new Date(Date.now() - 60_000).toISOString();
  const { count, error } = await admin
    .from("ssm_api_log")
    .select("id", { count: "exact", head: true })
    .eq("org_id", orgId)
    .gte("created_at", since);
  // A log that cannot be read is not a reason to let the calls through
  // unmetered: the balance is real money and the limit is what protects
  // it. Refused, and the refusal says what happened.
  if (error) {
    throw new HttpError(
      503,
      "The SSM lookup could not check its own rate limit.",
      "internal",
    );
  }
  if ((count ?? 0) >= RATE_LIMIT_PER_MIN) {
    throw new HttpError(
      429,
      `That is more than ${RATE_LIMIT_PER_MIN} SSM lookups in a minute for ` +
        "this company. Try again shortly.",
      "rate_limited",
    );
  }
}

async function logRequest(
  // deno-lint-ignore no-explicit-any
  admin: any,
  info: SsmRequestInfo & {
    orgId: string;
    userId: string;
    action: string;
  },
): Promise<void> {
  const { error } = await admin.from("ssm_api_log").insert({
    org_id: info.orgId,
    // `searched_by`, not `user_id`. A `user_id` beside an `org_id` is
    // read by `a_colleague_not_a_stranger.sql` as work HANDED to
    // somebody and wants a trigger checking they belong; nobody is
    // handed anything here. `0589` made the same call for
    // `ssm_search_log`.
    searched_by: info.userId,
    action: info.action,
    path: info.path,
    client_ref_no: info.clientRefNo,
    request_ref_no: info.requestRefNo,
    status: info.status,
    ok: info.ok,
    error_kind: info.errorKind,
    duration_ms: info.durationMs,
    base_url: info.baseUrl,
  });
  if (error) console.warn("ssm_api_log insert failed", error.message);
}

/**
 * The cache key.
 *
 * The base URL is part of it on purpose: the development host serves
 * fixture data for free and production serves the register for money,
 * and an answer from one must never be handed back as an answer from
 * the other.
 */
export async function cacheKeyFor(
  action: string,
  params: Params,
  baseUrl: string,
): Promise<string> {
  const { force: _force, ...rest } = params;
  const canon = JSON.stringify({ action, baseUrl, params: sortKeys(rest) })
    .toLowerCase();
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(canon),
  );
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Key order is not meaning. `{name, page}` and `{page, name}` are one
 * search, and hashing them apart would pay for the same answer twice.
 */
export function sortKeys(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v && typeof v === "object") {
    return Object.fromEntries(
      Object.keys(v as object).sort().map((
        k,
      ) => [k, sortKeys((v as Record<string, unknown>)[k])]),
    );
  }
  return typeof v === "string" ? v.trim() : v;
}

// deno-lint-ignore no-explicit-any
async function cacheGet(admin: any, key: string): Promise<unknown | null> {
  const { data, error } = await admin
    .from("ssm_search_cache")
    .select("payload")
    .eq("cache_key", key)
    .gt("expires_at", new Date().toISOString())
    .maybeSingle();
  if (error || !data) return null;
  return data.payload ?? null;
}

async function cachePut(
  // deno-lint-ignore no-explicit-any
  admin: any,
  key: string,
  action: string,
  params: Params,
  payload: unknown,
  baseUrl: string,
  ttlSec: number,
): Promise<void> {
  const { force: _force, ...rest } = params;
  const { error } = await admin.from("ssm_search_cache").upsert({
    cache_key: key,
    provider: "ssm_api",
    action,
    params: rest,
    payload,
    base_url: baseUrl,
    expires_at: new Date(Date.now() + ttlSec * 1000).toISOString(),
  });
  if (error) console.warn("ssm_search_cache upsert failed", error.message);
}
