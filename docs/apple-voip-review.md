# App Review: the `voip` background mode

App Review asked for one of two things:

> If the app has a feature that requires VoIP, reply to this message and
> add a screen recording showing the VoIP functionality on a physical
> device. […] If the app does not have a feature that requires VoIP, it
> would be appropriate to remove the "voip" value from the
> UIBackgroundModes key.

**This app has the feature. The key stays, and the answer is a
recording.** Removing `voip` from `app/ios/Runner/Info.plist:96` would
stop incoming calls arriving on a locked or backgrounded iPhone, which
is the whole of what `0140` and `0658` were built for.

## The evidence, in the order it answers their question

Apple's real concern is the last line of their message — VoIP used only
to keep a socket alive. The strongest single answer is a server rule,
not a screen:

* **`supabase/functions/send-push/routing.ts:73`** — a target registered
  as `apns_voip` is sent a push **only when the notification is a
  call**. Every other notification to that device returns `null`. There
  is no path in this codebase that sends a VoIP push for a message, a
  badge, a sync or a wake-up, and `routing_test.ts` asserts it.
* **`supabase/functions/_shared/apns.ts:134`** — a VoIP push is
  addressed to `<bundle>.voip` and nothing else, with `apns-push-type:
  voip` set at `:150` for a call and `alert` for everything else.
* **`app/ios/Runner/AppDelegate.swift:325`** — `PKPushRegistry` with
  `desiredPushTypes = [.voIP]`, and **`:411`
  `provider.reportNewIncomingCall`**: every VoIP push reports a call to
  CallKit before the completion handler returns, which is the contract
  Apple is checking for.
* **`supabase/migrations/0140_call_signalling.sql:57`** — `chat_calls`,
  the signalling table: one open call per conversation, with offer,
  answer and ICE candidates.
* **`app/lib/src/features/chat/call_incoming.dart:330` and `:338`** —
  the voice and video call buttons in a conversation;
  `call_screen.dart` and `call_engine.dart` are the call itself.

The `audio` value beside it is for the same feature: a call that
continues while the person switches apps.

## BLOCKED: the media server is not deployed

Found by trying it, 29 September, on the demo pair:

    FunctionException(status: 503, {error: Calling is not configured.
    Set CALL_SFU_URL and CALL_SFU_SECRET in the project's function
    secrets.})

That is `call-token/index.ts:127` refusing plainly, and it is not a
missing config line. `CALL_SFU_URL` points at `server/sfu/` — a
mediasoup server that has never been deployed. Its README says what it
needs: a Linux VM with a public IP, TCP 443 for the `wss://` signalling
socket, UDP 40000–40999 for media, and coturn beside it for the roughly
one call in five that cannot go direct. Plus the two secrets, which must
match on both sides.

**So the recording cannot be finished today**, and the script below is
split by what the missing piece actually stops:

| shots | needs the SFU? |
| --- | --- |
| 1–4: locked handset, ring, CallKit answer, app opens | **no** |
| 5–7: two-way audio, backgrounded call, hang up | **yes** |

The ring works without it because of the ORDER in
`Repo.chatStartCall`: the RPC creates the call row and the VoIP push is
fired immediately after it (`unawaited(notifyPush(kind: 'call'))`),
before anything asks for a media token. So a locked iPhone really does
ring with the system's own call UI and really can be answered — and then
the call screen fails, which is precisely the shot that must not be in a
video sent to Apple.

Two things to fix before filming:

1. **Deploy `server/sfu/`** and set both secrets.
2. **Add the SFU host to `connect-src`** in the CSP. `docs/pre-deployment.md`
   already warns about this and it is worth repeating here because it
   fails silently: the header lists the Supabase host and nothing else,
   so the WEB build's call socket to `wss://<sfu-host>` is refused with
   no useful error. Native is unaffected — which means the web caller
   this document recommends would break while the phone looked fine.

### A failed attempt leaves the conversation stuck

`chat_calls` has a unique index of one open call per conversation. The
503 happens AFTER the row is created, so the call stays open, the call
buttons are replaced by "Join call", and nothing can start a fresh one.
One such row was cleared by hand on 29 September. If the buttons are
missing during filming, that is why; `chat_end_call` is the verb, and
only whoever started it may call it.

## What to record

Two physical iPhones (or one iPhone and one other signed-in client),
both on a build with push registered. **Do not use the Simulator** —
PushKit does not deliver there, and Apple asked for a physical device.

Before recording, on the CALLEE handset:

1. Sign in and open Settings → Notifications; grant the permission and
   register the device. The alert token and the PushKit token are two
   different tokens and both are registered here (`0658`).
2. Confirm the device appears in the registered-devices list.

Then record in one unbroken take, screen recording the **callee**:

| # | What the camera sees | Why Apple needs it |
|---|---|---|
| 1 | The callee's iPhone **locked**, screen off, app not running — swipe up to show the app switcher first so it is visibly not backgrounded, then lock it | Proves the process is not alive |
| 2 | The caller taps the **voice call** button in the conversation | Shows the feature that originates the call |
| 3 | The locked callee **rings full screen with the system's own call UI** — not an app notification | This is `reportNewIncomingCall`; it is the shot the whole recording exists for |
| 4 | Answer on the **system** call screen | Shows CallKit answering, not the app |
| 5 | The app opens into the call and **audio passes both ways** — say something on each side | Shows the VoIP session is real |
| 6 | Press Home so the app is backgrounded; audio keeps passing; return to the call | This is the `audio` mode, justified in the same take |
| 7 | End the call from the system call UI | Shows the full lifecycle |

