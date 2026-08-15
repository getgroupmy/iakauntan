# Push notifications

What makes a phone ring when the app is closed.

Chat (0135) and calling (0140) both shipped with the same limitation: a
call rang only on a device that already had the app open, and a message
arrived only where somebody was already looking. Since the reason to ring
somebody is that they are doing something else, that is close to saying
it did not work.

| Piece | Where |
| --- | --- |
| The register of devices, and who may be reached | `supabase/migrations/0141_push_notifications.sql` |
| Assertions | `supabase/tests/push.sql` (runs in CI) |
| The sender | `supabase/functions/send-push/` |
| Registration in the app | **not built yet** — see the bottom of this page |

## How a notification happens

1. The app registers its Firebase token with `register_device(token,
   platform, label)` on every start.
2. Somebody sends a message or starts a call.
3. **The sender's own app** calls `send-push` with the conversation id.
4. `send-push` checks, under the caller's own token, that they are in
   that conversation; reads the devices to reach with the service role;
   and posts to FCM.

### Why the sender's app asks, rather than a trigger

A database trigger firing `pg_net` would be more robust — it would fire
whether or not the sender's app survived the moment. It would also mean
putting the function's URL and a service key inside the database, which
is the one thing every other decision in this system has been arranged
to avoid.

The cost is real and worth stating: a phone that dies between
`chat_send` and the push call sends no notification. The message is
still committed and still arrives the moment the other person opens the
app. That is a much better failure than a service key in a table.

## The rules, and where they live

`push_targets(conversation, exclude)` is the whole fan-out, and it does
not restate the permission model — it joins through `chat_participants`,
which is where 0135, 0138 and 0139 already put it. A second copy of
those rules would be a second copy free to disagree with the first.

What `supabase/tests/push.sql` asserts, each refusal paired with the
thing that must still work:

- A handset that changes hands belongs to whoever signed in last.
- A person sees their own devices and none of anybody else's.
- A client cannot read `push_targets` at all — not for their own room,
  not for any room.
- The sender's own devices are never in the list.
- A colleague who is not in the conversation is not reached, even with a
  registered handset.
- Switching chat off for somebody stops their notifications; so does the
  company's module lapsing.
- A client cannot forget or unregister somebody else's token.

### One token, one handset

The token identifies an *installation*, not a person. When somebody
signs out and a colleague signs in on the same phone, Firebase hands
back the same token — so `device_tokens.token` is unique on its own and
registering **moves** it. Keyed on `(user, token)` instead, both people
would have a live registration for one handset, and the first person's
messages would keep arriving on a phone they no longer hold. In a system
carrying payroll and bank details that is not a notification bug.

## What is deliberately not in the payload

The message text.

A notification lands on a lock screen anybody standing near the desk can
read, and this application's chat carries payslips, bank details and
things said about staff. So the push says who it is from and where, and
the content is fetched when the app is opened by somebody who has
authenticated.

This is stricter than most chat applications. Relaxing it means adding
the body in `send-push` and nothing else — but it should be a decision
somebody makes on purpose, not a default that leaked out.

## Configuring it

One secret, set under **Edge Functions → Secrets** and nowhere else:

| Name | What it is |
| --- | --- |
| `FCM_SERVICE_ACCOUNT` | the whole Firebase service account JSON, including `project_id` |

Get it from the Firebase console → Project settings → Service accounts →
Generate new private key. Until it is set, `send-push` returns 503 and
says so, rather than accepting the request and silently sending nothing.

You will also need, on the Firebase side:

- an **APNs key** uploaded to Firebase, or nothing reaches iOS;
- `google-services.json` in the Android app and
  `GoogleService-Info.plist` in the iOS app;
- a **VAPID key pair** and a service worker for web push.

## What is not built

**The app does not register anything yet.** The database and the sender
are complete and asserted; the Flutter half is not written, so today
nothing calls `register_device` and `send-push` has nobody to send to.
That is the next piece of work, and it needs the Firebase project above
to exist first — adding `firebase_core` to the build without
`google-services.json` breaks the Android build outright, so it is not
something to do speculatively.

Two platform limits worth knowing before that work starts, because they
change what is achievable rather than just how long it takes:

- **iOS calls cannot ring properly through FCM.** A real incoming-call
  screen on a locked iPhone needs CallKit driven by a **PushKit** VoIP
  push, and FCM cannot send one. What FCM can do is a time-sensitive
  alert — a banner with sound, which the person taps to answer. Proper
  CallKit ringing needs APNs addressed directly, with the VoIP
  certificate, from something other than FCM.
- **Web push on Safari** needs the app installed to the home screen as a
  PWA. Chrome, Edge and Firefox work from an ordinary tab.

Android is the one platform where a call can ring the way people expect,
via a high-priority data message and a full-screen intent.
