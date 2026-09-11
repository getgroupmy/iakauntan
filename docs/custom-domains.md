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
instead: a **proxied** (orange-cloud) `*` CNAME, with Cloudflare's
Universal SSL terminating TLS. Universal SSL covers one level of
subdomain, which is exactly what a tenant gets.

That handles the browser's half of the connection. It does not handle
the origin's. Pointing the proxied wildcard straight at Vercel fails
with **error 525**: Cloudflare offers SNI `sinar.iakauntan.com`, Vercel
holds no certificate for it, and the handshake never completes. Vercel
issues a wildcard certificate only through a DNS-01 challenge it
automates itself, which needs its own nameservers — the very thing this
path declines to give it.

So the origin's half is handled by a worker,
`cloudflare/workspace-proxy/`, which fetches the apex — a host Vercel
can answer for — and returns it under the company's own address. Step 6
has the detail.

**Path B is the one to take** unless there is a reason to move the zone.
It keeps the mail half exactly as built, and the worker is thirty lines
of decision beside a hundred of mail parsing that already live here.

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

### 6. The workspace proxy

**An earlier draft of this step was wrong**, and wrong in a way that
costs an evening, so the correction is written out rather than quietly
replaced.

It said to add `*.iakauntan.com` in Vercel, ignore the *Invalid
Configuration* warning as cosmetic, and set Cloudflare's SSL mode to
**Full**. Doing exactly that produces:

> **SSL handshake failed — Error code 525.** Browser ✓, Cloudflare ✓,
> Host ✗.

Cloudflare opens a TLS connection to Vercel with SNI
`sinar.iakauntan.com`. Vercel holds no certificate for that host and
aborts the handshake. *Invalid Configuration* is not cosmetic: it is
Vercel saying it cannot issue a certificate. It issues a **wildcard**
certificate only through a DNS-01 challenge it automates itself, which
needs Vercel's nameservers — and on Path B ours are at Cloudflare and
have to stay there. `Full` does not rescue it either: `Full` skips
*validating* the origin's certificate, but the handshake still has to
complete.

So the wildcard is served by a worker instead, from
`cloudflare/workspace-proxy/`:

```
npx wrangler deploy            # from that directory
```

It has no secrets. `wrangler.toml` carries the route
(`*.iakauntan.com/*`), which is what binds it to every company's
subdomain and — because of the leading `*.` — not to the apex.

**CI does this now**, on every push to the default branch: the `worker`
job in `.github/workflows/ci.yml`. It needs one repository secret,
`CLOUDFLARE_API_TOKEN` — a token with **Edit Cloudflare Workers** on
this zone, from dash.cloudflare.com → My Profile → API Tokens, added
under Settings → Secrets and variables → Actions. Without it the job
warns on the run summary and deploys nothing, rather than going red.

The command above is still the way to do it the first time, or from a
laptop when CI is not the fastest route to a fix. Both upload the same
script to the same route; neither is authoritative over the other.

The job then asks `ci-probe.iakauntan.com` for a page and expects a 200.
That is not a check of *which* page — no company holds that name, so the
app draws the one that says so — it is a check that TLS completed and
something served. It is the assertion this arrangement went without for
its whole first outing, during which every subdomain answered 525 and
nothing said so.

The worker never asks Vercel for a host Vercel has never heard of. It
fetches the apex, which Vercel does hold a certificate for, and returns
that. The address bar still reads `sinar.iakauntan.com`, which is all
the app needs: it resolves the company client-side from `Uri.base.host`.

Two things that still have to be true:

- The `*` DNS record from step 5 must be **proxied** (orange cloud). A
  worker route over a grey-clouded record never fires.
- Cloudflare → **SSL/TLS → Overview** → **Full**. The worker's own
  subrequest goes to the apex over TLS regardless, but the zone-wide
  setting should not be *Flexible*.

