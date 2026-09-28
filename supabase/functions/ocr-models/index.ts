/**
 * ocr-models
 *
 * What models the key in front of a reader can actually reach.
 *
 * POST { "provider": "openai" }
 *   -> { models: [{ id, label }], source: "pool" | "secret" }
 *
 * ## Why this function exists
 *
 * `0113` seeded `ocr_providers` with `model` null on ChatGPT and Grok,
 * and its header says why:
 *
 *   > Guessing an identifier would produce a migration that looks
 *   > finished and a 404 at the first scan, blamed on the feature
 *   > rather than on the guess.
 *
 * That reasoning holds, and nothing here invents a model either. What
 * was wrong was the other half: an operator was left to type an
 * identifier they had to already know, from a vendor that renames its
 * models every few months, into a free-text field that accepts anything
 * and only fails at the first scan — by which time a tenant has been
 * charged for it.
 *
 * Every one of these vendors publishes what the presented key can
 * reach. Asking beats both guessing and typing: the answer is current
 * by construction and scoped to the account rather than to a marketing
 * page.
 *
 * ## Holding the key is not being allowed to use it
 *
 * The caller's own JWT decides, through `am_i_platform_admin` on the
 * caller's client, before the service role is touched — the same
 * arrangement as `platform-users`, and for the same reason. The
 * platform's reader keys are a credential a tenant must never be able
 * to spend, and an endpoint that would list models for anybody signed
 * in is an endpoint that tells you whether a key is valid.
 *
 * ## The key is never returned and never logged
 *
 * It goes out in a header to the vendor and nowhere else. The response
 * carries model identifiers; `source` says WHERE the key came from —
 * the pool or the function's secret — because "no models came back" and
 * "there is no key to ask with" are different things to do next, and
 * that distinction needs no part of the key itself.
 *
 * ## Asking does not spend a scan
 *
 * `claim_ocr_key` would: it rolls a key's minute, day and month
 * counters forward in the same statement that hands the key over. That
 * is right for a scan and wrong for a catalog lookup — an operator
 * opening a dropdown would be eating a tenant's allowance. So the pool
 * is READ here with the service role, ordered the same way the claim
 * orders it, and no counter moves.
 */
import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2.117.0";
import { fail, json, serveFunction } from "../_shared/cors.ts";
import { requireEnv } from "../_shared/env.ts";
// Everything decided before a key or a vendor is touched lives in
// `catalog.ts`, which imports nothing, so `catalog_test.ts` can assert
// it on a machine that cannot reach jsr.io.
import { cannotAsk, modelQuery, modelsFrom, sorted } from "./catalog.ts";

const EVENT = "ocr-models";

interface Caller {
  userClient: SupabaseClient;
  admin: SupabaseClient;
  body: Record<string, unknown>;
}

async function callerOrThrow(req: Request): Promise<Caller | Response> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return fail("Missing Authorization header", 401);

  const url = requireEnv("SUPABASE_URL");
  const anonKey = requireEnv("SUPABASE_ANON_KEY");
  const serviceKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");

  const userClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: userData } = await userClient.auth.getUser();
  if (!userData?.user) return fail("Not authenticated", 401);

  // Asked through the CALLER's client, so their own JWT decides.
  const { data: isAdmin, error } = await userClient.rpc("am_i_platform_admin");
  if (error) return fail("Could not check your access", 403);
  if (isAdmin !== true) return fail("Platform administrators only", 403);

  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  return { userClient, admin: createClient(url, serviceKey), body };
}

/** Where the key came from, for the sentence the console shows. */
type Source = "pool" | "secret";

interface FoundKey {
  apiKey: string;
  source: Source;
}

/**
 * The platform's key for this reader, without spending anything.
 *
 * The PLATFORM's pool only — `org_id is null`. This is the platform
 * console setting the platform's catalog, and a tenant's own key is
 * theirs; listing models with it would be spending somebody else's
 * credential to answer a question they did not ask.
 *
 * Ordered `last_used_at nulls first` to match `app.claim_ocr_key`, so
 * the key this reports on is the one a scan would most likely run on.
 * `is_active` is honoured because a key stood down by hand should not
 * be presented as the platform's answer; the clock and the caps are
 * NOT, because they govern how often a key may read a document and have
 * nothing to say about reading a catalog.
 */
