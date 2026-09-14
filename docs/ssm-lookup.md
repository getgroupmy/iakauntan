# Looking a company up at SSM

Type a name, pick the right entity, and the contact's name and
registration number become what the registry says rather than what
somebody read off a letterhead.

That is the whole point. `contacts.registration_no` is what MyInvois
validates a party against, and one transposed digit is a submission
LHDN rejects — or worse, accepts against another company. A number
confirmed by the register is a different kind of fact from a number
typed off a printed invoice, and `contacts.ssm_verified_at` is what
lets you tell them apart.

## Read this first

The reader in use signs in to **ssmsearch.com** the way its own website
does and calls its search endpoint from a server.

**Their terms of service prohibit that.** They forbid reaching the
service "on another website or server … through … any other
technological means", and forbid sharing login credentials. This runs
while the official SSM Corporate API is being arranged. It is a
deliberate, temporary choice, and it is written here rather than only in
a README so that the person who has to decide whether to keep it can
find it.

Two consequences that are not negotiable while it is in use:

* **The cache and the rate limit are not optimisations.** A company
  looked up by six people in a morning reaches ssmsearch.com once, and
  one person can make thirty searches a minute and no more. Those two
  are the difference between a modest footprint and a conspicuous one.
* **Keep the volume modest.** This is not a bulk-verification tool and
  must not be turned into one.

## Switching it on

1. Create an ssmsearch.com account.
2. In the Supabase dashboard, **Edge Functions → Secrets**, set
   `SSMSEARCH_EMAIL` and `SSMSEARCH_PASSWORD`. Never in this
   repository, never in the database, never in a payload the app can
   read — the same rule as `OCR_KEY_*` and `RESEND_API_KEY`.
3. Deploy: the function ships with every push, so this is only the
   secrets.
4. Platform console → **SSM register** (`/admin/ssm`) → **Test the
   login**. That is the real check; everything before it is
   arrangement.

Optional: `SSM_CACHE_TTL_HOURS` (24) and `SSM_RATE_LIMIT_PER_MIN` (30).

Until the secrets are set, every search answers `SSM_NOT_CONFIGURED`
and the app says it is not set up yet — not that it failed.

## The endpoints are a guess, and the first sign-in said so

The login and search paths were read off the package this feature
arrived in, not off a live browser. The first real **Test the login**
answered:

```
Sign-in failed (there was no session yet):
Page not found: /api/user/login
```

Read that carefully — it is good news twice. The message is
ssmsearch.com's own words, so `/api` routes and answers: the root is
right. And `/user/login` is simply not one of their routes.

So each piece is an optional secret, and correcting one is a **secret
change rather than a release**:

| Secret | Default |
| --- | --- |
| `SSMSEARCH_API_ROOT` | `https://ssmsearch.com/api` |
| `SSMSEARCH_LOGIN_PATH` | `/user/login` |
| `SSMSEARCH_SEARCH_PATH` | `/company/search` |

They are endpoints, not credentials — there is nothing secret about a
URL — but they live beside the login because that is where this
function's configuration is, and one place beats two. The console page
shows the URLs currently in use, because once they are overridable the
repository can no longer answer "which URL did it ask for".

### Finding the real ones

Nobody can do this from CI or from a server; it takes a browser signed
in to ssmsearch.com.

1. Open ssmsearch.com, then the browser's developer tools, **Network**
   tab, and tick **Fetch/XHR**.
2. Sign in. The request that carries the email and password is the
   login call — its **Request URL** is the path to set, minus the
   `https://ssmsearch.com/api` root.
3. Search for a company. The request that carries the query is the
   search call; same again.
4. While you are there, note what the login **response** contains — the
   provider expects a `token` field and reads `email` for display. If
   theirs is `access_token`, or the token is set as a cookie rather
   than returned, that is a code change and not a secret, so say so.

## How the login stays alive

