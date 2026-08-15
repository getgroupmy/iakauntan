# The call signalling protocol

This document is a contract, not a description. mediasoup is a Node.js
library, not a server: it gives you a `Router`, `WebRtcTransport`,
`Producer` and `Consumer`, and says nothing whatsoever about how a
client is supposed to ask for them. Every mediasoup deployment invents
its own wire protocol between browser and server, and no two are the
same.

So the app had to pick one, and it picked the shape the official
mediasoup demo uses, because that is the closest thing to a convention
the ecosystem has and because the Flutter client library is written
against it.

**Both ends of this contract are in this repository.** The server is
[`server/sfu`](../server/sfu/README.md), and its tests drive every
method and notification below against real mediasoup workers. If a
method appears here and not there, or the other way round, one of them
is wrong — that is what the document is for.

Where it lives in the codebase:

| Piece | File |
|---|---|
| Signalling state (who is called, who answered) | `supabase/migrations/0140_call_signalling.sql` |
| Room credentials | `supabase/functions/call-token/index.ts` |
| Client transport | `app/lib/src/features/chat/call_engine.dart` |
| Call UI | `app/lib/src/features/chat/call_screen.dart` |
| The server | `server/sfu/` |

## Before the socket

A call exists in the database before it exists on the media server.

1. Somebody calls `chat_start_call(conversation, kind)`. A row appears in
   `chat_calls` with a random `room_name`, and a `chat_call_participants`
   row per member of the conversation, all in state `ringing`.
2. Everybody's app is watching `chat_incoming_calls()` and starts
   ringing.
3. Whoever answers calls `chat_join_call(call_id)`, which moves their own
   participant row to `joined` and the call to `live`.
4. Only then does the app `POST /functions/v1/call-token` with
   `{ "call_id": … }`, and get back:

```json
{
  "url": "wss://sfu.example.my",
  "room": "9f2c…",
  "peer_id": "<the caller's auth.users id>",
  "display_name": "Siti Nurhaliza",
  "token": "<HS256 JWT>",
  "ice_servers": [
    { "urls": ["stun:turn.example.my:3478"] },
    { "urls": ["turn:turn.example.my:3478?transport=udp"],
      "username": "1786000000:0f1e…", "credential": "base64…" }
  ],
  "expires_at": "2026-08-14T12:00:00Z"
}
```

The order matters: the token is refused to anybody whose participant row
is not `joined`. A room name is visible to the whole conversation, so it
cannot be what gets you in.

### Verifying the token

The token is a plain HS256 JWT signed with `CALL_SFU_SECRET`, which the
server also holds and which exists nowhere else — not in the database,
not in the Flutter bundle.

```json
{ "sub": "<user id>", "room": "9f2c…", "kind": "video",
  "name": "Siti Nurhaliza", "iat": …, "exp": … }
```

The server must, on connect:

- verify the signature and that `exp` is in the future;
- take the room from the **token**, never from the query string;
- take the peer id from `sub`, never from the client.

A server that trusts a `room` query parameter has no access control at
all, because the app is the only thing that would ever send the right
one.

### TURN

`ice_servers` carries coturn's REST credentials: username is
`<expiry>:<user id>`, password is base64(HMAC-SHA1(username,
`CALL_TURN_SECRET`)). coturn recomputes it per request under
`use-auth-secret`, so no accounts are created and nothing needs revoking
— the pair simply stops working after `expires_at`.

Roughly one connection in five cannot go peer to peer, so this is not
optional in practice, and on a corporate network it is most of them.

## The socket

`wss://<url>/?token=<jwt>` — one socket per peer, JSON frames.

Three frame shapes, distinguished by which keys are present:

```jsonc
// request  (either direction)
{ "id": 7, "method": "join", "data": { … } }

// response (to the id above)
{ "id": 7, "ok": true, "data": { … } }
{ "id": 7, "ok": false, "error": "…" }

// notification (no id, no answer expected)
{ "notification": "peerClosed", "data": { "peerId": "…" } }
```

### Requests the client sends

| Method | `data` | Response `data` |
|---|---|---|
| `getRouterRtpCapabilities` | — | the router's `RtpCapabilities` |
| `join` | `{ rtpCapabilities, displayName }` | `{ peers: [{ id, displayName }] }` |
| `createWebRtcTransport` | `{ producing, consuming }` | `{ id, iceParameters, iceCandidates, dtlsParameters }` |
| `connectWebRtcTransport` | `{ transportId, dtlsParameters }` | `{}` |
| `produce` | `{ transportId, kind, rtpParameters, appData }` | `{ id }` |
| `closeProducer` | `{ producerId }` | `{}` |
| `pauseProducer` | `{ producerId }` | `{}` |
| `resumeProducer` | `{ producerId }` | `{}` |
| `resumeConsumer` | `{ consumerId }` | `{}` |

