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
4. Platform console → SSM lookup → **Test login**. That is the real
   check; everything before it is arrangement.

Optional: `SSM_CACHE_TTL_HOURS` (24) and `SSM_RATE_LIMIT_PER_MIN` (30).

Until the secrets are set, every search answers `SSM_NOT_CONFIGURED`
and the app says it is not set up yet — not that it failed.

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
live credentials. **Test login** on the admin page is the first real
check. When it fails, ssmsearch.com's own words are shown and kept in
`ssm_session.last_error`, because a refusal only they understand is one
only their message can explain.
