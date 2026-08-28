/**
 * places
 *
 * Address suggestions, and the address behind one, from Google Places.
 *
 * POST { "q": "jalan ampang", "country": "MY", "session": "<uuid>" }
 *   -> { "suggestions": [{ "id": "...", "line": "...", "detail": "..." }] }
 *
 * POST { "place": "<id>", "session": "<uuid>" }
 *   -> { "address": { line1, city, postcode, state, country, formatted } }
 *
 * ## Why this exists rather than a key in the bundle
 *
 * Google's own guidance is that a browser key is public and restricted
 * by HTTP referrer. That is true and it is not enough here: a referrer
 * restriction is a header anybody can send, the bill for a leaked
 * Places key lands on us, and this project's rule — set for the LHDN
 * credentials and every provider key since — is that a key we pay for
 * does not travel to a browser. So the key lives in this function's
 * environment, the client sends a query, and what comes back is an
 * address.
 *
 * It costs one hop. What it buys is that rotating the key is a secret
 * change rather than a deploy of the app, and that a scraped bundle
 * cannot spend our quota.
 *
 * ## Sessions
 *
 * Places bills autocomplete by session: the keystrokes leading to one
 * chosen address are one billable unit if they carry the same session
 * token, and one unit *each* if they do not. The client makes a token
 * per address it is filling in and sends it with every call including
 * the final details fetch, which is what closes the session.
 *
 * ## Authorization
 *
 * Signed in, and nothing more. This is the company-setup screen, which
 * somebody reaches before they have an organization at all — there is
 * no org to be a member of yet. What it protects is the quota, and a
 * session is enough for that.
 */
import { createClient } from "jsr:@supabase/supabase-js@2";
import { fail, json, serveFunction } from "../_shared/cors.ts";
import { requireEnv } from "../_shared/env.ts";

const AUTOCOMPLETE = "https://places.googleapis.com/v1/places:autocomplete";
const DETAILS = "https://places.googleapis.com/v1/places/";

/// Google's own words for why it said no.
///
/// A status on its own is not a diagnosis. `403` from this API means
/// any of four different things -- Places API (New) not enabled on the
/// project, an HTTP-referrer restriction on a key called from a server
/// that sends no referrer, an API restriction that omits this API, or
/// billing not enabled -- and Google names which one in the body. The
/// first version of this function logged the number and threw the
/// sentence away, so the only way to tell those four apart was to go
/// and look in the Cloud console. It is in the log now.
///
/// The body carries no credential: the key travels in a header and
/// Google does not echo it back.
async function refusal(call: string, res: Response): Promise<Error> {
  const body = await res.text().catch(() => "");
  let said = body.slice(0, 500);
  try {
    const parsed = JSON.parse(body) as {
      error?: { message?: string; status?: string };
    };
    const e = parsed.error ?? {};
    if (e.status || e.message) {
      said = [e.status, e.message].filter(Boolean).join(": ");
    }
  } catch { /* not JSON; the raw body is what there is */ }
  return new Error(`places ${call} ${res.status}${said ? ` -- ${said}` : ""}`);
}

/// One suggestion, as the screen wants it: a line to show in bold and a
/// line under it. Google's own split, not one we compute.
interface Suggestion {
  id: string;
  line: string;
  detail: string;
}

/// The pieces the company form has boxes for.
///
/// Google returns a list of components with types; this picks the ones
/// the form asks for and drops the rest. A `null` is a component Google
/// did not return, which is common and not an error — plenty of
/// addresses have no postcode.
interface Address {
  line1: string | null;
  city: string | null;
  postcode: string | null;
  state: string | null;
  country: string | null;
  formatted: string | null;
}

/// Who is asking. Signed in is the whole requirement; see the note above.
async function requireCaller(req: Request): Promise<void> {
  const auth = req.headers.get("Authorization");
  if (!auth) throw new Response(null, { status: 401 });

  const client = createClient(
    requireEnv("SUPABASE_URL"),
    requireEnv("SUPABASE_ANON_KEY"),
    { global: { headers: { Authorization: auth } } },
  );
  const { data, error } = await client.auth.getUser();
  if (error || !data.user) throw new Response(null, { status: 401 });
}

