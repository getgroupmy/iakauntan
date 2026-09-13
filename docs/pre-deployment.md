# Before this goes live

A pass over the seven things that are worth checking before a first
deploy, what each one found, and what was done about it. Where the fix is
not in this repository — because it lives in a dashboard nobody can reach
from a commit — the exact setting is written down here rather than
described.

Verified against the hosted project `ewwcgtnniwqndrzukksm` on 16 August
2026. The numbers below were measured, not recalled; the queries that
produced them are in the sections that quote them.

---

## 1. Environment variables

**Was:** the client's two settings, `SUPABASE_URL` and
`SUPABASE_ANON_KEY`, have defaults pointing at the production project, so
a build that passed `--dart-define=SUPABASE_URL=` with an unset variable
behind it started anyway, failed every query, and looked like a network
problem. Three edge functions reached for `SUPABASE_URL` and friends with
a `!`, which hands `undefined` to `createClient` and fails several frames
later with a message about a malformed URL.

**Now:** `Env.misconfiguration()` runs before `Supabase.initialize` and
refuses to start on an empty or non-`https://` URL, with a screen that
says the build is misconfigured rather than that the server is
unreachable — the two have nothing in common as problems and one of them
cannot be fixed by reloading. `_shared/env.ts` adds `requireEnv`, which
names the missing variable in the log at the point it was wanted;
`serveFunction` turns that into a 500 with a reference. The name of the
variable stays in the log and does not reach the caller.

The defaults themselves stay. They are not secrets — the publishable key
ships in every bundle by design and RLS is what protects the data — and
removing them would break the deploy for anyone who has not yet set the
Actions secrets. The consequence to know about: **a build with no
`--dart-define` is a production build.** There is no staging-by-omission.

The optional secrets were already right and were left alone.
`send-email` names which of `RESEND_API_KEY` and `MAIL_FROM` is missing
and reports it as a 503 with the scheduler flag intact; `ocr` and
`call-token` report their features as unconfigured rather than failing
obscurely.

## 2. Debug code

Nothing to remove. No `TODO`, `FIXME`, `XXX` or `HACK` anywhere in the
repository; no test, debug or seed endpoint — the six functions are
`call-token`, `fetch-rates`, `myinvois`, `ocr`, `send-email` and
`send-push`, and every one of them is a feature. The Flutter client has
no `print` statements at all.

One thing did default the wrong way: `demoModeEnabled` was
`bool.fromEnvironment('DEMO_MODE', defaultValue: true)`, so demo sign-in
buttons appeared on any build that did not explicitly switch them off.
It is now `bool.fromEnvironment('DEMO_MODE')` — off unless a build asks
for it. CI already passes `--dart-define=DEMO_MODE=` from a repository
variable, so a demo build is still one setting away.

## 3. Error handling

**Was:** eight places returned a raw error message to the caller. Two
catch-alls did `fail((error as Error).message, 500)`; `myinvois` returned
the message of anything that escaped it — and an error thrown in that
function may be carrying a MyInvois request or response, which holds the
buyer's name, TIN, address and every invoice line. `ocr` returned the
provider's message, which for Document AI quotes the project, the
processor and sometimes the page. Three more passed a Postgres error
message straight through.

**Now:** `logFailure` puts the error type and message in the log with a
`crypto.randomUUID()` reference and returns that reference;
`failUnexpected` wraps it in a generic sentence and a 500. Every
catch-all uses one of the two, and `serveFunction` catches anything that
escapes a handler entirely, so a function cannot leak by forgetting to
try. The caller gets a sentence and a reference; the person debugging
gets the reference and the error, in the log.

What deliberately still reaches the caller: `HttpError.details` from
MyInvois — which invoice line LHDN rejected is the whole point of asking
— and the `raise exception` messages from database functions, which are
written to be read by the person who triggered them. Those are answers,
not leaks.

`ocr_scans.error` still holds the provider's real message. That is the
organization's own row behind RLS, and it is where somebody should look;
the same argument as `einvoice_logs`.

## 4. Security headers

