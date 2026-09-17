/**
 * What the workspace proxy does with a URL.
 *
 * These run with no permission flags, like the other assertions in the
 * `edge` job: `worker.js` reads no environment, opens no socket and
 * touches no disk at module scope, and if that ever stops being true
 * this is where it will be noticed.
 *
 * The failures worth catching here are all quiet ones. A worker that
 * proxies the apex to itself answers 508 after exhausting its
 * subrequest budget; a worker that treats `www` as a company shows a
 * sign-in page for a company that does not exist; a worker that
 * rewrites every `Location` breaks the OAuth round trip and nothing
 * else. None of the three announces itself.
 */
import { assertEquals } from "jsr:@std/assert@1";
import { APEX, NOT_TENANTS, rewriteLocation, upstream } from "./worker.js";

Deno.test("a company's subdomain is proxied to the apex", () => {
  assertEquals(
    upstream("https://sinar.iakauntan.com/"),
    { target: "https://iakauntan.com/" },
  );
});

Deno.test("the path and query survive the trip", () => {
  assertEquals(
    upstream("https://sinar.iakauntan.com/assets/main.dart.js?v=3"),
    { target: "https://iakauntan.com/assets/main.dart.js?v=3" },
  );
});

Deno.test("the apex is left alone, because proxying it is a loop", () => {
  assertEquals(upstream("https://iakauntan.com/"), null);
  assertEquals(upstream("https://iakauntan.com/anything"), null);
});

Deno.test("a host that is not ours is left alone", () => {
  assertEquals(upstream("https://example.com/"), null);
  // The one that matters: a domain that merely ends in our name.
  assertEquals(upstream("https://evil-iakauntan.com/"), null);
  assertEquals(upstream("https://iakauntan.com.evil.test/"), null);
});

Deno.test("the platform's own labels go to the apex", () => {
  for (const label of NOT_TENANTS) {
    assertEquals(
      upstream(`https://${label}.iakauntan.com/x`),
      { redirect: "https://iakauntan.com/x" },
      label,
    );
  }
});

Deno.test("two labels deep is nobody's, and has no certificate either", () => {
  assertEquals(
    upstream("https://a.b.iakauntan.com/"),
    { redirect: "https://iakauntan.com/" },
  );
});

Deno.test("the host is read case-insensitively and without its port", () => {
  assertEquals(
    upstream("https://SINAR.IAKAUNTAN.COM:443/"),
    { target: "https://iakauntan.com/" },
  );
});

Deno.test("a redirect to the apex comes back to the company's host", () => {
  assertEquals(
    rewriteLocation("https://iakauntan.com/#/login", "sinar.iakauntan.com"),
    "https://sinar.iakauntan.com/#/login",
  );
});

Deno.test("a relative redirect is already right", () => {
  assertEquals(rewriteLocation("/#/login", "sinar.iakauntan.com"), "/#/login");
  assertEquals(rewriteLocation("dashboard", "sinar.iakauntan.com"), "dashboard");
});

Deno.test("a scheme-relative redirect is absolute, and is moved", () => {
  assertEquals(
    rewriteLocation("//iakauntan.com/#/login", "sinar.iakauntan.com"),
    "https://sinar.iakauntan.com/#/login",
  );
});

Deno.test("a redirect somewhere else is somebody else's", () => {
  const supabase = "https://ewwcgtnniwqndrzukksm.supabase.co/auth/v1/authorize";
  assertEquals(rewriteLocation(supabase, "sinar.iakauntan.com"), supabase);
  assertEquals(
    rewriteLocation("https://accounts.google.com/o/oauth2/auth", "s.iakauntan.com"),
    "https://accounts.google.com/o/oauth2/auth",
  );
});

Deno.test("the apex this proxies to is the domain the app is served from", () => {
  assertEquals(APEX, "iakauntan.com");
});
