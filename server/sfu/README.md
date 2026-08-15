# The call server

The media half of in-app calling. The other half — who may call whom,
whose phone rings, who answered, who hung up — is in Postgres, in
`supabase/migrations/0140_call_signalling.sql`, and this server does not
touch it. It holds no Supabase credentials and has no opinion about
permissions: by the time a socket arrives here, the database has already
decided.

The protocol between the app and this server is
[`docs/call-signalling.md`](../../docs/call-signalling.md). mediasoup is
a library rather than a server and defines no client protocol at all, so
that document is the contract, and this is its implementation.

## How the pieces fit

```
Flutter app ──1── Postgres            chat_calls: who is ringing, who answered
     │             (chat_start_call, chat_join_call)
     │
     ├────2──── call-token (Supabase edge function)
     │             checks the caller has joined, signs a room token
     │
     └────3──── this server (wss://)  signalling: transports, produce, consume
                        │
                        └── media (UDP 40000-40999) ── coturn, for the ~1 in 5
                                                       that cannot go direct
```

Step 2 is what stops step 3 needing a permission model. The token is
signed with `CALL_SFU_SECRET`, which exists in exactly two places — the
Supabase function secrets and this server's environment — and never in
the database, the repository, or the app bundle.

## Running it

### What you need

A Linux VM with a public IP. Not much of one: mediasoup forwards
packets, it does not transcode, so a 2-core box carries a lot of calls.
What it does need is the ports.

| Port | Protocol | What for |
| --- | --- | --- |
| 443 | TCP | `wss://` signalling, via nginx or a load balancer |
| 40000-40999 | UDP **and** TCP | media, direct to mediasoup |
| 3478 | UDP and TCP | TURN |
| 5349 | TCP | TURN over TLS |
| 49152-65535 | UDP | TURN relay |

Open all of them. The media range being closed is the single most common
cause of "the call connects and nobody can hear anything", because
signalling succeeds over 443 and only the media fails.

### Configure

```bash
cd server/sfu
cp .env.example .env      # then fill it in
docker compose up -d --build
```

`.env` is git-ignored and holds four things:

| Name | What it is |
| --- | --- |
| `CALL_SFU_SECRET` | any long random string. **Must be identical** to the Supabase function secret of the same name. |
| `CALL_TURN_SECRET` | likewise, for TURN. Different value, same rule. |
| `MEDIASOUP_ANNOUNCED_IP` | this machine's **public** address. |
| `TURN_REALM` | the TURN hostname, e.g. `call.example.my`. |

Generate the secrets with `openssl rand -hex 32`. Set them on the
Supabase side under **Edge Functions → Secrets** — never in a migration,
a table, or the Flutter bundle, because either one would let anybody mint
their own entry to any room.

`MEDIASOUP_ANNOUNCED_IP` is the setting that goes wrong. On a cloud VM
the socket binds to a private address, and that private address is what
mediasoup would otherwise put in its ICE candidates — so every client
would be told to send media somewhere it cannot reach. The server refuses
to start in production without it for exactly that reason.

### The rest of the settings

All optional, all with defaults that work:

| Name | Default | |
| --- | --- | --- |
| `PORT` | 4443 | the signalling socket |
| `MEDIASOUP_WORKERS` | one per core | each saturates one core and no more |
| `MEDIASOUP_MIN_PORT` / `MAX_PORT` | 40000 / 40999 | the media range |
| `CALL_MAX_PEERS_PER_ROOM` | 16 | a ceiling, not a business rule |
| `CALL_TOKEN_CLOCK_TOLERANCE` | 30s | how much clock drift to forgive |
| `CALL_HEARTBEAT_MS` | 20000 | how often to ping for dead sockets |
| `MEDIASOUP_LOG_LEVEL` | warn | |

### TLS

This server speaks plain `ws://` and expects nginx or a load balancer in
front doing TLS, because that is where certificate renewal already lives
on any machine serving anything else. The app connects to `wss://`.

```nginx
location / {
    proxy_pass http://127.0.0.1:4443;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    # A call is a long-lived socket. The default 60s read timeout closes
    # it mid-conversation, which reads as "the call keeps dropping".
    proxy_read_timeout 3600s;
}
```

Only the WebSocket goes through nginx. Media goes straight to the ports
above and must not be proxied.

### Checking it

```bash
curl -s localhost:4443/healthz     # {"ok":true,"rooms":0,"workers":4,...}
```

Then place a real call from two devices. The failure to look for is a
call that connects and stays silent — that is `MEDIASOUP_ANNOUNCED_IP`
or the UDP range, in that order, and never the signalling.

## Tests

```bash
npm install && npm test
```

Thirty-three assertions, run in CI on every push. They start real mediasoup
workers, open real WebSockets, and create real routers, transports,
producers and consumers — the token checks, the room rules, and the whole
protocol surface.

**What they do not cover is media.** Nothing in a test process performs a
DTLS handshake or sends an RTP packet, so producers there never carry
audio. That is a narrower gap than it sounds — `transport.produce()`
needs valid RTP parameters, not a connected transport, so the objects are
the real ones and the routing decisions about them (`canConsume`, who
gets a `newConsumer`, what happens when a producer closes) are the real
decisions. What is untested is whether packets arrive, which needs two
browsers and a network, and no amount of unit testing substitutes for
placing one call from two devices before trusting this with anybody's
meeting.

One bug these tests already caught, worth recording because it is the
kind that never shows up in development: the connection handler `await`s
a mediasoup router into existence before attaching its `message`
listener, and `ws` drops messages that arrive in between. The first
request of the first person into a call vanished, occasionally, under
load — and the app sat on "Connecting…" until it timed out. The socket is
now paused until its listeners exist, and
`a request sent the instant the socket opens is answered` fails without
that.

## Scaling, when it comes to that

One process, many workers, one router per room — a call lives entirely
inside one worker, because everybody in it has to be in the same router
to hear each other. That means a single machine's ceiling is roughly
"the busiest single call fits in one core", which for an accounting
system it always will.

Beyond one machine, the next step is several of these behind a load
balancer with sticky routing by room, which needs the `call-token`
function to choose the host and put it in the response — the client
already takes the URL from the token response rather than from a
constant, so that change is server-side only. Nothing here needs to
change to allow it, and nothing here should be built until it is needed.
