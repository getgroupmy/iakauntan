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

## The runbook

Ten steps, in this order. The order is deliberate: everything that can
be done safely in advance is done first, so that when DNS goes live the
thing either works or fails for one reason rather than three.

Nothing before step 5 changes what any visitor sees. Steps 1–4 are
inert until a subdomain resolves.

Identifiers you will need:

| Thing | Value |
|---|---|
| Supabase project ref | `ewwcgtnniwqndrzukksm` |
| Vercel project | `prj_ACEwE16VnLeesABU7sAkPhzdn2Ti` |
| Vercel team | `team_EBG91tunYkCckYh5bCELGRU3` |

### 1. Decide the path

Read *The decision that comes first* above and pick. Everything below
assumes **Path B** — nameservers stay at Cloudflare — because it keeps
inbound mail exactly as built. If you take Path A, steps 5 and 6 are
replaced by adding the wildcard in Vercel, and steps 7–9 by whichever
inbound provider you choose.

Do not start step 5 until this is settled. Moving nameservers after
wiring Email Routing means unpicking both.

### 2. The Supabase redirect allow-list

Supabase → **Authentication → URL Configuration → Redirect URLs**, add:

```
https://*.iakauntan.com/**
```

Leave the existing entries alone. This is additive and inert until a
subdomain exists.

*Why now:* without it a tenant's sign-in page draws correctly and then
fails on submit, and that failure looks like the app rather than like a
setting.

### 3. `ALLOWED_ORIGINS`

Supabase → **Edge Functions → Secrets**. If `ALLOWED_ORIGINS` is *not*
set, skip this step — the functions answer `*` and nothing needs doing.

If it is set, it must name both:

```
https://iakauntan.com,https://*.iakauntan.com
```

The apex needs its own entry. `*` stands for a label, not for nothing,
so `https://*.iakauntan.com` alone would lock out the main site.

### 4. Check nothing is broken yet

Load `https://iakauntan.com`, sign in, and open a screen that calls an
edge function — Settings will do. Steps 2 and 3 cannot break anything,
but finding that out now is cheaper than finding it out after the DNS
has changed.

### 5. The wildcard record, in Cloudflare

Cloudflare → the `iakauntan.com` zone → **DNS → Records → Add record**:

| Field | Value |
|---|---|
| Type | `CNAME` |
| Name | `*` |
| Target | the CNAME target Vercel gives for a **subdomain** |
| Proxy status | **Proxied** (orange cloud) |

The apex cannot be copied here. `iakauntan.com` is an **A** record to
Vercel's anycast addresses (`64.29.17.65`, `216.198.79.65`), and a CNAME
cannot point at an address. Take the target from Vercel instead —
**Settings → Domains**, the value it shows for a subdomain, normally
`cname.vercel-dns.com`.

Explicit records still win over the wildcard, so any subdomain already
in the zone keeps behaving as it does. The apex's own grey cloud can
stay as it is; the proxy setting is per record, and only the wildcard
needs it — that is what makes Cloudflare terminate TLS for
`<name>.iakauntan.com`.

### 6. Vercel and Cloudflare SSL

Two settings, both needed:

- Vercel → the project → **Settings → Domains** → add
  `*.iakauntan.com`. Vercel will mark it *Invalid Configuration* because
  it expects its own DNS records. On Path B that is cosmetic — the
  domain has to be there or Vercel does not recognise the `Host` header
  and answers 404.
- Cloudflare → **SSL/TLS → Overview** → mode **Full**. Not *Full
  (strict)*: Vercel holds no certificate for a host it could not
  validate, so strict origin verification fails.

### 7. A name to test with

In the app, as a platform operator:

1. Switch the `workspace_address` module on for one company —
   **Platform console → Organizations**.
2. As that company, **Settings → Your names on our domain**, ask for a
   name.
3. Back in **Platform console → Names on our domain**, approve it.

Then, before opening a browser:

```sql
select * from public.workspace_by_host('<name>.iakauntan.com');
```

A row means the database half is right. No row means the module is off,
the request is not approved, or the company is not active — all three
visible in the console.

### 8. Open it

`https://<name>.iakauntan.com` should show that company's name and logo
and say *"Sign in to continue to <company>"*.

If TLS fails, it is step 5 or 6 and nothing to do with this repository.
If it loads but says iAkauntan, the host lookup returned nothing — go
back to step 7's query.

**Then actually sign in.** That is the step that exercises the redirect
allow-list from step 2, and it fails last and loudest.

### 9. Inbound mail

Only after steps 5–8 are working, so a mail problem is a mail problem.

1. Cloudflare → **Email → Email Routing**, and let it add its own MX
   records.
2. From `cloudflare/email-router/`:
   ```
   npx wrangler deploy
   npx wrangler secret put INBOUND_SECRET
   npx wrangler secret put FUNCTION_URL
   ```
   `FUNCTION_URL` is
   `https://ewwcgtnniwqndrzukksm.supabase.co/functions/v1/receive-email`.
   Generate the secret with `openssl rand -hex 32` and keep it to hand
   for the next step.
3. Email Routing → **Routes** → catch-all → *Send to a Worker* → this
   one. Nothing arrives until this is set.
4. Supabase → **Edge Functions → Secrets** → `INBOUND_SECRET`, the same
   string.

### 10. Send it a message

Switch the `mailbox` module on for the test company, ask for an address,
approve it, and send something to it from an ordinary mail client. It
should appear in **Inbox** within a few seconds.

If it does not, check in this order — each stage names which of step 9's
four settings is missing:

1. Email Routing's activity log shows the message arriving.
2. `npx wrangler tail` shows the worker POSTing.
3. Supabase → Edge Functions → `receive-email` → Logs shows the call.

A 401 in the third means the two halves of `INBOUND_SECRET` do not
match. A 503 means it is unset on the Supabase side.

---

## Three things in this system that must change either way

Steps 2, 3 and a fact worth knowing, explained rather than listed. The
DNS is necessary and not sufficient. All three of these are
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

Steps 7, 8 and 10, in more detail than the runbook gives them. Three
checks, innermost first, so a failure says which layer is wrong.

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
