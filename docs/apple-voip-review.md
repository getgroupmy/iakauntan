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
