# A company's own address on our domain

Two modules sell a name on `iakauntan.com`:

- **`workspace_address`** — `sinar.iakauntan.com`, a sign-in page with
  the company's own mark on it. `0327`.
- **`mailbox`** — `hello@iakauntan.com`, sending and receiving. `0328`.

Both are finished in this repository: schema, RLS, the request-and-
approve flow, the screens, the ingest function and the demo tenants that
show them. Neither can work until the DNS is arranged, and the DNS is
not something a migration can do.

This file is what to do about that, and the order to do it in.

---

## The decision that comes first

These two requirements are in tension:

- **Vercel issues a wildcard certificate only for a domain using
  Vercel's nameservers.** The certificate comes from a DNS-01 challenge
  Vercel has to automate, so it needs control of the zone.
- **Cloudflare Email Routing only works when the zone is on Cloudflare
  DNS.**

One zone cannot satisfy both. Pick a path before touching anything.

### Path A — nameservers at Vercel

The wildcard becomes trivial: add `*.iakauntan.com` in the Vercel
project and it provisions and renews the certificate itself.

What it costs: Cloudflare Email Routing is out. Inbound mail then needs
a provider that works from plain MX records — Resend Inbound, Postmark,
Mailgun — pointed at `receive-email` by webhook.

Nothing in the database changes. `cloudflare/email-router/worker.js` is
replaced by whatever that provider posts, and `public.receive_email`
takes delivery exactly as it does now. The worker is a hundred lines and
the parsing in it is the only part worth porting.

### Path B — nameservers stay at Cloudflare

Email Routing works as built. The wildcard is solved at the edge
instead: a **proxied** (orange-cloud) `*` CNAME to the Vercel deployment
host, with Cloudflare's Universal SSL terminating TLS. Universal SSL
covers one level of subdomain, which is exactly what a tenant gets.

Two details that catch people:

- `*.iakauntan.com` still has to be added to the Vercel project, or
  Vercel does not recognise the `Host` header and answers 404.
- Cloudflare's SSL mode has to be **Full**, not **Full (strict)** —
  Vercel holds no certificate for a host it could not validate, so
  strict origin verification fails.

**Path B is the one to take** unless there is a reason to move the zone.
It keeps the mail half exactly as built, and the wildcard is the easier
of the two problems to solve at the edge.

---

## Three things in this system that must change either way

The DNS is necessary and not sufficient. All three of these are
invisible until somebody tries to sign in at their own address.

### 1. The Supabase Auth redirect allow-list

Add `https://*.iakauntan.com/**` under **Authentication → URL
Configuration → Redirect URLs**.

Without it, GoTrue refuses the redirect and a tenant's sign-in page
draws with their own mark and then fails on submit — which reads as a
broken product rather than a missing setting. Password reset breaks the
same way: `sign_in_screen.dart` aims the link at `Uri.base.origin`, so
on a tenant subdomain the link comes back to that subdomain.

### 2. `ALLOWED_ORIGINS` on the edge functions

If the secret is set, it must name the wildcard:

```
https://iakauntan.com,https://*.iakauntan.com
```

One `*` is allowed and stands for exactly one DNS label, which is what
a tenant has. `supabase/functions/_shared/origin_test.ts` asserts what
that does and does not admit — in particular that it does not admit
`evil-iakauntan.com`, two labels, or the bare domain.

The apex needs its own entry. `*` stands for a label, not for nothing.

If the secret is unset the functions answer `*` and nothing here
applies.

### 3. Nothing needs redeploying for a new tenant

Worth saying because it is the question everyone asks. A company
reserving `sinar` is a row in `org_subdomains`; the wildcard already
resolves, the certificate already covers it, and
`public.workspace_by_host` already answers. No deploy, no DNS change, no
certificate.

---

## Inbound mail, on Path B

1. **MX records.** Cloudflare → Email → Email Routing, and let it add
   its own MX records for the zone.
2. **The worker.** From `cloudflare/email-router/`:
   ```
   npx wrangler deploy
   npx wrangler secret put INBOUND_SECRET
   npx wrangler secret put FUNCTION_URL
   ```
   `FUNCTION_URL` is
   `https://<project>.supabase.co/functions/v1/receive-email`.
3. **The catch-all.** Email Routing → Routes → catch-all address → *Send
   to a Worker* → this one. Nothing arrives until this is set.
4. **The function's side of the secret.** Supabase → Edge Functions →
   Secrets → `INBOUND_SECRET`, the same string as the worker's.

`receive-email` refuses every request when `INBOUND_SECRET` is unset,
rather than accepting them — an unset secret would otherwise mean
anybody who finds the URL can file mail as anybody.

### What a message does when it arrives

Cloudflare → worker → `receive-email` → `public.receive_email`, which is
granted to the service role and to nobody else. Mail to an address
nobody has reserved is dropped rather than stored, and a redelivery
lands once on the sender's own `Message-ID`.

Nothing bounces. A bounce tells a sender whether an address exists, and
an address-existence oracle on a shared domain is how somebody finds out
which companies are on the platform.

---

## Checking it worked

Three checks, innermost first, so a failure says which layer is wrong.

**The database.** Before any browser is involved:

```sql
select * from public.workspace_by_host('sinar.iakauntan.com');
```

A row means the reservation is approved, the module is on and the
company is trading. No row means one of those three, all visible in the
platform console under *Names on our domain*.

**The certificate.** Independent of the app:

```
curl -sI https://sinar.iakauntan.com | head -1
openssl s_client -connect sinar.iakauntan.com:443 -servername sinar.iakauntan.com </dev/null 2>/dev/null | openssl x509 -noout -subject -dates
```

A TLS error here is DNS or the certificate and nothing to do with this
repository. A 404 with valid TLS on Path B means the wildcard is not
attached to the Vercel project.

**The page.** Open it. The sign-in page should carry the company's name
and logo and say *"Sign in to continue to Sinar Teknologi"*. If it says
iAkauntan instead, the host lookup returned nothing — go back to the
first check.

Then actually sign in. That is the step that exercises the redirect
allow-list, and it is the one that fails last and loudest.

**Mail.** Send something to the reserved address and look in the Inbox
screen. If nothing arrives, the order to check is: Email Routing shows
the message, the worker's logs show the POST, the function's logs show
the call. Each stage says which of the four settings above is missing.

---

## What is deliberately not automated

The names are approved by a person. `iakauntan.com` has one of every
subdomain and one of every address, and first-come-first-served would
let a company take `support`, `billing`, `lhdn` or `ssm` — names that
read as the platform speaking, or as the agency a company on this
platform files with.

`public.reserved_names` refuses the predictable ones before an operator
sees the request. The operator is there for the rest, and
`lhdn-refunds` is the example worth remembering: no blocklist was going
to have that one.
