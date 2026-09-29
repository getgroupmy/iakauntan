# Turning calling on

In-app calling is built and tested and has never been switched on. This
is the order to switch it on in, and the checks that tell you each step
worked before the next one can hide its failure.

It does not repeat [`server/sfu/README.md`](../server/sfu/README.md) —
that is the server, its settings and its ports, and it is right. What is
here is the sequence, including the two steps that are NOT in
`server/sfu` at all and are the reason this file exists: the Supabase
secrets and the browser's content policy.

The symptom when it is not on, and the line to search for when somebody
reports it:

    FunctionException(status: 503, {error: Calling is not configured.
    Set CALL_SFU_URL and CALL_SFU_SECRET in the project's function
    secrets.})

## The host is a decision, and it is already written down

`call.iakauntan.com`. Chosen because `wss://` hosts cannot be
discovered by a browser at runtime — the content policy has to name one
ahead of time — so it is pinned in two places:

* `deploy/vercel-output-config.json`, in `connect-src`;
* `scripts/check_csp_allows.py`, which fails the build if the policy
  ever loses it.

Move the SFU and both change together. Nothing else in the repository
names it: the app takes the URL from `call-token`'s response rather than
from a constant, which is what makes several SFUs behind a load balancer
a server-side change later.

## In order

### 1. DNS, before anything

`call.iakauntan.com` → the VM's public IP. Do it first: certificate
issuance needs it to resolve, and so does `TURN_REALM`.

### 2. The VM and its ports

`server/sfu/README.md` has the table. The one worth re-reading is the
media range, **UDP and TCP 40000–40999**, because it is the only entry
whose absence produces a call that connects and is silent — signalling
succeeds over 443 and the media alone fails, which sends people to look
at the signalling.

### 3. The server

```bash
cd server/sfu && cp .env.example .env    # fill it in
docker compose up -d --build
curl -s localhost:4443/healthz           # {"ok":true,...}
```

`MEDIASOUP_ANNOUNCED_IP` is the public address, not the one the socket
binds to. The server refuses to start in production without it.

### 4. nginx in front of it

The snippet is in the SFU README. `proxy_read_timeout 3600s` is the part
that is not decoration: the default sixty seconds closes a call
mid-conversation, and it is reported as "calls keep dropping".

### 5. The two Supabase secrets

**Edge Functions → Secrets**, on the project:

| | |
| --- | --- |
| `CALL_SFU_URL` | `wss://call.iakauntan.com` |
| `CALL_SFU_SECRET` | the same value as the server's `.env` |

Identical on both sides or every token is rejected. Never in a
migration, a table or the app bundle — anything the client can read
would let anybody mint their own entry to any room.

`call-token` reads them at invocation, so no redeploy is needed; the
503 stops on the next call.

### 6. The content policy — the step that only breaks the web

Already committed, so this is a verification rather than an edit:

```bash
python3 scripts/check_csp_allows.py
```

It has to be a *deployed* build for the header to change. Until it is,
the web caller's socket is refused with no useful error while a phone on
the same call is fine — which is the worst shape of failure, because the
half that works is the half you are watching.

## Then prove it, in this order

Each step fails differently, so do them in order and stop at the first
one that does not behave.

1. **`curl -s https://call.iakauntan.com/healthz` from off the VM.**
   Proves DNS, TLS, nginx and the process. Not the media.
2. **A call between two devices on the same network.** Proves
   signalling and the token. Still not the ports: two devices on one LAN
   usually go direct.
3. **A call between two devices on DIFFERENT networks, one on mobile
   data.** This is the one that proves the media range and TURN, and it
   is the one nobody does. A call that connects and is silent here is
   `MEDIASOUP_ANNOUNCED_IP` or the UDP range, in that order.

Only (3) makes the Apple recording in
[`apple-voip-review.md`](apple-voip-review.md) filmable end to end.

## What can be filmed before any of this

The ring. `Repo.chatStartCall` creates the call row and fires the VoIP
push immediately after the RPC, before anything asks for a media token —
so a locked iPhone rings with CallKit's own screen and can be answered
without an SFU existing. The call screen then fails, which is why that
is four shots of a seven-shot recording rather than a shortcut.

## One thing that bites during testing

A failed call leaves the conversation stuck. `chat_calls` carries a
unique index of one open call per conversation, and the 503 lands AFTER
the row is created — so the call buttons are replaced by "Join call" and
nothing starts a fresh one. `chat_end_call` is the verb, and only
whoever started the call may call it.
