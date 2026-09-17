/**
 * Which origins the functions answer, and — mostly — which they do not.
 *
 *   deno test supabase/functions/_shared/origin_test.ts
 *
 * `ALLOWED_ORIGINS` used to be an exact-match list, which was right
 * until `0327` began selling companies their own subdomain. A list of
 * exact strings cannot name a domain that does not exist yet, so on a
 * deployment with the secret set every tenant subdomain was refused:
 * the sign-in page drew with the company's own mark and then failed on
 * submit, which reads as a broken product rather than a missing
 * setting.
 *
 * So one `*` is allowed, standing for one DNS label. Almost everything
 * below is about the ways that could go wrong, because a CORS list that
 * is too generous is not a bug you notice — it is a bug somebody else
 * notices.
 *
 * No permissions are needed to run this: no network, no environment, no
 * disk. That is why `originAllowed` lives in `origin.ts` and not in
 * `cors.ts` — `cors.ts` reads `ALLOWED_ORIGINS` at module scope, so
 * importing it costs `--allow-env`, and this file failed to load at all
 * on the run that first tried it.
 */
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";

import { originAllowed } from "./origin.ts";

const APP = "https://iakauntan.com";
const TENANTS = "https://*.iakauntan.com";

Deno.test("an exact entry still matches exactly, as every existing one is", () => {
  assert(originAllowed(APP, [APP]));
  assertFalse(originAllowed("https://iakauntan.com.evil.test", [APP]));
  assertFalse(originAllowed("http://iakauntan.com", [APP]), "scheme counts");
  assertFalse(originAllowed("https://www.iakauntan.com", [APP]));
});

Deno.test("a wildcard admits one label, which is what a tenant has", () => {
  assert(originAllowed("https://sinar.iakauntan.com", [TENANTS]));
  assert(originAllowed("https://amanah-setiausaha.iakauntan.com", [TENANTS]));
});

Deno.test("and does not admit the bare domain", () => {
  // `*` stands for a label, not for nothing. The apex is its own entry
  // if it is wanted, and on this deployment it is.
  assertFalse(originAllowed(APP, [TENANTS]));
});

Deno.test("nor two labels, because the certificate only covers one", () => {
  // Cloudflare's Universal SSL and Vercel's wildcard both cover a
  // single level. Admitting `a.b.iakauntan.com` here would be admitting
  // an origin no browser can reach over TLS anyway — and would admit it
  // on a deployment where somebody had wired up a second level.
  assertFalse(originAllowed("https://a.b.iakauntan.com", [TENANTS]));
});

Deno.test("nor a name that merely ends the same way", () => {
  // The shape attackers actually try. Every one of these matches an
  // unanchored regex, and none of them is us.
  for (
    const origin of [
      "https://evil-iakauntan.com",
      "https://xiakauntan.com",
      "https://sinar.iakauntan.com.evil.test",
      "https://evil.test/https://sinar.iakauntan.com",
    ]
  ) {
    assertFalse(originAllowed(origin, [TENANTS]), origin);
  }
});

Deno.test("the dots in the pattern are dots, not any character", () => {
  // Unescaped, `.` matches anything — so `*.iakauntan.com` would admit
  // `sinar.iakauntanXcom`, which somebody can register.
  assertFalse(originAllowed("https://sinar.iakauntanXcom", [TENANTS]));
  assertFalse(originAllowed("https://sinarXiakauntan.com", [TENANTS]));
});

Deno.test("a caller that sent no Origin is not a browser and gets nothing", () => {
  assertFalse(originAllowed("", [TENANTS, APP]));
  assertFalse(originAllowed("", []));
});

Deno.test("an empty list admits nothing here", () => {
  // The `*` case never reaches this function: `corsFor` answers it
  // before asking. What this asserts is that an empty list is not
  // quietly permissive if it ever does.
  assertFalse(originAllowed(APP, []));
});

Deno.test("several entries are tried, and any one of them is enough", () => {
  const list = [APP, TENANTS, "http://localhost:3000"];
  assert(originAllowed(APP, list));
  assert(originAllowed("https://sinar.iakauntan.com", list));
  assert(originAllowed("http://localhost:3000", list));
  assertFalse(originAllowed("https://elsewhere.test", list));
});

Deno.test("a pattern is not a way to smuggle a regex in", () => {
  // `ALLOWED_ORIGINS` is set by whoever runs the deployment, so this is
  // not an injection boundary — but a pattern that silently behaved as
  // a regex would be a trap for the person setting it, who would write
  // `https://a|b.test` meaning a domain with a pipe in it.
  assertEquals(originAllowed("https://a.test", ["https://a|b.test"]), false);
  assertEquals(originAllowed("https://ab.test", ["https://a+b.test"]), false);
  assert(originAllowed("https://a+b.test", ["https://a+b.test"]));
});
