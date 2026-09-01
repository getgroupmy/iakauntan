// Cross-origin rules, and what a failure is allowed to say.

import { originAllowed } from "./origin.ts";


/// Origins the browser may call these functions from.
///
/// Unset means `*`, which is where this started and what the running
/// deployment relies on. Set `ALLOWED_ORIGINS` — comma separated — to
/// narrow it to the app's own domains; anything not on the list gets no
/// `Access-Control-Allow-Origin` header at all and the browser refuses
/// the response.
///
/// An entry may carry one `*`, which stands for exactly one DNS label:
/// `https://*.iakauntan.com` admits `https://sinar.iakauntan.com` and
/// nothing else. That exists because `0327` sells a company its own
/// subdomain, and a list of exact strings cannot name a domain that
/// does not exist yet — set on a deployment with tenant subdomains, the
/// exact-match version refused every one of them and the company saw
/// its own sign-in page fail on submit.
///
/// Only browsers are affected. The scheduled workflows and the mobile
/// app send no `Origin` and enforce nothing, so tightening this cannot
/// break them — which is why it is safe to turn on without a deploy of
/// anything else.
const ALLOWED = (Deno.env.get("ALLOWED_ORIGINS") ?? "")
  .split(",")
  .map((o) => o.trim())
  .filter((o) => o.length > 0);

export function corsFor(req?: Request): Record<string, string> {
  const base: Record<string, string> = {
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type, x-scheduler-secret",
    "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
    "Vary": "Origin",
  };

  if (ALLOWED.length === 0) {
    return { ...base, "Access-Control-Allow-Origin": "*" };
  }

  const origin = req?.headers.get("Origin") ?? "";
  // No header rather than a wrong one: echoing an origin that is not on
  // the list is the mistake this check exists to avoid.
  if (originAllowed(origin, ALLOWED)) {
    return { ...base, "Access-Control-Allow-Origin": origin };
  }
  return base;
}

/// Kept for the call sites that have no request to hand.
export const corsHeaders = corsFor();

export function json(body: unknown, status = 200, req?: Request): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsFor(req), "Content-Type": "application/json" },
  });
}

/// A failure the caller is meant to read and act on: which invoice line
/// LHDN rejected, which attachment is missing. `extra` is deliberate,
/// caller-facing detail — not an error object.
export function fail(message: string, status = 400, extra?: unknown): Response {
  return json({ error: message, details: extra ?? null }, status);
}

/// The entry point every function uses.
///
/// It does the three things each of them was doing separately, and one
/// they were not: answers the preflight, catches whatever escapes the
/// handler, and — the new part — stamps the origin-aware CORS headers
/// onto every response on the way out. That last one matters because
/// `json` and `fail` are called without a request all over the place; if
/// `ALLOWED_ORIGINS` is set, only the response that goes through here
/// knows which origin asked.
export function serveFunction(
  event: string,
  handler: (req: Request) => Response | Promise<Response>,
): void {
  Deno.serve(async (req: Request) => {
    let res: Response;
    if (req.method === "OPTIONS") {
      res = new Response("ok");
    } else {
      try {
        res = await handler(req);
      } catch (err) {
        res = failUnexpected(err, event, req);
      }
    }
    const headers = new Headers(res.headers);
    for (const [k, v] of Object.entries(corsFor(req))) headers.set(k, v);
    return new Response(res.body, {
      status: res.status,
      statusText: res.statusText,
      headers,
    });
  });
}

/// Put a failure in the log and hand back the reference that names it.
///
/// The error type and its message, never the error object: whatever
/// threw it may be carrying a request body, a provider URL or somebody's
/// invoice on it, and logs are read by people who have no business
/// seeing a particular company's data.
/// The context is whatever a JSON log line can hold: a boolean answers
/// "was a key configured" more honestly than the string "yes", and
/// narrowing this to strings only pushed that conversion onto every
/// caller, where it was forgotten once already.
export function logFailure(
  err: unknown,
  event: string,
  context?: Record<string, string | number | boolean>,
): string {
  const ref = crypto.randomUUID();
  console.error(
    JSON.stringify({
      event,
      ref,
      ...context,
      kind: err instanceof Error ? err.name : typeof err,
      message: err instanceof Error ? err.message : String(err),
    }),
  );
  return ref;
}

/// A failure nobody planned for.
///
/// The client gets a generic sentence and a reference; the reference and
/// the real error go to the log, where the person debugging can find
/// them. An unexpected error carries whatever the thing that threw it
/// was holding — a Postgres message naming a column or a constraint, a
/// URL, a fragment of somebody's invoice — and none of that belongs in
/// a response body.
export function failUnexpected(
  err: unknown,
  event: string,
  req?: Request,
  context?: Record<string, string>,
): Response {
  const ref = logFailure(err, event, context);
  return json(
    {
      error: "Something went wrong at our end. Quote this reference if you " +
        "get in touch.",
      ref,
    },
    500,
    req,
  );
}
