# The sign-in link

A link in the inbox instead of a password in the box. Press "Email me a link
instead", open what arrives, and you are signed in.

`signin_show_magic_link` ships **off**, and this page is why.

## Who it is for

Not the accountant who signs in every morning — a password manager has
already solved that. It is for the person who signs in twice a year: a
director approving one resolution, an auditor looking at one year's
accounts. They will have forgotten the password by then, ask for a reset,
and end up in the same inbox anyway. A sign-in link is that, without the
intervening screen.

## What is already built

* **The database.** `signin_show_magic_link` is a column on the landing
  page, carried into `brand` so the sign-in screen sees it whether or not a
  marketing site has been published. Migration `0613`.
* **The console.** Platform console → Site pages → "Offer a link by email".
* **The screen.** The button, the wait, the wording, and the one line that
  keeps it a sign-in form rather than a registration one.

## What has to happen first, in the Supabase dashboard

**Authentication → Emails → SMTP Settings.** Configure a sender.

Until you do, the project uses Supabase's built-in service, and its limit
is deliberately unusable for anything real: a handful of messages an hour,
shared across every address on the project. That is not a bug — it is there
to stop projects being used to send mail — but the effect is that almost
everybody who presses the button gets nothing, and waits.

This is the same sender the password reset uses, so a project that already
sends resets has nothing more to do.

**Authentication → URL Configuration → Redirect URLs.** The app aims the
link at `Uri.base.origin`, so a preview deployment sends people back to that
preview instead of production. Every origin you deploy to has to be on that
list, or GoTrue refuses the redirect and the link lands on the project's
Site URL instead.

**Authentication → Providers → Email → "Confirm email".** Leave it as it is.
A sign-in link and a confirmation link are the same mechanism, and turning
confirmation off does not turn this off.

## The one line that matters

```dart
shouldCreateUser: false,
```

The default is `true`, and it **creates an account for any address typed
into the box**. A sign-in form would silently become a registration form —
on a platform whose operator may have switched registration off entirely,
and whose door policy would then turn the new account away.

With it false, GoTrue answers `signups not allowed` for an address it does
not know. The screen does **not** show that: it shows the same "if there is
an account" sentence it shows for a real one. Two different answers would
turn the form into a way to find out who has an account here by typing.

## The wait

Held in the client as well as at the server, because a link that can be
asked for every few seconds is a way to fill somebody's inbox using nothing
but their address.

It has **its own clock**, separate from the password reset's. Asking for a
sign-in link is not asking for a reset, and sharing the timer would tell
somebody who has just reset their password that they cannot have a link
either, for a reason about a different button.

Where the server states a wait of its own, that one wins: told to wait forty
seconds, saying "five minutes" would be a second wrong answer on top of the
first.

## What this is not

It is not two-factor, and it is not a replacement for a passkey. A link in
an inbox is exactly as strong as that inbox — which for most people is
stronger than the password they would otherwise have chosen, and weaker than
a key their laptop holds and their fingerprint unlocks.

If you want the strongest of the three, `docs/passkeys.md` is the other
page, and both switches can be on at once.