Two transports are created per peer, one `producing` and one
`consuming`. `connectWebRtcTransport` is sent when mediasoup-client
raises its `connect` event, not before — DTLS parameters do not exist
until then.

`join` is sent **after** both transports exist, so that the server can
send a `newConsumer` for everybody already in the room and the client has
somewhere to put them.

### Notifications the server sends

| Notification | `data` |
|---|---|
| `newConsumer` | `{ peerId, producerId, id, kind, rtpParameters, appData, producerPaused }` |
| `consumerClosed` | `{ consumerId }` |
| `consumerPaused` / `consumerResumed` | `{ consumerId }` |
| `peerJoined` | `{ peerId, displayName }` |
| `peerClosed` | `{ peerId }` |

Consumers are created **paused** on the server — that is mediasoup's own
advice, so the first key frame is not sent before the client has a
receiver for it. The client sends `resumeConsumer` as soon as it has one.
A server that creates them unpaused will mostly work and will
occasionally show a black rectangle for several seconds.

`appData` carries `{ "source": "mic" | "cam" | "screen" }`, which is how
the UI tells one track from another. It is not decoration: a camera and
a shared screen are both `kind: "video"`, so without the label a
spreadsheet ends up in the little round avatar.

### Sharing a screen

A screen is an ordinary video producer with `appData.source = "screen"`,
and it stops with `closeProducer` like any other. Two rules are the
server's rather than the app's:

- **One screen per room.** `produce` with `source: "screen"` is refused
  while somebody else is sharing, and the refusal names them —
  `"Ahmad is already sharing a screen"` — because "no" with no reason
  sends people to look for a bug. Two screens at once is technically
  fine and is a room where two people fight over everybody else's
  window with no way to choose.
- **The refusal has to be handled.** The client rolls its own state back
  when it comes: a share button left lit over a capture nobody is
  receiving is worse than the refusal.

Rules the app cannot be trusted with are enforced where they cannot be
skipped, which is the same reason `mic` and `cam` are *not* checked —
those only label a stream that peer may already send.

## What the server must also do

Signalling state lives in Postgres and the media server does not write to
it — it holds no Supabase credentials and should not. Two consequences:

- **Hanging up is two things.** The client sends `chat_leave_call` (or
  `chat_end_call`) to the database *and* closes the socket. If the socket
  dies without the RPC — a killed app, a tunnel dropped — the row says
  `live` until `chat_expire_calls` tidies it. That is why
  `chat_active_call` treats a ringing call past `ringing_until` as not
  ringing rather than trusting the row.
- **The room is not created by the app.** The server makes a router for a
  room the first time somebody presents a valid token for it, and
  destroys it when the last peer leaves.

## What has and has not been exercised

| Half | Covered by | Runs in CI |
| --- | --- | --- |
| Signalling state — ringing, joining, declining, expiry, who is permitted | `supabase/tests/chat.sql` | yes |
| This protocol, against real routers and transports | `server/sfu/test/` | yes |
| The call UI, against a fake engine | `app/test/call_screen_test.dart` | yes |
| Media actually arriving | nothing | **no** |

### Where screen sharing works

`getDisplayMedia` is a browser and desktop call. Android and iOS both
need platform work the Dart side cannot do, so the button is absent
there rather than present and broken:

| | |
| --- | --- |
| Web, macOS, Windows, Linux | works, no extra permission |
| Android | needs a foreground service of type `mediaProjection`, or the system stops the capture after a few seconds |
| iOS | needs a Broadcast Upload Extension: a second Xcode target sharing an App Group with the app |

The gap is the third row, and it is not one more test away. Nothing in a
test process performs a DTLS handshake or sends an RTP packet, so no
suite here can tell you whether two people can hear each other — that
takes two devices on two networks. Place one real call before trusting
this with anybody's meeting.

### A note on the client library

The obvious package, `mediasoup_client_flutter`, does not compile. It was
last released in 2022 against `flutter_webrtc 0.9.x`; `webrtc_interface`
has since changed two of the types it extends, and `dart_webrtc` moved to
`package:web`. Neither problem is fixable with version constraints:
pinning the interface back breaks the layer below it, and the web
renderer in `flutter_webrtc 0.9.48` cannot compile against any
`dart_webrtc` new enough for `package:web ^1.0.0`, which this app needs
for its download helper. Twelve type errors in the library, then four
more in `flutter_webrtc` itself — the whole 2023 stack has rotted out
from under it.

`mediasfu_mediasoup_client` is the same library, forked and maintained
against current `flutter_webrtc`. Identical API; the only difference in
`call_engine.dart` is the import line. If upstream ever revives, the
swap back is one line.