`*.iakauntan.com` in the Vercel project is now unnecessary. Leaving it
there is harmless; it will read *Invalid Configuration* forever.

`cloudflare/workspace-proxy/route_test.ts` asserts what the worker does
with a URL, and runs in CI's `edge` job.

#### If you want one name working before deploying anything

An explicit record beats the wildcard, so a single subdomain can be
taken straight to Vercel with no worker involved:

1. Cloudflare → DNS → `CNAME`, name `sinar`, target
   `cname.vercel-dns.com`, **DNS only (grey cloud)**.
2. Vercel → **Settings → Domains** → add `sinar.iakauntan.com` — the
   exact host, not the wildcard. Vercel validates it over HTTP-01 and
   issues a real certificate, usually within a minute.

Grey cloud means the browser reaches Vercel directly, so there is no
origin leg to fail. This does not scale — it is a step per company —
but it proves the app half without waiting on anything else.

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

### 7a. The three kinds of name

`0344`. **Platform console → Names on our domain** asks whose a name is
before it asks anything else:

| Kind | Company | What answers on it |
|---|---|---|
| A company's | required | their sign-in page, gated on their holding `workspace_address` |
| Ours → Reserved | none | nothing; the visitor gets 7b's page |
| Ours → Admin use | none | the app on our own mark, confined to the module or screen chosen |

**Admin use** is the one worth reading twice. It exists so an address we
run ourselves — a counter tablet on `pos`, a kitchen screen on `kds` —
does not have to be given to some company to work at all, which is a
real arrangement expressed as a fake customer. It needs nobody to have
bought `workspace_address`, because there is nobody to have bought it.

It is **not** an authorisation, and the name invites that reading. An
admin address answers to anyone who types it, exactly as
`iakauntan.com` does; what arrives is the ordinary sign-in page, and who
may then read what is decided where it always was — by the session, by
RLS. The confinement is which screens draw, not which rows are legible.
Making one staff-only would be a rule in the router after sign-in, not a
setting on the name.

#### `mail`, and a name the platform could not use

`reserved_names` holds `mail` with the reason *the mail service*, so no
company can take it. Until `0562` nothing could **use** it either: every
path that set a name went through one check, the platform's own
included, so pointing `mail` at the mail service came back *"That name
is reserved: the mail service."* The list was holding the name against
the use it was held for.

`0562` splits that check. The **shape** — three to sixty-three
characters, letters digits and hyphens, no punycode prefix — applies to
everybody. The **blocklist** applies where the name is about to be a
company's. So the platform can hold `mail`; a company still cannot get
it, either by asking or by being handed it afterwards, and that second
path is closed in the same migration that opens the first.

`mail` is pointed at the `mailbox` module by the migration, as **Admin
use**, with no screen named — so it confines to every screen that module
grows rather than freezing on today's one. Nothing to do here unless you
want it elsewhere, in which case release it in the console. A deployment
that already held `mail` is left alone.

Two things still have to be true for it to open: the wildcard record
from step 5 covers it (it does, like every other label), and the
signing-in account's company must hold the `mailbox` module —
`workspace_module_refusal` turns away one that does not, with a sentence
rather than a screen.

### 7b. A name that is nobody's

Every label under the wildcard resolves, so `nosuchcompany.iakauntan.com`
reaches the app exactly as an approved name does. `0331` gives that
visitor a page that says so, rather than the platform's own front page —
which reads as "the address is fine, the company is not here", the
opposite of what happened.

The copy is edited in **Platform console → Names on our domain**, under
*When the name is nobody's*. Every box may be left empty; empty means
"use the wording the product ships with", so clearing a field restores
the default rather than producing a blank page. The button's address may
be left empty too, and then it goes to the bare domain.

It is stored on `landing_page` with the rest of the front-door copy, and
travels in the payload's `brand` object rather than its `page` — `page`
is gated on publication, and somebody standing at a door that does not
open needs an answer whether or not a marketing site has been written.

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