The function keeps the bearer token in `public.ssm_session`, which is
service-role only. Every search uses it; when ssmsearch.com rejects it,
the function signs in again and retries the search **once**. A second
refusal after a fresh login is that account being refused, and asking a
third time is just asking again.

`ssm_session_try_lock()` stops two function instances signing in at the
same moment. That is not a performance guard: ssmsearch.com is **one
shared account**, so a second login can invalidate the first one's
token, which is a loop rather than a race. The lock expires after
thirty seconds rather than being released, so an instance that dies
holding it blocks the next sign-in for seconds and not for ever.

If you sign in to ssmsearch.com in a browser and that invalidates the
server's token, nothing breaks — the next search signs in again.

## What is stored on a contact

A confirmed lookup writes, through `set_contact_ssm_entity`:

| Column | What |
| --- | --- |
| `name` | overwritten — the registry is the authority |
| `registration_no` | overwritten, for the same reason |
| `old_registration_no` | filled when the registry returns one; an older number already recorded is kept otherwise |
| `id_value` / `id_type` | filled as `BRN` **only when empty** — a TIN somebody entered deliberately is not ours to replace |
| `ssm_entity_type` | Company, Business, Audit Firm or LLP |
| `ssm_slug` | the registry's own handle, so a later lookup goes straight back |
| `ssm_verified_at` | when the register last confirmed it |

Deliberately **not** added: `ssm_name`, `ssm_reg_no`, `ssm_reg_no_old`.
This schema already has `name`, `registration_no` and
`old_registration_no`, and a second copy of the same fact is two columns
with nothing to say which one a report should believe.

## Where it turns up in the app

Three places, and each of them is a moment where somebody is about to
commit a registration number to a record that an e-Invoice will be
validated against:

* **The contact editor**, under the name — *Check the SSM register*.
  Seeded with the registration number if one is typed, and with the
  name otherwise, because the register matches a number exactly and a
  name only approximately. What comes back fills the name, both
  registration numbers and the legal name, and seeds `id_value` only
  when it is empty.

  Saving is what records the check. If the name or the number is edited
  by hand **after** the lookup, nothing is stamped: the form no longer
  says what the register said, and `ssm_verified_at` would then be
  recording a verification that did not happen.

* **The scanned-bill supplier dialog** — the review screen that stands
  between a reading and a new contact. The same button, seeded from the
  reading and, failing that, from the raw text the reader returned;
  that last case is the one somebody hits when a scan produced no
  supplier details at all and the form opened empty. A supplier created
  from a confirmed match is stamped after it exists.

  If the stamp fails the supplier is still created and the screen says
  so. Reporting "could not create the supplier" about a supplier that
  had just been created is how somebody ends up with two.

* **The platform console**, for the operator: is it configured, is
  there a live session, what went wrong last, how much is it being
  used — and four buttons. There is deliberately **no credential form**:
  the login is a dashboard secret, and a box on that page would put a
  working third-party login in the database.

## Only the free search

Name, new and old registration numbers, and entity type. Status,
address and directors are paid documents on their side and are not
fetched.

## When the Corporate API arrives

Nothing in the app changes. `provider.ts` has one class and one
contract — a query in, entities out. A second class implementing the
same two methods, chosen by `SSM_PROVIDER`, is the whole change.

It is deliberately not stubbed: a class that type-checks and does
nothing is one somebody switches on by accident.

Worth asking Infomina for: an **entity name search** endpoint (their
public catalogue lists per-document lookups by registration number
only), its price per call, rate limits, and the OpenAPI spec — their
developer portal renders with RapiDoc, so one exists.

## What nobody has tested

The login call and its response mapping were derived from
ssmsearch.com's own frontend and verified against a mock, not against
live credentials. **Test the login** on the console page was the first
real check, and it found the paths wrong — see "The endpoints are a
guess" above. The response MAPPING is still unverified: nobody has seen
a successful login body. When it fails, ssmsearch.com's own words are shown and kept in
`ssm_session.last_error`, because a refusal only they understand is one
only their message can explain.
