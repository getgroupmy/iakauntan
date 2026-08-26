/**
 * The worker that puts the app behind every company's own subdomain.
 *
 * ## Why this exists
 *
 * `sinar.iakauntan.com` has to answer with the app, and the app is on
 * Vercel. The obvious arrangement — a proxied wildcard CNAME straight
 * at Vercel — does not work, and fails in a way worth writing down
 * because it looks like a Cloudflare problem and is not:
 *
 *   Cloudflare opens a TLS connection to Vercel with SNI
 *   `sinar.iakauntan.com`. Vercel holds no certificate for that host,
 *   so it aborts the handshake, and the visitor gets error 525.
 *
 * Vercel will only issue a *wildcard* certificate for a domain using
 * Vercel's nameservers, because the DNS-01 challenge has to be
 * automated. Our nameservers are at Cloudflare and have to stay there:
 * Email Routing, which the `mailbox` module is built on, only works on
 * Cloudflare DNS. So no wildcard certificate is available at the
 * origin, and `Full` does not help — it skips *validating* the origin's
 * certificate, but the handshake still has to complete.
 *
 * This worker sidesteps the whole problem. It never asks Vercel for a
 * host Vercel has never heard of: it fetches the apex, which Vercel
 * does hold a certificate for, and returns that. The browser's address
 * bar still reads `sinar.iakauntan.com`, which is the only thing that
 * matters — the app resolves the company from `Uri.base.host` on the
 * client, by calling `public.workspace_by_host`.
 *
 * ## Deploying it
 *
 *   npx wrangler deploy            # from this directory
 *
 * No secrets. The route in `wrangler.toml` is what binds it to
 * `*.iakauntan.com`, and the wildcard DNS record has to be **proxied**
 * (orange cloud) or the route never fires.
 *
 * ## What it does not do
 *
 * It does not rewrite the response body. The app's assets are all
 * relative, so they resolve against whatever host asked for them, and a
 * body rewrite on every response would cost more than it bought.
 */
export default {
  async fetch(request) {
    const decision = upstream(request.url);

    if (decision === null) return fetch(request);
    if (decision.redirect) {
      return Response.redirect(decision.redirect, 308);
    }

    // `new Request(url, request)` carries the method, headers and body
    // across. The Host header and the SNI both follow the URL, which is
    // the entire point: they become the apex, which Vercel can answer.
    const forward = new Request(decision.target, request);
    // Manual, so a redirect the origin writes is one this can correct
    // rather than one it silently follows on the visitor's behalf.
    const response = await fetch(forward, { redirect: "manual" });

    // A redirect the origin writes as an absolute apex URL would walk
    // the visitor off their own subdomain and lose the company with it.
    const location = response.headers.get("location");
    if (!location) return response;

    const rewritten = rewriteLocation(location, new URL(request.url).host);
    if (rewritten === location) return response;

    const headers = new Headers(response.headers);
    headers.set("location", rewritten);
    // Status and statusText are read explicitly. Spreading a Response
    // copies none of them — they are getters on the prototype — and the
    // result is every redirect silently becoming a 200.
    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  },
};

/** The domain the app is actually served from. */
export const APEX = "iakauntan.com";

/**
 * Labels that are the platform's own rather than a company's.
 *
 * Kept identical to `ours` in `workspaceLabel`
 * (`app/lib/src/data/reserved_names_repository.dart`). The two lists
 * answer the same question on either side of the wire, and a name the
 * app refuses to look up should not be a name this one serves.
 */
export const NOT_TENANTS = new Set(["www", "app", "api", "staging", "dev"]);

/**
 * Where a request should go, from its URL alone.
 *
 * Returns `{ target }` to proxy, `{ redirect }` to send the visitor to
 * the apex, or `null` to leave the request alone.
 *
 * Pure, and separate from `fetch`, because every interesting case here
 * is a decision rather than a transfer — and because the one mistake
 * that matters is invisible in production: sending the apex through
 * itself is a loop that answers 508 after burning a subrequest budget.
 */
export function upstream(rawUrl) {
  const url = new URL(rawUrl);
  const host = url.host.split(":")[0].toLowerCase();

  // Not our domain at all. The route should never send one of these
  // here, but a worker that trusts its route is a worker that breaks
  // the day somebody widens it.
  if (host !== APEX && !host.endsWith(`.${APEX}`)) return null;

  // The apex proxying to the apex is a loop. It is excluded by the
  // route pattern too; this is the second lock on the same door.
  if (host === APEX) return null;

  const label = host.slice(0, -(APEX.length + 1));

  // A company name has exactly one label in front of the domain.
  // `a.b.iakauntan.com` is nobody's, and Universal SSL does not cover
  // it either.
  if (label.includes(".")) {
    return { redirect: `https://${APEX}${url.pathname}${url.search}` };
  }

  if (NOT_TENANTS.has(label)) {
    return { redirect: `https://${APEX}${url.pathname}${url.search}` };
  }

  return { target: `https://${APEX}${url.pathname}${url.search}` };
}

/**
 * A `Location` header, moved back onto the host the visitor is on.
 *
 * Only an absolute redirect to the apex is touched. A relative one is
 * already right, and one pointing somewhere else entirely — an OAuth
 * provider, Supabase — is somebody else's and must survive untouched.
 */
export function rewriteLocation(location, tenantHost) {
  // A relative redirect already points at the host the visitor is on.
  // Resolving it against the apex would make it absolute for no gain,
  // and every response carrying one would be rebuilt to say what it
  // already said. `//host/path` is absolute despite having no scheme.
  const absolute = /^[a-z][a-z0-9+.-]*:/i.test(location) ||
    location.startsWith("//");
  if (!absolute) return location;

  let target;
  try {
    target = new URL(location, `https://${APEX}`);
  } catch {
    return location;
  }
  if (target.host !== APEX) return location;
  target.host = tenantHost;
  return target.toString();
}
