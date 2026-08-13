/**
 * fetch-rates
 *
 * Brings Bank Negara Malaysia's published exchange rates into
 * `public.exchange_rates` as system rows, so a month-end revaluation is
 * not waiting on somebody to type twenty figures.
 *
 * POST {}                          -> the latest published session
 * POST { "session": "0900" }       -> a named session: 0900, 1200, 1700
 * POST { "date": "2026-08-11" }    -> a particular day, for backfilling
 *
 * Deliberately thin. It fetches, renames four fields, and hands the
 * figures to `public.ingest_exchange_rates` exactly as published — no
 * arithmetic at all. The division by `unit` (the ringgit price of a
 * *hundred* yen is not the price of one) happens in SQL, where
 * `supabase/tests/exchange_rate_feed.sql` runs it on every commit.
 * Anything computed here would be computed nowhere CI can see.
 *
 * No API key: BNM's Open API is public. The only credential involved is
 * this project's own service role key, which the platform injects, and
 * which is what lets it call an ingest that is closed to every signed-in
 * user — a rate that prices everybody's ledger is not one organization's
 * business.
 *
 * Called on a schedule. See docs/exchange-rate-feed.md.
 */
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, fail, json } from "../_shared/cors.ts";
import { isSchedulerCall } from "../_shared/scheduler.ts";

const BNM_ENDPOINT = "https://api.bnm.gov.my/public/exchange-rate";

/**
 * BNM's own versioning header. Without it the API answers 400, so this
 * is not optional politeness — it is part of the address.
 */
const BNM_HEADERS = {
  "Accept": "application/vnd.BNM.API.v1+json",
};

/** The published sessions. 1700 is the one that closes the day. */
const SESSIONS = ["0900", "1200", "1700"] as const;

/** One currency as BNM publishes it. */
interface BnmRow {
  currency_code?: string;
  unit?: number;
  rate?: {
    date?: string;
    buying_rate?: number | string;
    selling_rate?: number | string;
    middle_rate?: number | string;
  } | null;
}

/** One currency as `ingest_exchange_rates` wants it. */
interface Quote {
  currency_code: string;
  unit: number;
  rate: number;
  rate_date: string;
}

/**
 * The middle rate, which is the one to book at.
 *
 * Buying and selling are what a bank would deal at and bracket the
 * middle; using either would build the bank's spread into every foreign
 * balance on the ledger, in the same direction every month.
 */
function quoteOf(row: BnmRow): Quote | null {
  const code = row.currency_code?.trim().toUpperCase();
  const middle = row.rate?.middle_rate;
  const on = row.rate?.date;
  if (!code || middle === undefined || middle === null || !on) return null;

  const rate = typeof middle === "string" ? Number(middle) : middle;
  if (!Number.isFinite(rate)) return null;

  // `unit` is passed through rather than defaulted. If BNM stops sending
  // it, the ingest refuses the row and says so — which is the whole
  // point of doing the division down there. Defaulting to 1 here would
  // silently multiply the yen by a hundred.
  return {
    currency_code: code,
    unit: row.unit as number,
    rate,
    rate_date: on,
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") return fail("Use POST", 405);

  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const url = Deno.env.get("SUPABASE_URL");
  if (!serviceKey || !url) return fail("Function is missing its own keys", 500);

  // `verify_jwt` is not enough on its own, and the gap is easy to miss.
  // It accepts any JWT this project signed — including the publishable
  // key, which ships inside the web bundle and is therefore public. So
  // without this check anybody at all could make the project hammer
  // Bank Negara. The effect would be bounded (the same public rates,
  // upserted onto the same rows) but the door should not be open.
  //
  // The app cannot call this and should not want to: rates belong to
  // every organization at once, so fetching them is not an action any
  // one user takes. See `_shared/scheduler.ts` for what counts as proof.
  const schedulerSecret = Deno.env.get("SCHEDULER_SECRET");
  if (!isSchedulerCall(req, { secret: schedulerSecret, serviceKey })) {
    // Which of the two ways this failed, because they have completely
    // different fixes and the caller cannot see either side. "403" alone
    // sends somebody comparing a secret that was never set.
    //
    // It says whether a secret is configured, never anything about its
    // value. That reveals only whether this door is locked to somebody
    // who still cannot open it — and behind it is a public exchange
    // rate feed.
    const configured = (schedulerSecret ?? "").trim() !== "";
    return fail(
      configured
        ? "The X-Scheduler-Secret presented does not match the " +
          "SCHEDULER_SECRET set on this function."
        : "No SCHEDULER_SECRET is set on this function, so the service " +
          "role key as the bearer token is the only thing it will " +
          "accept. Set it under Edge Functions → Secrets in the " +
          "Supabase dashboard.",
      403,
    );
  }

  let body: { session?: string; date?: string } = {};
  try {
    const text = await req.text();
    if (text.trim()) body = JSON.parse(text);
  } catch {
    return fail("Body must be JSON");
  }

  const session = body.session ?? "1700";
  if (!SESSIONS.includes(session as typeof SESSIONS[number])) {
    return fail(`Session must be one of ${SESSIONS.join(", ")}`);
  }
  if (body.date && !/^\d{4}-\d{2}-\d{2}$/.test(body.date)) {
    return fail("Date must be YYYY-MM-DD");
  }

  // `quote=rm` asks for the ringgit price of a foreign unit, which is
  // the direction `exchange_rates` stores: from_currency -> to_currency,
  // base amount = foreign amount x rate.
  const query = new URLSearchParams({ session, quote: "rm" });
  const endpoint = body.date
    ? `${BNM_ENDPOINT}/date/${body.date}?${query}`
    : `${BNM_ENDPOINT}?${query}`;

  let payload: { data?: BnmRow[]; meta?: Record<string, unknown> };
  try {
    const res = await fetch(endpoint, { headers: BNM_HEADERS });
    if (!res.ok) {
      return fail(
        `Bank Negara answered ${res.status} ${res.statusText}`,
        502,
        (await res.text()).slice(0, 500),
      );
    }
    payload = await res.json();
  } catch (err) {
    // Reached rather than swallowed. A feed that is quietly not running
    // looks exactly like a feed with nothing to report, and the symptom
    // turns up a month later as a revaluation that will not post.
    return fail(`Could not reach Bank Negara: ${err}`, 502);
  }

  const rows = Array.isArray(payload.data) ? payload.data : [];
  if (rows.length === 0) {
    return fail(
      `Bank Negara published no rates for session ${session}` +
        (body.date ? ` on ${body.date}` : "") +
        ". Weekends and public holidays have none.",
      404,
      payload.meta ?? null,
    );
  }

  const quotes: Quote[] = [];
  const unreadable: string[] = [];
  for (const row of rows) {
    const q = quoteOf(row);
    if (q) quotes.push(q);
    else unreadable.push(row.currency_code ?? "(unnamed)");
  }

  const db = createClient(url, serviceKey);
  const { data, error } = await db.rpc("ingest_exchange_rates", {
    p_rows: quotes,
    p_source: "bnm",
    p_quote: "MYR",
  });
  if (error) return fail(`Could not store the rates: ${error.message}`, 500);

  const verdicts = (data ?? []) as Array<{ status: string }>;
  const count = (s: string) => verdicts.filter((v) => v.status === s).length;

  return json({
    session,
    date: body.date ?? null,
    published: rows.length,
    stored: count("stored"),
    skipped: count("skipped"),
    errors: count("error"),
    // The whole verdict, not a summary. A rate that was refused is worth
    // reading in full when somebody asks why the euro will not post.
    rates: verdicts,
    unreadable,
  });
});