Already present in `deploy/vercel-output-config.json` — the build output
config, not `vercel.json`, which holds only `{"git":{"deploymentEnabled":
false}}`. All four asked for were there: `X-Content-Type-Options:
nosniff`, `X-Frame-Options: DENY`, `Strict-Transport-Security: max-age=
31536000; includeSubDomains` (one year), and a CSP with `default-src
'self'`, `script-src 'self' 'wasm-unsafe-eval'`, `frame-ancestors 'none'`,
`object-src 'none'` and `base-uri 'self'`.

One header was wrong in a way that would have broken a feature rather
than exposed one: `Permissions-Policy: camera=(), microphone=(),
payment=()` switches camera and microphone off **for the app's own
origin**, and the app calls `getUserMedia` and `getDisplayMedia` for
calls and `ImageSource.camera` for receipt capture. Now
`camera=(self), microphone=(self), display-capture=(self), geolocation=(),
payment=(), usb=(), interest-cohort=()`, and `media-src 'self' blob:` was
added to the CSP for the same reason.

**Outstanding, and it will break calls:** `connect-src` lists the
Supabase host and nothing else, but `call_engine.dart` opens a WebSocket
to whatever `CALL_SFU_URL` says. When the SFU is deployed its host must
be added to `connect-src` as `wss://<host>` or every call will fail at
the CSP with no useful error. ICE to STUN/TURN is not covered by
`connect-src` and needs nothing.

`fonts.gstatic.com` in `font-src` and `connect-src` looks like dead
allowance — Plus Jakarta Sans is a bundled asset and nothing in the
source names Google Fonts — but it is load-bearing: CanvasKit fetches
Noto fallbacks from there for glyphs the bundled font does not have, and
this is an application whose customer names include Chinese and Tamil
script. Left alone deliberately.

## 5. Rate limiting

The login and password-reset paths are Supabase Auth, not application
code — the client calls GoTrue directly and there is no server of ours in
between to count attempts. So this one cannot be fixed in this
repository, and saying otherwise would be worse than saying nothing.
**Set these in the dashboard**, under Authentication → Rate Limits:

| Setting | Asked for | Platform default |
|---|---|---|
| Sign in / sign up per 5 min per IP | **25** (= 5/min) | 30 |
| Emails sent per hour | leave at 2 unless custom SMTP is on | 2 |

The password-reset requirement (3 per hour) is already met and then some
by the email limit, which is the thing a reset actually consumes.

Also on that page, and worth turning on before launch: **leaked password
protection**, which checks new passwords against HaveIBeenPwned. The
security advisor flags it as off.

The application's own token-gated endpoints — share links, signing links,
payslip access — do not need rate limiting to resist guessing.
`app.corp_new_token()` returns 244 bits from the same CSPRNG as
`gen_random_uuid`, only the SHA-256 hash is stored, and
`open_shared_document` returns a state rather than an error for an
unknown token so that guessing tells the guesser nothing.

## 6. CORS

**Was:** `Access-Control-Allow-Origin: *` on every function response.

**Now:** `corsFor(req)` reads `ALLOWED_ORIGINS` — comma separated — and
echoes the request's origin only if it is on the list, sending no
`Access-Control-Allow-Origin` at all otherwise, because a wrong origin is
worse than a missing one. `serveFunction` stamps the result onto every
response on the way out, including the ones built by `json` and `fail`,
which are called without a request all over the place.

Unset still means `*`, so the running deployment is not broken by this
commit. **To finish it**, set `ALLOWED_ORIGINS` in Edge Functions →
Secrets to the app's own origin, e.g. `https://app.iakauntan.com`. Only
browsers are affected — the scheduled workflows and the mobile app send
no `Origin` and enforce nothing — so it is safe to turn on without
deploying anything else.

## 7. Database security

Nothing to fix. The figures below were re-measured on 2 September 2026,
against a schema that has roughly doubled since they were first taken —
177 tables then, 306 now; 290 SECURITY DEFINER functions then, 796 now.
Every claim still holds. **Two of them hold because CI asserts them**,
and that distinction is marked, because a number somebody measured once
is worth less than a number a test defends.

- **TLS.** `select ssl, version, cipher from pg_stat_ssl` on the session
  reporting connection: TLS 1.3, `TLS_AES_256_GCM_SHA384`. Supabase does
  not expose a non-TLS port. *Measured once; nothing guards it.*
