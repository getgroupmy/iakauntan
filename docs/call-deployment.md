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

## On a Synology NAS instead of a cloud VM

It works, and four things differ. None of them is the NAS being slow —
mediasoup forwards packets rather than transcoding — and all four are
about the NAS being behind a router rather than on the internet.

**Check these before buying anything or filling in a single field**,
because two of them can make the whole plan impossible and neither is
visible from the NAS:

1. **Is the WAN address public, or is the ISP using CGNAT?** Compare the
   WAN IP the router shows against what a "what is my IP" page says. If
   they differ, inbound is impossible and no amount of forwarding fixes
   it — the ISP has to give you a public IP, usually on a business plan.
   A "fixed IP" on the NAS itself is almost always a static LAN address,
   which is a different thing and not the one that matters here.
2. **Is the model x86 or ARM, and how much RAM?** mediasoup's worker is
   a native binary with prebuilt glibc builds for x86-64 and arm64. A
   Ryzen or Intel model (DS923+, DS1522+, DS918+) is comfortable; a
   modern arm64 j-series will run but has little memory to spare; an
   older armv7 model will not work at all. The Dockerfile can compile
   the worker if no prebuilt one matches, which on a 512 MB NAS means it
   will try for a long time and then fail.

### 0. The DNS record must be DNS-ONLY, not proxied

Checked on 29 September: `call.iakauntan.com` already resolves, and it
resolves to **Cloudflare** (104.21.x, 2606:4700:…) rather than to any
NAS. Either a wildcard or an existing record is answering for it, with
the orange cloud on.

**That cannot work, and it fails in a way that looks like two unrelated
bugs.** Cloudflare's proxy carries HTTP and WebSockets on 443, so
signalling might well connect — and TURN and media cannot go through an
HTTP reverse proxy at all. `turn:call.iakauntan.com:3478` would resolve
to Cloudflare, which is not listening for STUN, and the media ports are
not HTTP in the first place. So the call would connect and be silent,
which is the same symptom as a wrong announced address and has a
completely different cause.

Make `call` an explicit **A record, grey cloud (DNS only)**, pointing at
the router's public address. Not the NAS's LAN address. If a proxied
wildcard exists, the explicit record has to win over it.

The consequence of grey cloud is that the origin address is visible in
DNS. That is not a regression: a TURN server has to be reachable
directly or it is not a TURN server.

### 1. `MEDIASOUP_ANNOUNCED_IP` is the PUBLIC address, not the NAS's

This is the setting the whole deployment turns on. The container binds
the NAS's LAN address and must ANNOUNCE the router's public one, because
that is where the far side has to send. Putting the LAN address here
produces a call that connects and is silent — every time, with nothing
in any log saying so.

### 2. Port forwarding, and why the relay range was narrowed

Forward to the NAS's LAN address:

| | |
| --- | --- |
| 443/tcp | the `wss://` socket |
| 40000–40999 udp **and** tcp | mediasoup media |
| 3478 udp and tcp, 5349/tcp | TURN |
| 49152–49651/udp | TURN relay |
| 80/tcp | **only** for the certificate |

Port 80 is on that list for a reason that is easy to miss until a
renewal fails ninety days later: DSM's Let's Encrypt uses the HTTP-01
challenge, which needs port 80 reachable from outside at issuance **and
at every renewal**. Nothing serves on it otherwise.

That last range is 500 ports because this file's own coturn config was
narrowed from coturn's 16,384-port default for exactly this reason. If
the router cannot forward ranges at all — some ISP-supplied ones cannot
— that is a hard stop, and it is worth finding out before anything else.

### 3. DSM already owns 443, and its reverse proxy is better than nginx

Do not install nginx. **Control Panel → Login Portal → Advanced →
Reverse Proxy**: source `https://call.iakauntan.com:443`, destination
`http://localhost:4443`, and **turn on the WebSocket option** — without
it the upgrade is stripped and every call fails at connect with a clean,
unhelpful HTTP error.

Raise the proxy timeout while you are there. DSM's default closes a
long-lived socket mid-call, which gets reported as "calls keep
dropping" and looks nothing like a timeout.

DSM can also issue and renew the Let's Encrypt certificate for that
hostname, which is the other reason to use it rather than nginx.
**Control Panel → Security → Certificate.** coturn needs the same
certificate on disk for `turns:` — export it into
`server/sfu/coturn/certs/` as `fullchain.pem` and `privkey.pem`, and
remember the renewal will not reach the container by itself: the `turn`
container reads its certificate at start, so a renewal needs a restart.

### 4. On a 2 GB model, cap the workers

`MEDIASOUP_WORKERS` defaults to one per core — `os.cpus().length` in
`src/config.js` — which is four on a DS224+'s J4125. Four mediasoup
worker processes beside DSM on 2 GB is the wrong trade: each saturates
one core and no more, and nobody here is running enough concurrent calls
to need the second, let alone the fourth.

    MEDIASOUP_WORKERS=2

in `.env`. A call lives entirely inside one worker anyway, because
everybody in it has to share a router to hear each other.

### 5. Container Manager, not `docker compose` on a shell

DSM 7.2+: **Container Manager → Project → Create**, point it at the
`server/sfu` folder with its `docker-compose.yml`. `network_mode: host`
is supported there and is required — see the compose file's own header
for why publishing a thousand UDP ports through Docker's proxy is not an
option.

### The trap that will bite during filming

**Hairpin NAT.** With the announced address being the public one, two
devices *inside the same LAN as the NAS* may be told to send media to
the public IP and out through the router and back — which many routers
silently refuse. The call connects and is silent, and it looks exactly
like a wrong announced address.

So film with **one device on mobile data**. That is also the third proof
below, which is the one worth doing anyway.

### And the thing to decide rather than discover

DSM reboots for its own updates, and a call in progress dies with it.
Fine for a recording; a decision for production, where a small cloud VM
is the boring answer.

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