function component(
  components: Array<Record<string, unknown>>,
  type: string,
): string | null {
  for (const c of components) {
    const types = (c.types ?? []) as string[];
    if (types.includes(type)) {
      return (c.longText ?? c.shortText ?? null) as string | null;
    }
  }
  return null;
}

/// Google's components, in the shape the form fills from.
///
/// `line1` is the street address: the number and the road, joined,
/// because those are two components and one box. Everything else is one
/// component each.
function toAddress(place: Record<string, unknown>): Address {
  const components =
    (place.addressComponents ?? []) as Array<Record<string, unknown>>;

  const number = component(components, "street_number");
  const route = component(components, "route");
  const line1 = [number, route].filter((p) => p).join(" ") || null;

  return {
    line1,
    // `locality` is the town or city; `postal_town` is what the UK and
    // a few others use instead, and an address with neither falls back
    // to the administrative area below it rather than to nothing.
    city: component(components, "locality") ??
      component(components, "postal_town") ??
      component(components, "administrative_area_level_2"),
    postcode: component(components, "postal_code"),
    state: component(components, "administrative_area_level_1"),
    country: component(components, "country"),
    formatted: (place.formattedAddress ?? null) as string | null,
  };
}

async function suggest(
  key: string,
  q: string,
  country: string | null,
  session: string | null,
): Promise<Suggestion[]> {
  const body: Record<string, unknown> = { input: q };
  // The country the operator chose, so somebody setting up a Malaysian
  // company is not offered a street in Ohio. Omitted when unknown
  // rather than guessed.
  if (country) body.includedRegionCodes = [country.toLowerCase()];
  if (session) body.sessionToken = session;

  const res = await fetch(AUTOCOMPLETE, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": key,
      "X-Goog-FieldMask":
        "suggestions.placePrediction.placeId," +
        "suggestions.placePrediction.structuredFormat",
    },
    body: JSON.stringify(body),
  });

  if (!res.ok) throw await refusal("autocomplete", res);
  const data = await res.json() as Record<string, unknown>;
  const raw = (data.suggestions ?? []) as Array<Record<string, unknown>>;

  const out: Suggestion[] = [];
  for (const s of raw) {
    const p = s.placePrediction as Record<string, unknown> | undefined;
    if (!p) continue;
    const f = (p.structuredFormat ?? {}) as Record<string, unknown>;
    const main = (f.mainText ?? {}) as Record<string, unknown>;
    const secondary = (f.secondaryText ?? {}) as Record<string, unknown>;
    out.push({
      id: String(p.placeId ?? ""),
      line: String(main.text ?? ""),
      detail: String(secondary.text ?? ""),
    });
  }
  return out.filter((s) => s.id.length > 0);
}

async function details(
  key: string,
  place: string,
  session: string | null,
): Promise<Address> {
  const url = new URL(DETAILS + encodeURIComponent(place));
  if (session) url.searchParams.set("sessionToken", session);

  const res = await fetch(url, {
    headers: {
      "X-Goog-Api-Key": key,
      "X-Goog-FieldMask": "addressComponents,formattedAddress",
    },
  });

  if (!res.ok) throw await refusal("details", res);
  return toAddress(await res.json() as Record<string, unknown>);
}

serveFunction("places", async (req) => {
  if (req.method !== "POST") return fail("POST only", 405);

  try {
    await requireCaller(req);
  } catch (res) {
    if (res instanceof Response) return fail("Sign in first", 401);
    throw res;
  }

  const key = Deno.env.get("GOOGLE_PLACES_KEY");
  // Not configured is not broken. The form has typed address boxes and
  // they keep working; suggestions are the part that is missing, and
  // saying so plainly beats a 500 that looks like an outage.
  if (!key) return json({ suggestions: [], configured: false });

  const body = await req.json().catch(() => ({})) as Record<string, unknown>;
  const session = typeof body.session === "string" ? body.session : null;

  if (typeof body.place === "string" && body.place.length > 0) {
    return json({ address: await details(key, body.place, session) });
  }

  const q = typeof body.q === "string" ? body.q.trim() : "";
  // Two characters is where a suggestion starts being a suggestion
  // rather than the whole index, and every call is billed.
  if (q.length < 3) return json({ suggestions: [], configured: true });

  const country = typeof body.country === "string" ? body.country : null;
  return json({
    suggestions: await suggest(key, q, country, session),
    configured: true,
  });
});
