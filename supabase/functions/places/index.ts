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
 * ## Two APIs, and which one answers
 *
 * Places API (New) first, the legacy Places API behind it. They are
 * separate products on separate hosts with separate switches in the
 * Cloud console, and a key enabled for one is routinely refused by the
 * other — which is exactly what happened here: the key was live, the
 * old API was on, the new one was not, and every request came back 403
 * with an empty box and no explanation.
 *
 * So a refusal that means "this key may not use this API" — 403, 404,
 * or the new API's own quota — is retried against the old one rather
 * than shown to somebody typing an address. A 400 is not: that is a
 * request we built wrong, and asking a second API the same wrong
 * question buys a second refusal and one more billed call.
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
import {
  type Address,
  addressFromLegacy,
  addressFromNew,
  legacyRefused,
  PlacesRefusal,
  statusOf,
  type Suggestion,
  suggestionsFromLegacy,
  suggestionsFromNew,
  worthFallingBack,
} from "./parse.ts";

const AUTOCOMPLETE = "https://places.googleapis.com/v1/places:autocomplete";
const DETAILS = "https://places.googleapis.com/v1/places/";

const OLD_AUTOCOMPLETE =
  "https://maps.googleapis.com/maps/api/place/autocomplete/json";
const OLD_DETAILS = "https://maps.googleapis.com/maps/api/place/details/json";

/// When the new API last refused this key, if it has.
///
/// An isolate that has been told "no" once does not need to be told
/// again per keystroke: without this, every letter somebody types pays
/// a wasted round trip before the one that works. It is deliberately
/// only a memory of this isolate and only for a few minutes, so turning
/// the new API on in the console starts being used again on its own
/// rather than after a deploy.
let newApiRefusedAt = 0;
const REMEMBER_MS = 5 * 60 * 1000;

function newApiWorthTrying(): boolean {
  return Date.now() - newApiRefusedAt > REMEMBER_MS;
}

function rememberRefusal(): void {
  newApiRefusedAt = Date.now();
}

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
async function refusal(call: string, res: Response): Promise<PlacesRefusal> {
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
  return new PlacesRefusal(
    `places ${call} ${res.status}${said ? ` -- ${said}` : ""}`,
    res.status,
  );
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

/// What answered, so the caller and the log can say which.
type Via = "new" | "legacy";

async function suggestNew(
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
  return suggestionsFromNew(await res.json() as Record<string, unknown>);
}

async function suggestLegacy(
  key: string,
  q: string,
  country: string | null,
  session: string | null,
): Promise<Suggestion[]> {
  const url = new URL(OLD_AUTOCOMPLETE);
  url.searchParams.set("input", q);
  url.searchParams.set("key", key);
  // The old API spells the same restriction `components=country:my`.
  if (country) {
    url.searchParams.set("components", `country:${country.toLowerCase()}`);
  }
  if (session) url.searchParams.set("sessiontoken", session);

  const res = await fetch(url);
  if (!res.ok) throw await refusal("autocomplete (legacy)", res);

  const data = await res.json() as Record<string, unknown>;
  // 200 with the refusal in the body — see `legacyRefused`.
  if (legacyRefused(data.status as string | undefined)) {
    throw new PlacesRefusal(
      `places autocomplete (legacy) ${data.status}` +
        (data.error_message ? ` -- ${data.error_message}` : ""),
      null,
    );
  }
  return suggestionsFromLegacy(data);
}

async function suggest(
  key: string,
  q: string,
  country: string | null,
  session: string | null,
): Promise<{ suggestions: Suggestion[]; via: Via }> {
  if (newApiWorthTrying()) {
    try {
      const found = await suggestNew(key, q, country, session);
      return { suggestions: found, via: "new" };
    } catch (e) {
      const status = statusOf(e);
      if (status === null || !worthFallingBack(status)) throw e;
      rememberRefusal();
      console.error(
        JSON.stringify({
          event: "places",
          note: "new API refused; falling back to the legacy Places API",
          reason: `${e instanceof Error ? e.message : e}`,
        }),
      );
    }
  }
  const found = await suggestLegacy(key, q, country, session);
  return { suggestions: found, via: "legacy" };
}

async function detailsNew(
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
  return addressFromNew(await res.json() as Record<string, unknown>);
}

async function detailsLegacy(
  key: string,
  place: string,
  session: string | null,
): Promise<Address> {
  const url = new URL(OLD_DETAILS);
  url.searchParams.set("place_id", place);
  url.searchParams.set("key", key);
  url.searchParams.set("fields", "address_component,formatted_address");
  if (session) url.searchParams.set("sessiontoken", session);

  const res = await fetch(url);
  if (!res.ok) throw await refusal("details (legacy)", res);

  const data = await res.json() as Record<string, unknown>;
  if (legacyRefused(data.status as string | undefined)) {
    throw new PlacesRefusal(
      `places details (legacy) ${data.status}` +
        (data.error_message ? ` -- ${data.error_message}` : ""),
      null,
    );
  }
  return addressFromLegacy(data);
}

async function details(
  key: string,
  place: string,
  session: string | null,
): Promise<Address> {
  // A place id from one API is a place id to the other, so the fallback
  // works on the second half of a session as well as the first — which
  // matters, because the half that fills the boxes is this one.
  if (newApiWorthTrying()) {
    try {
      return await detailsNew(key, place, session);
    } catch (e) {
      const status = statusOf(e);
      if (status === null || !worthFallingBack(status)) throw e;
      rememberRefusal();
    }
  }
  return await detailsLegacy(key, place, session);
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
  const answered = await suggest(key, q, country, session);
  return json({
    suggestions: answered.suggestions,
    configured: true,
    // Which API answered. Nothing on the screen reads it; it is here so
    // that "suggestions work" and "suggestions work because the new API
    // is off and we are on the old one" are distinguishable without
    // reading the logs.
    via: answered.via,
  });
});