Then repeat 1–4 once with a **video** call, which is a second shot and
only costs twenty seconds.

Keep it under two minutes, no edits, no cuts between step 2 and step 3 —
a cut there is exactly where a reviewer would doubt it.

## The two demo accounts

A call needs two people, so App Review needs two accounts — and the four
things that make the call button appear are easy to get three-quarters
right. `0724` does the wiring in one call:

```sql
select public.demo_calling_pair(
  'review-one@example.com', 'review-two@example.com', 'iAkauntan Demo');
```

It is idempotent, platform-admin only, and returns the conversation id.
What it does NOT do is create the accounts, and that is not an oversight:
an account and its password live in `auth.users`, which only the Admin
API may write — `supabase/functions/platform-users/index.ts` is where
that key lives and why. A row written straight into the table is an
account that exists and cannot sign in.

So the order is:

1. **Console → Users → new**, twice. Set the passwords there. Use
   addresses that are obviously for review, and treat the passwords the
   way you would any other credential — they do not belong in a commit,
   an issue, or a chat message.
2. Run the call above with those two addresses.
3. Sign in as each once, on the devices you will film with, and grant
   notifications on the iPhone so the PushKit token is registered.

What the function actually guarantees, and what the assertion file
proves, is `app.chat_enabled` answering true for both people — which is
only true when the company is entitled to `chat`, **each person is
switched on individually in `chat_access`**, and both are members. That
third one is the one that gets missed: two members of a company that has
bought chat still cannot see each other until their own row exists, and
the symptom is a call button that is simply absent.

### What exists in production now (29 September 2026)

Done, verified, and recorded here because a demo org created outside a
migration is invisible to anybody reading the schema:

| | |
| --- | --- |
| company | `iAkauntan Demo`, slug `iakauntan-demo`, `a1ae9901-5215-4810-b094-e94060d7f10d` |
| conversation | `5f42b308-e82e-444e-83b9-74ec131420c9` |
| owner | `test_account_1@iakauntan.com` |
| admin | `test_account_2@iakauntan.com` |

`app.chat_enabled` answers true for both, both `chat_access` rows are
enabled, and the conversation has exactly those two participants.

Two things about how it got there are worth keeping:

* **`demo_calling_pair` was run twice** — once by the platform admin
  through the SQL editor with their own claims, once as the database
  owner — and the second run returned the SAME conversation id. That is
  the idempotence assertion confirmed against production rather than
  only against a throwaway Postgres.
* **`superadmin@iakauntan.com` was removed afterwards, but only after
  the company was handed over.** `add_creator_as_owner` had made them
  the owner, and `platform_remove_org_access` refuses to take the last
  owner away — *"A company with no owner is a company nobody can open —
  hand it over first."* So `test_account_1` is the owner now. Their
  `chat_access` row was deleted too: it is a separate per-person row and
  does not cascade from membership, so leaving it would be a chat
  entitlement for somebody who is not a member.

Those writes went in as the database owner, so their `audit_logs` rows
carry a null `user_id`. That is the price of doing it that way and it is
recorded here rather than left to be discovered.

### Who places the call

The **callee** must be the iPhone — that is the device the recording is
of, and PushKit only delivers to a real handset. The **caller** can be
anything signed in as the other account: a second handset, or the web
build in a desktop browser, which is the easier setup for a reviewer
with one phone. Try the web side once before relying on it for a
submission.

## What to send

Reply to the App Review message with the recording attached, and put the
same text in **App Store Connect → App Review Information → Notes** so a
future submission does not ask again.

> iAkauntan includes one-to-one voice and video calling inside its team
> chat. `voip` is required so that an incoming call can be reported to
> CallKit while the app is not running: a PushKit push starts the
> process and the app calls `reportNewIncomingCall` before the
> completion handler returns, so the recipient sees the system's own
> full-screen call UI on a locked device.
>
> VoIP pushes are sent for calls only. Our server sends a push to a
> PushKit token exclusively when the notification is a call; messages,
> badges and every other notification go to the standard APNs alert
> token on a different topic. VoIP is not used to keep a connection
> alive.
>
> The `audio` background mode beside it is for an in-progress call
> continuing while the user switches apps.
>
> A screen recording of the full sequence on a physical iPhone —
> locked device, incoming call, CallKit answer, two-way audio, backgrounded
> call, hang up — is attached.

Demo accounts: App Review needs **two** signed-in accounts to see a call
arrive, or they will accept the recording in place of reproducing it.
Give them both sets of credentials in the Notes field if they ask to
reproduce it themselves.

## If the answer ever becomes "remove it"

Then it is not only the plist. `voip` supports a feature, and taking the
key out while the feature ships is worse than either choice: the call
buttons would still be drawn, the push would still be sent, and the
recipient would simply never ring. Removing it means removing the
feature — `CallButtons`, `IncomingCallWatcher`, the `apns_voip`
transport in `routing.ts`, and the PushKit half of `AppDelegate` — and
that is a product decision, not a build setting.