async function keyFor(
  admin: SupabaseClient,
  code: string,
  kind: string,
): Promise<FoundKey | null> {
  const { data, error } = await admin
    .from("ocr_provider_keys")
    .select("api_key")
    .eq("provider", code)
    .is("org_id", null)
    .eq("is_active", true)
    .order("last_used_at", { ascending: true, nullsFirst: true })
    .limit(1);
  if (error) {
    // Not fatal: the secret below may still answer, and an operator
    // cares about the outcome rather than which of two places failed.
    console.error(JSON.stringify({ event: EVENT, step: "pool", code }));
  }
  const row = Array.isArray(data) ? data[0] : null;
  const pooled = typeof row?.api_key === "string" ? row.api_key.trim() : "";
  if (pooled !== "") return { apiKey: pooled, source: "pool" };

  // `OCR_KEY_<CODE>` by convention, and the one name that predates the
  // catalog, so a platform that configured Claude before `0113` is not
  // told it has no key.
  const generic = Deno.env.get(`OCR_KEY_${code.toUpperCase()}`);
  const legacy = kind === "anthropic"
    ? Deno.env.get("OCR_ANTHROPIC_API_KEY")
    : undefined;
  const fromEnv = (generic ?? legacy ?? "").trim();
  return fromEnv === "" ? null : { apiKey: fromEnv, source: "secret" };
}

serveFunction(EVENT, async (req) => {
  if (req.method !== "POST") return fail("POST only", 405);

  const caller = await callerOrThrow(req);
  if (caller instanceof Response) return caller;
  const { userClient, admin, body } = caller;

  const code = typeof body.provider === "string" ? body.provider.trim() : "";
  if (code === "") return fail("Which reader?", 400);

  // Read with the CALLER's client: `ocr_providers` is readable by
  // anybody signed in, and using the service role for a row the caller
  // may read anyway would widen what this function needs for nothing.
  const { data: row, error } = await userClient
    .from("ocr_providers")
    .select("code, name, kind, endpoint")
    .eq("code", code)
    .maybeSingle();
  if (error) return fail("The reader catalog could not be read", 502);
  if (!row) return fail(`There is no reader called ${code}.`, 404);

  const kind = typeof row.kind === "string" ? row.kind : "";
  const name = typeof row.name === "string" ? row.name : code;

  // Said before a key is fetched, because "this kind has no catalog" is
  // true whether or not a key exists, and fetching one first would
  // report a missing key as the reason.
  const why = cannotAsk(kind);
  if (why) return fail(why, 422);

  const key = await keyFor(admin, code, kind);
  if (!key) {
    return fail(
      `There is no platform key for ${name} to ask with. Add one to its ` +
        `key pool, or set OCR_KEY_${code.toUpperCase()} on this function.`,
      409,
    );
  }

  let query;
  try {
    query = modelQuery(kind, typeof row.endpoint === "string" ? row.endpoint : "", key.apiKey);
  } catch (err) {
    // A kind the catalog grew without this function growing with it.
    return fail(err instanceof Error ? err.message : String(err), 422);
  }

  let response: Response;
  try {
    response = await fetch(query.url, { headers: query.headers });
  } catch (err) {
    // The vendor, the network, or an endpoint somebody typed wrong.
    // Named as unreachable rather than as a refusal, because those are
    // different things to check.
    console.error(JSON.stringify({
      event: EVENT,
      step: "fetch",
      code,
      // The URL, never the headers: the key is in the headers.
      url: query.url,
      message: err instanceof Error ? err.message : String(err),
    }));
    return fail(`${name} could not be reached at ${query.url}.`, 502);
  }

  const vendorBody = await response.json().catch(() => ({}));
  if (!response.ok) {
    // The vendor's own sentence where there is one: "incorrect API key
    // provided" is the whole answer, and replacing it with "the reader
    // refused" sends somebody to read logs for what they were already
    // told.
    const said = (vendorBody as { error?: { message?: string } })?.error
      ?.message;
    return fail(
      `${name} refused: ${said ?? `HTTP ${response.status}`}`,
      response.status === 401 || response.status === 403 ? 409 : 502,
    );
  }

  const models = sorted(modelsFrom(kind, vendorBody));
  // An empty list from a vendor that answered 200 is not an error, and
  // saying so is more use than an empty dropdown: a key restricted to
  // one project can legitimately see nothing.
  return json({ models, source: key.source, count: models.length });
});
