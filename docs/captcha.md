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

## The switch covers the whole project, and the phones are in it

Attack Protection is a project-wide setting. It applies to every client
that talks to GoTrue, not only the web app. So the phones have to be
able to produce a token before it is pressed.

They can. `captcha_native.dart` draws the challenge in a webview and
reads the token back out of it; `web/captcha.html` is the other half.
This section used to say the opposite — "the Android and iOS builds
cannot draw a Turnstile widget… this app does not carry one" — and went
on saying it after `879b692` built it.

### Why a hosted page and not an HTML string

Every short guide to Turnstile on mobile loads an HTML string into the
webview with a `data:` URI. That does not work here, and the reason is
worth keeping: **a Turnstile site key is scoped to a list of domains**,
and the widget refuses to render on an origin that is not on it. A
string loaded into a webview has no useful origin — `about:blank`, or a
base URL the app asserts rather than one the browser verified. So the
widget either refuses, or it only works because the key was left
unscoped, which is the protection switched off.

`captcha.html` is served from the same domain as the web app, which is
an origin the key already allows because the web sign-in form uses it.

### Where the phone looks for it

`CAPTCHA_HOST`, a `--dart-define`, defaulting to `https://iakauntan.com`
— the same arrangement as `PRODUCTION_URL`. Nothing in `ci.yml` sets
it, which is correct for this deployment and is the thing to change
first on any other: a mobile build that does not set it points its
sign-in screen at a page on somebody else's domain.

### The iOS-only trap, which cost a release

The webview delegate refuses navigations that leave the host, because a
sign-in screen is the last place to follow one somebody else chose.
Written as `url.startsWith(host)` that guard **shuts every iPhone out
of signing in**, and Android is fine.

Turnstile draws itself in an IFRAME served from
`challenges.cloudflare.com`, and the two plugins disagree about whether
the app is consulted for a subframe:

- `webview_flutter_android` asks only about the main frame, and says why
  in its own source: "the client is only allowed to stop navigations
  that target the main frame because overridden URLs are passed to
  `loadUrl` and `loadUrl` cannot load a subframe."
- `webview_flutter_wkwebview` calls the callback from
  `decidePolicyForNavigationAction` for EVERY navigation action and
  passes `isMainFrame` through rather than acting on it.

So on iOS the guard cancelled Turnstile's own iframe, nothing rendered,
and the form said "The security check could not load, so signing in is
not possible from here" — correctly, about a page with nothing wrong
with it. The guard is `captchaMayNavigate`, it takes `isMainFrame`, and
`captcha_native_test.dart` pins all four cases, because there is no
browser test in CI and running the app on one platform cannot find it.

A subframe is not left unguarded by that: the page's own
Content-Security-Policy decides what it may embed, which is where it
belongs and what `scripts/check_csp_allows.py` asserts.

### And the error handler it exposed

Cancelling that navigation is how WebKit raised `NSURLErrorCancelled`
(-999), and the plugin reports EVERY navigation error through
`didFailProvisionalNavigation` with `isForMainFrame` hardcoded to true
— so the cancelled iframe arrived at the app as a main-frame failure,
which is how a widget that was only being refused ended up reported as
a page that could not load.

That leaves a second fault behind it, independent of the first: -999 is
raised routinely whenever a new `loadRequest` supersedes one in flight,
and that is exactly what `CaptchaController` does when a form has spent
its token and asks for a fresh challenge. Read as a failure it locks
the sign-in form for good. `captchaLoadFailed` names -999 and lets it
pass; Android's own codes run -1 to -16, so nothing collides with it. A
page that genuinely cannot be fetched still fails, because a form that
submits without a token is refused by GoTrue with nothing on the screen
to explain it.

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
