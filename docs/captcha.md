# The security check on the sign-in pages

Cloudflare Turnstile, on the four forms nobody is signed in for:
registration, sign-in, the forgot-password link and the confirmation
resend.

Supabase Auth does the verifying. The app draws the widget and sends the
token it produces as `captchaToken` on `signUp`, `signInWithPassword`,
`resetPasswordForEmail` and `resend`; GoTrue checks it against
Cloudflare before it does anything else.

## Two keys, and only one of them belongs here

Turnstile has a **site key** and a **secret**.

The site key identifies the widget to the browser. It is public by
design — it is in the page source of every site that uses Turnstile —
and it lives on `landing_page.turnstile_site_key`, where the platform
console can change it without a release (`0556`).

The secret verifies a token, and the thing doing the verifying is
GoTrue. It goes in the Supabase dashboard under **Authentication →
Attack Protection** and never in this repository, this database, or any
payload the app can read.

## Switching it on, in this order

1. Create a Turnstile site at `dash.cloudflare.com` → Turnstile. Add
   every hostname the app is served from: `iakauntan.com`, any
   workspace subdomains, and `localhost` if you sign in against a local
   build.
2. Paste the **site key** into the platform console, under the sign-in
   page settings, and save.
3. Check the Content-Security-Policy allows Cloudflare. Turnstile is
   a script, an iframe and a callback, so `deploy/vercel-output-config.json`
   needs `https://challenges.cloudflare.com` in `script-src`,
   `frame-src` AND `connect-src`. A missing `frame-src` is the quiet
   one: there is no such directive by default, so it falls back to
   `default-src 'self'` and the widget's iframe is refused with
   everything else looking correct.

   `scripts/check_csp_allows.py` asserts this, and CI runs it. It exists
   because the policy shipped without any of the three: the widget never
   drew, the form went on demanding a token from a box that was not on
   the screen, and nobody could sign in with a password. A blocked
   script is a console message on somebody else's machine.
4. Load `/signin` and check the widget draws.
5. Only then, in Supabase: **Authentication → Attack Protection →
   Enable Captcha protection**, provider Turnstile, and paste the
   **secret**.

Doing 5 before 2 refuses every sign-in on the project — including
yours — because GoTrue starts demanding a token no form is sending.

## The trap: the switch covers the whole project

Attack Protection is a project-wide setting. It applies to every client
that talks to GoTrue, not only the web app.

**The Android and iOS builds cannot draw a Turnstile widget.** Turnstile
is a browser widget with no native SDK; embedding it on a phone needs a
webview, and this app does not carry one. Until it does, enabling the
protection locks every phone out of signing in.

The app says so rather than failing silently: on a platform that cannot
draw the widget, the form prints "This app cannot complete the security
check on this device. Use the web app to sign in." That is honest, and
it is not a substitute for knowing this before pressing the switch.

If the mobile apps are in use, the options are: leave the protection off
until a webview-backed widget is written, or accept that mobile sign-in
stops.

## How wide the box is

Turnstile's default `size` is a fixed 300x65 rectangle. The sign-in
form's fields are wider than that on nearly every screen, so the check
sat in the column looking like something that had been pasted in --
reported from an Android handset, where the gap either side of it is
most of the difference.

It is rendered with `size: 'flexible'`, which takes the width of its
container down to a floor of 300 and keeps the same 65-pixel height.

That only works if the container HAS a width. Flutter sizes the slot it
drops a platform view into; it does not size the element inside it, so
the `<div>` the view factory returns is given `width: 100%` and
`height: 100%` explicitly. Without that the browser lays the div out at
its content, Flutter reports that the view's size was never set, and
Cloudflare has nothing to be flexible against and falls back to 300.

Both halves live in `lib/src/features/auth/captcha_web.dart`, and
neither is covered by a test: that file is compiled only for the web,
`flutter test` runs on the VM, and CI runs no browser tests. Changing
it means loading a form in a browser and looking.

## Switching it off

Clear the site key in the console AND turn the protection off in the
dashboard. Either alone leaves a form that cannot be submitted: no key
means no token, and the protection means no token is refused.

## What is not covered

Changing an email address or a mobile number happens inside the app,
where the caller is already signed in and Supabase's captcha protection
does not reach. Those are guarded by re-entering the account password,
which answers the question that actually matters there — whether the
person at the keyboard is the account holder — where a captcha only
answers whether anybody is.