- **No default credentials.** The only login role with superuser
  capability is `supabase_admin`, which is the platform's own.
  *Measured once; nothing guards it.*
- **RLS everywhere.** All **306** tables in `public` carry it — none
  without. **Asserted** by `supabase/tests/table_grants.sql`, which
  fails naming the offending table, so a new table without a policy
  cannot reach production quietly. The behavioural check still stands as
  it was taken: as `anon` with no JWT, `organizations`, `gl_lines`,
  `payslips`, `profiles` and `employees` all return 0 rows.
- **`search_path` pinned.** All **796** SECURITY DEFINER functions in
  `public` and `app` set it — none without — which is what stops a
  caller shadowing `round()` in `pg_temp` and running their own code
  with the definer's rights. **Asserted** by
  `supabase/tests/search_path.sql` across all **1,223** functions in
  those schemas, extension members excluded by `pg_depend`.

The advisor's warnings, re-counted, and why they stand:

- **609 × `authenticated_security_definer_function_executable`** (was
  203). This is the architecture. Every posting routine is a SECURITY
  DEFINER function with an `app.can_*` guard inside it; that is how
  permission is enforced at all. The count grows with the product and
  says nothing on its own.
- **15 × `anon_security_definer_function_executable`** (was 3, and the
  old note that all three were token-gated is no longer the whole
  answer). **Ten are token-gated**, each reachable only with a 244-bit
  token: `corp_open_signing_link`, `corp_sign_with_link`,
  `corp_decline_with_link`, `open_shared_document`,
  `shared_payment_options`, `open_shared_ticket`,
  `reply_to_shared_ticket`, `public_pos_menu`,
  `public_pos_menu_modifiers` and `place_public_pos_order`.

  **Five are not, and each is deliberate**, with the reasoning already
  written down elsewhere — named here so a reader of this checklist does
  not have to rediscover it:

  | function | why it answers an unauthenticated caller |
  |---|---|
  | `landing_page()` | the marketing page's own content |
  | `site_pages()` | the same |
  | `workspace_by_host(host)` | the sign-in page must resolve a hostname before anybody is signed in — `docs/custom-domains.md` |
  | `report_failed_sign_in(email)` | records a refused attempt; built to be safe against an anonymous caller — `docs/security.md` |
  | `may_sign_in_here(host, email)` | tells a company's own door that an address is not on that team. **It is an enumeration oracle and is one on purpose**: migration `0347` sets out the trade-off at length, and the sign-in screen's own comment names it. Listed here because a checklist that says "all token-gated" would be false. |

- **3 × `extension_in_public`** (was 2): `citext`, `pg_trgm`, and now
  `btree_gist`. Moving them is the advisor's fix and it is the wrong
  call here: `citext` is a column type, every function in this schema
  pins `search_path`, and relocating the extension would change operator
  resolution under all of them. No privilege is gained by the move.
- **4 × `rls_enabled_no_policy`** (was 2): `einvoice_credentials`,
  `org_ocr_credentials`, and now `idempotency_keys` and
  `org_payment_gateways`. That is the design — RLS on with no policy
  means nobody but the service role reaches the table, which is what a
  credential store, a gateway secret and a replay-guard ledger all want.

## Still needing somebody with a password

Nothing below can be done from a commit.

1. **Authentication → Rate Limits**: sign-in to 25 per 5 minutes; turn on
   leaked password protection.
2. **Edge Functions → Secrets**: set `ALLOWED_ORIGINS` to the app's
   origin.
3. **`deploy/vercel-output-config.json`**: add the SFU's `wss://` host to
   `connect-src` when the SFU is deployed. Calls will not work until this
   is done.
4. **Rotate anything that was ever committed.** See the warning in
   `README.md`.
5. **Take one live payment through a tenant's own acquirer.** Everything
   either side of the HTTP is asserted and no ringgit has ever been
   through it. `docs/first-payment.md` is the runbook.
6. **Turn passkeys on for the project.** The web code is built and the
   console switch ships off, because GoTrue answers `passkey_disabled`
   until somebody sets the relying party ID in the dashboard.
   `docs/passkeys.md` is the runbook. Web only: the phone half is not
   shipped, and the last section of that runbook says why — the obvious
   plugin takes the web build down with it — and what a second attempt
   has to do first.
