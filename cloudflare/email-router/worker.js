/**
 * The worker Cloudflare Email Routing hands each message to.
 *
 * Deployed to Cloudflare, not to Supabase, and kept here so the two
 * halves of inbound mail live in one repository:
 *
 *   1. Cloudflare Email Routing holds the MX records for the domain and
 *      runs this on every message that arrives.
 *   2. This posts the message to the `receive-email` edge function,
 *      which files it against the company that reserved the address.
 *
 * ## Deploying it
 *
 *   npx wrangler deploy            # from this directory
 *   npx wrangler secret put INBOUND_SECRET
 *   npx wrangler secret put FUNCTION_URL
 *
 * Then in the Cloudflare dashboard, under Email → Email Routing →
 * Routes, set the catch-all address to "Send to a Worker" and pick this
 * one. Nothing arrives until that is done.
 *
 * `INBOUND_SECRET` must be the same string as the edge function's.
 * `FUNCTION_URL` is https://<project>.supabase.co/functions/v1/receive-email
 *
 * ## What it does with a message it cannot deliver
 *
 * Nothing, deliberately. The function answers `stored: false` for an
 * address nobody has reserved, and this drops the message rather than
 * bouncing it: bouncing tells a sender whether an address exists, and
 * an address-existence oracle on a shared domain is how somebody finds
 * which companies are on the platform.
 */
import { parse } from "./mime.js";

export default {
  async email(message, env) {
    // The raw message, read once. `message.raw` is a stream and can
    // only be consumed a single time.
    const raw = await new Response(message.raw).text();

    const headers = message.headers;
    const body = {
      to: message.to,
      from: message.from,
      from_name: headers.get("from"),
      // The sender's own Message-ID is what makes a redelivery land
      // once. A message without one gets a stable substitute built from
      // what it does have, rather than a random id that would let the
      // same message through twice.
      message_id: headers.get("message-id") ??
        `<${message.from}-${headers.get("date") ?? ""}-${raw.length}@generated>`,
      subject: headers.get("subject"),
      ...parse(raw),
    };

    const response = await fetch(env.FUNCTION_URL, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-inbound-secret": env.INBOUND_SECRET,
      },
      body: JSON.stringify(body),
    });

    // A 5xx is worth another attempt; Cloudflare retries a message the
    // worker rejects. Anything else — including "nobody's address" —
    // is final, and retrying it only repeats the work.
    if (response.status >= 500) {
      message.setReject("Temporary failure, try again");
    }
  },
};
