# The edge functions, and how they get deployed

Some things in this system are neither in the database nor in the app,
because they talk to somebody else — or because they hold a secret that
must reach neither:

| Function | Talks to | Called by |
| --- | --- | --- |
| `myinvois` | LHDN MyInvois | the app, when a document is submitted, cancelled, or a TIN is checked |
| `send-email` | Resend | the app's **Send queued** button, and the outbox scheduler |
| `fetch-rates` | Bank Negara Malaysia | the exchange-rate scheduler |
| `ocr` | whichever reader the company has chosen | the app, when a receipt is scanned |
| `call-token` | nobody — it signs | the app, once somebody has joined a call |
| `send-push` | Firebase Cloud Messaging | the sender's app, right after a message or a call |

They live in `supabase/functions/`. `_shared/` is not a function — it is
what they import, and the underscore is what tells both the CLI and the
deploy job to skip it.

## They are deployed by CI

Every push to the default branch redeploys all of them, from the
`functions` job in `.github/workflows/ci.yml`. There is nothing to run by
hand, and nothing to add to a list when a function is added — the job
reads the directory.

The job needs one repository secret:

**`SUPABASE_ACCESS_TOKEN`** — a personal access token from
[supabase.com → Account → Access Tokens][tokens]. It is the same
credential `supabase login` stores on a laptop, so it can do anything to
the project that you can; it belongs in **Settings → Secrets and
variables → Actions** and nowhere else.

[tokens]: https://supabase.com/dashboard/account/tokens

Until it is set the job warns, says on the run summary that nothing was
deployed, and passes. That is deliberate — a repository that has not been
given the token yet should not show a red tick on every commit — but it
does mean a green run is not by itself proof that the functions are
current. Read the summary.

The project reference (`ewwcgtnniwqndrzukksm`) is written into the
workflow rather than kept as a secret, because it is an identifier and
grants nothing on its own. A `SUPABASE_PROJECT_REF` secret or repository
variable overrides it.

### Why all three, every time

Because working out which functions a change to `_shared/` reaches is
exactly the kind of reasoning that goes wrong quietly. Deploying an
unchanged function costs a few seconds and a version number.

This job exists because of a real instance of the alternative: the
deployed `myinvois` was carrying a `loadCredentials` that selected
credentials on `org_id` alone, months after the repository had been fixed
to select on `(org_id, environment)`. Nothing would have reported that.
The repository read as though it were live, and the drift would have
surfaced as an authentication failure against LHDN on the day somebody
configured both environments.

### Why the default branch only

There is one Supabase project. A feature branch that deployed its own
functions would put half-finished work in front of production — which is
not true of the Vercel deploy in the same workflow, because that gets its
own preview URL. The two conditions look similar and are not the same.

### What the CLI reads, and what it does not

`verify_jwt` comes from `supabase/config.toml`, not from a command-line
flag, so it is reviewable in a diff. All three are `verify_jwt = true`,
and each checks something further on top of it — a JWT this project
signed includes the publishable key, which ships inside the web bundle
and is therefore public:

- `myinvois` resolves the caller and their membership of the organization
  named in the request body.
- `send-email` decides, from whether the caller proved it is the
  scheduler, whether it drains one organization's outbox or everybody's.
- `fetch-rates` requires that proof outright.

The proof is `_shared/scheduler.ts`, asserted by the CI `edge` job on
every push. [schedulers.md](schedulers.md) covers it.

**Function secrets are not deployed by this job**, and should not be.
`RESEND_API_KEY`, `MAIL_FROM`, `SCHEDULER_SECRET`, the OCR provider keys,
and the two call secrets below are set once in the Supabase dashboard
under **Edge Functions → Secrets** (or with `supabase secrets set`) and
live only in the function's environment — never in this repository, a
migration, a table, or the Flutter bundle. `SUPABASE_URL`,
`SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are injected by the
platform.

### Calling

`call-token` needs these before a call can connect. Until they are set it
returns 503 and says so, rather than failing as a network error:

| Name | Secret? | What it is |
| --- | --- | --- |
| `CALL_SFU_URL` | no | `wss://…`, the signalling socket |
| `CALL_SFU_SECRET` | **yes** | signs the room token the media server checks |
| `CALL_TURN_URLS` | no | comma separated `turn:`/`turns:` URLs |
| `CALL_TURN_SECRET` | **yes** | coturn's `static-auth-secret` |
| `CALL_STUN_URLS` | no | comma separated, optional |

Both secrets are HMAC keys. Either one in the database or in the app
would let anybody mint their own entry to any room, which is the whole
reason this is a function and not a SQL function.
[call-signalling.md](call-signalling.md) is the protocol the server on
the other end has to implement.

### Notifying

`send-push` needs one secret, `FCM_SERVICE_ACCOUNT` — the whole Firebase
service account JSON. Until it is set the function returns 503 and says
so, rather than accepting requests and silently sending nothing.
[push-notifications.md](push-notifications.md) covers what else Firebase
needs and what is not built yet.

## Deploying one by hand

Not necessary, and preferably not done — a hand deploy is how the drift
above happened. If a function has to go up without a commit:

```bash
supabase functions deploy send-email --project-ref ewwcgtnniwqndrzukksm
```

That needs the Supabase CLI installed, a clone of this repository, and
`supabase login`. Push to the default branch instead, and let the job do
it — that way the deployed copy and the repository are the same thing by
construction.
