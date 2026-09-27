# Passkeys

A passkey is a key pair the device holds and the screen lock unlocks. The
private half never leaves the phone or the laptop, there is nothing to type,
nothing to remember, and nothing a phishing page can be given — the browser
will only sign for the domain the key was made for, which is the whole
security argument and the reason it is worth the setup below.

None of it works until somebody with a dashboard password does four things,
and a button drawn before they have is a button that fails for everybody who
presses it. That is why all three switches ship **off**.

**Three switches, one per surface** (`0638`). `signin_show_passkey` is the
website's; `signin_show_passkey_android` and `signin_show_passkey_ios` are the
two apps'. They are separate because the three surfaces need three different
things done to them — the dashboard setting below applies to all of them,
Android additionally needs `assetlinks.json`, iOS additionally needs an
entitlement and an `apple-app-site-association` — and those are finished on
different days by different people. One switch would mean the first surface to
be ready turning the button on for the two that are not.

## What is already built

* **The database.** Three columns on the landing page — `signin_show_passkey`
  (`0579`) and `signin_show_passkey_android` / `signin_show_passkey_ios`
  (`0638`) — read into `brand` so the sign-in screen sees them whether or not
  a marketing site has been published.
* **The console.** Platform console → Site pages → Sign-in, three switches.
* **The web.** `passkey_web.dart` calls the browser's own WebAuthn JSON
  converters. Nothing to install.
* **Saving one.** Settings → Your account → Passkeys. Lists what is
  saved, with the authenticator's own name and when it was last used,
  and removes one — a passkey on a laptop that has since been sold is a
  key somebody else is holding, so the list IS the revocation.
* **The phone.** Shipped. `passkey_native.dart` over Corbado's `passkeys`
  plugin, with the web half kept out of the bundle by a local no-op —
  see the section at the bottom, which is the second attempt at this
  and explains what the first one did to production.

The button appears only when all three of these are true: the switch FOR THIS
SURFACE is on, the platform can reach an authenticator, and — the one nobody
can see from the app — passkeys are enabled for the Supabase project. It is
*absent* rather than disabled when any is missing, because a disabled control
invites somebody to work out why and there is nothing they can do about any of
them.

On a phone there is a fourth, and it is the one that cannot be checked before
somebody presses: the domain has to be associated with the build. That is
sections 3 and 4 below. When it is not, `passkey_native.dart` turns the
platform's refusal into a sentence rather than letting it be a button that does
nothing.

## 1. Supabase dashboard

Authentication → **Configuration** → **Passkeys**. Not under Sign In /
Providers, which is where this document sent people at first and is the
wrong menu: passkeys are not a provider, they are a project-level
setting, and they are a BETA feature — the `gotrue` package's own
documentation is the authority on where the switch lives.

`passkey_disabled` is a refusal from GoTrue, not from this app. If the
button still reports it after you have been to Configuration, then the
server still has the feature off — the sign-in screen has no way to
report anything else, and no amount of reloading changes it.

Turn it on and set the relying party ID to the site's own domain — `iakauntan.com`, no scheme, no
path, no port. Until this is done GoTrue answers `passkey_disabled` to every
call and the sign-in screen says so in as many words.

The relying party ID is the identity the key is bound to. Changing it later
invalidates every passkey already enrolled, so pick the domain the product
will still be on in five years. A passkey made for `iakauntan.com` works on
`app.iakauntan.com` and every other subdomain; one made for
`app.iakauntan.com` does not work on the apex.

## How somebody actually saves one

Sign in with a password once, then Settings → Your account → Passkeys →
**Save a passkey**. The device asks for the fingerprint, face or PIN it
already uses, and from then on "Sign in with a passkey" on the sign-in
screen will offer that account.

### Where the passkey is kept is the browser's question, not ours

When the prompt appears, the browser offers wherever it can put one:
**iCloud Keychain / Apple Passwords** on a Mac or iPhone, **Google
Password Manager** on Android and from a desktop Chrome, **a phone by QR
code** — which is the answer for a shared or locked-down desktop — or a
**security key** on USB or NFC.

None of that is this app's decision, and it must not become one. The
first version of `passkeysUsable()` required
`isUserVerifyingPlatformAuthenticatorAvailable()` — "is there a
fingerprint reader on THIS machine" — and drew no button when the answer
was no. That hid all four options from anybody on a desktop without
Touch ID or Windows Hello, including everybody who wanted to save the
passkey to the phone in their pocket. It was reported as the app having
no Apple or Google option, which is exactly what it looked like.

The check now asks only whether the browser can run the ceremony. The
cost is a prompt somebody can cancel on a machine with genuinely nothing
available; the alternative was silently hiding the feature from every
iPhone owner.

The order matters and is not obvious: a passkey can only be created by
somebody already signed in, so the password is not replaced, it becomes
the thing you use on a new device and then stop using. Until somebody
has done this, the sign-in button is a door with nothing behind it —
`startAuthentication` offers whichever accounts hold a passkey for this
site, and that is none of them.

## 2. The console switches

Platform console → Site pages → Sign-in. Three of them:

* **Offer a passkey** — the website. Off until step 1 is done. There is no
  harm in it being on afterwards: a browser with no authenticator still draws
  nothing.
* **Offer a passkey in the Android app** — off until step 1 AND section 3.
* **Offer a passkey in the iOS app** — off until step 1 AND section 4.

Turning one on does not turn the others on, which is the point of there being
three. Turning the website's on when the two association files do not exist
would draw a button in both apps that does nothing at all.

## 3. Android

Credential Manager will not offer a passkey for a domain the app has not
been associated with. The association is a file served by the domain, not
anything in the APK:

`https://iakauntan.com/.well-known/assetlinks.json`

**That file now exists**, at `app/web/.well-known/assetlinks.json`, and
is the authority — read it rather than the shape below, which is only
here to explain the two decisions in it.

```json
[
  {
    "relation": ["delegate_permission/common.get_login_creds"],
    "target": {
      "namespace": "android_app",
      "package_name": "my.iakauntan.iakauntan",
      "sha256_cert_fingerprints": ["<Play signing key>", "<upload key>"]
    }
  }
]
```

**`get_login_creds` and NOT `handle_all_urls`.** The Play Console offers
a ready-made Digital Asset Links snippet and it uses `handle_all_urls` —
App Links, which decides what opens a URL and carries no credentials.
Pasting it verbatim gives a file that looks configured and does nothing
for passkeys. It is the same decision the iOS side already made:
`Runner.entitlements` asks for `webcredentials:` and not `applinks:`,
because applinks would make the app open every link on the site.
Whether App Links is wanted at all is a separate, still-open question.

**A third and fourth certificate exist, and are deliberately not
listed.** Downloading the app signing certificates from the Play
Console gives three files, not one:

| File | Subject | In `assetlinks.json`? |
| --- | --- | --- |
| `deployment_cert.der` | `CN=Android, O=Google Inc.` | **yes** — `20:38:98:…` |
| `hybrid_classical_cert.der` | same | no |
| `hybrid_pqc_cert.der` | same | no |

The last two are Play's hybrid and post-quantum signing certificates.
Only the DEPLOYMENT certificate is listed, because that is the one the
Play Console's own generated Digital Asset Links snippet names — and
that snippet is generated live from the key actually in use, which
makes it a better authority than any reasoning from file names.

Written down because the reasoning is weaker than the rest of this
page: if passkeys ever start failing on Android after a Play signing
change, and nothing in this repository changed, **these two are the
first thing to check**. Adding a fingerprint that is never presented
is harmless; missing one that is fails silently on every affected
device.

**Both fingerprints.** The build signed locally carries the upload key;
the build a tester installs from Play carries Google's Play App Signing
key, which is a different certificate. Listing only the first is the
commonest way this ships broken — it works on the developer's handset
and nowhere else. The upload key also comes out of the Android release
job summary, and `keytool -list -v -keystore upload.jks -alias upload`
prints it locally; Google's half only exists in the Play Console, on
the app signing page (`.../app/<id>/keymanagement` — Google has moved
what that page is CALLED twice, and the URL has outlasted both names).

Served as `application/json`, over HTTPS, with no redirect. Android fetches
it directly and a 301 to `www.` is a failure.

## 4. iOS

Two halves, and both are needed.

**The app side** is an Associated Domains entitlement containing
`webcredentials:iakauntan.com`. The Runner target has no entitlements file
today, so this is an Xcode step rather than a commit: Signing & Capabilities
→ + Capability → Associated Domains. It cannot usefully be added here
because the file has to be referenced from the target's build settings and
signed against a team this repository does not have.

**The domain side** is `https://iakauntan.com/.well-known/apple-app-site-association`
— no extension, served as `application/json`:

```json
{ "webcredentials": { "apps": ["<TEAMID>.my.iakauntan.iakauntan"] } }
```

Apple fetches this through a CDN that caches aggressively, so a corrected
file can take a day to take effect. Appending `?mode=developer` to the
associated domain during development bypasses the cache; it must not ship.

## 5. Serving the two files

Both live under `/.well-known/` on the same origin as the site. Flutter
copies anything in `app/web/` into the build, so `app/web/.well-known/` is
where they go.

**The Content-Type is already arranged.** `deploy/vercel-output-config.json`
serves both paths as `application/json`. That route is in place ahead of the
files, because `apple-app-site-association` has no extension and a static host
serves it as `text/plain` by default, which Apple rejects — a correct file
served with the wrong type fails in a way that looks identical to a wrong
file, and Apple's CDN then caches the failure for about a day.

**`apple-app-site-association` is now in this repository**, at
`app/web/.well-known/`, carrying team ID `ZFEYTFLA74` and bundle
`my.iakauntan.iakauntan`. Flutter copies it into the build: the web resource
loop in `flutter_tools/lib/src/build_system/targets/web.dart` walks `web/`
recursively with no filter on dot-directories, which was checked in the SDK
source rather than assumed, because a file that is silently not deployed is
the same failure as a file that is wrong.

**`assetlinks.json` is now written**, at
`app/web/.well-known/assetlinks.json`, carrying both fingerprints:

* the **Play App Signing** certificate, `20:38:98:4F:…`, which is the
  key Google holds and re-signs with — what an app installed from Play
  actually presents;
* the **upload key**, `19:50:C0:81:…`, which is what the release
  workflow signs with and what a directly installed build presents.

Both, because they are different keys and a device presents whichever
one installed it. A file with only the upload key works on the
developer's own handset and on nothing that came from Play, which is
the failure this page is mostly about.

The relation is **`get_login_creds`, not `handle_all_urls`**. The Play
Console offers a ready-made Digital Asset Links snippet and that
snippet uses `handle_all_urls` — App Links, which decides what opens a
URL and carries no credentials at all. Pasting it verbatim produces a
file that looks configured and does nothing for passkeys. It is also
the same decision the iOS side already made deliberately:
`Runner.entitlements` asks for `webcredentials:` and not `applinks:`,
because applinks would make the app open every link on the site.

Whether App Links is wanted at all is still open, and is a separate
question from this file working.

`scripts/check_passkey_association.py` enforces that rather than leaving it
advisory. Absent is allowed; present and wrong is refused, including a
placeholder, a team ID of the wrong shape, a bundle or package this
repository does not build, `applinks` where `webcredentials` was meant, and
an `assetlinks.json` carrying ONE fingerprint — which is usually the upload
key alone and works on no device that installed from Play.

**The iOS entitlement is in the repository too**, at
`app/ios/Runner/Runner.entitlements`, wired into all three Runner build
configurations. It has a prerequisite this repository cannot satisfy: the App
ID `my.iakauntan.iakauntan` must have the Associated Domains capability
enabled in the Apple Developer portal, or the SIGNED build fails at signing.
CI does not catch that — `ci.yml` builds iOS with `--no-codesign`.

## When it does not work

On a phone, the failure is almost always the association, and it presents as
a button that does nothing. The app says "This app is not set up for
passkeys on this system yet" rather than staying silent, which is what
`PasskeyFailure` exists for.

A debug build goes further: the `passkeys` plugin's doctor runs only when
`debugMode` is set, which is `kDebugMode` here, and it fetches the two files
above and prints what it found wrong with them. A release build makes no
such call.

## How the phone was done, and what the first attempt did

The route is the `passkeys` plugin (Corbado) — there is no other. A WebAuthn
ceremony on a phone needs a platform plugin: Android's Credential Manager and
iOS's `ASAuthorization` are native APIs, and a webview cannot stand in for
them the way `captcha.html` does for Turnstile.

It was added once before. It worked, and it white-screened production the
moment it deployed. The reason is worth writing down, because nothing about it
is visible from the pub page, from `flutter analyze`, or from a successful
`flutter build web`.

`passkeys` declares a **web** implementation, `passkeys_web`. Flutter
generates `web_plugin_registrant.dart` from the platform declarations of
every package in the tree, so adding the plugin for Android and iOS
silently enrols `passkeys_web` into the web bundle as well — there is no
per-platform dependency in `pubspec.yaml` and nothing asks whether you
wanted it.

`PasskeysWeb.registerWith` then runs inside `registerPlugins()`, which
runs **before `runApp`**, and its last line is an unconditional call to:

```dart
@JS('PasskeyAuthenticator.init')
external void init();
```

`PasskeyAuthenticator` is a global that exists only if you have manually
included Corbado's `bundle.js` in `index.html`. This app does not, and
`script-src 'self'` in `deploy/vercel-output-config.json` would refuse to
load it if it tried. So `init()` throws during bootstrap, `main()` never
finishes, and every page of the app is a white screen — the landing page
included, which has nothing to do with passkeys.

The guard immediately above it does not help. It reads
`window['PasskeyAuthenticator']`, which returns null rather than throwing
for a missing global, so the `catch` never fires; the `window.close()`
inside it is never even reached, and would be a no-op on a tab the script
did not open anyway.

None of the local gates catch this. `flutter build web` compiles it
happily — the failure is a missing JS global at runtime, in a browser.

### What the second attempt did

`dependency_overrides` points `passkeys_web` at
`app/packages/passkeys_web`, a local package that implements
`PasskeysPlatform`, registers, and does nothing else. The web half of this app
has never needed the plugin — it calls the browser's own WebAuthn through
`passkey_web.dart` — so a no-op there loses nothing.

**The override does not remove the name from the generated registrant, and
the first version of the tripwire was wrong about that.** `passkeys` federates
by `default_package`, so Flutter emits
`import 'package:passkeys_web/passkeys_web.dart';` and
`PasskeysWeb.registerWith(registrar)` whichever package that turns out to be.
The override changes what the name RESOLVES to, and the generated file is
identical either way. A check on the name is both wrong answers at once: it
refuses a bundle that is safe, and it would pass one that is not if the plugin
were ever reached under a different name.

What decides is `.dart_tool/package_config.json`, which records where `pub`
put each package. That is what the tripwire reads now — and it also reads the
local package's source and refuses it if it has grown any JS, because an
override pointing at a path is only as good as what is at the path.

The sentence that used to be here — "the test that would have caught this is
the one to write first: build for web and assert the registrant does not
mention `passkeys_web`" — is the test that was written, and it gave the wrong
answer the day the plugin came back.

### The two gates

**The tripwire.** `scripts/check_web_plugin_registrant.py` runs
in the Flutter job on every commit, and it asks the question one step
earlier than the sentence above: the generated registrant only exists
after a web build, which in this repository happens in the deploy job —
so a check on it fires where the white screen already fired. The check
fires instead on the commit that ADDS the plugin. If `passkeys` is a
dependency, `dependency_overrides` must point `passkeys_web` at a local
`path:`, and a version override is refused because a version override is
still the real implementation.

It reads the generated registrant as well, when a local `flutter build
web` has left one, and says which of the two answers it gave — a check
that reports success for a file it never found is how a gate stops
meaning anything.

Verified against five states: the plugin with no override (the commit that
broke production), with a version override (the near miss), with a local
package that is not a no-op, with the registrant resolving to the published
`passkeys_web`, and the supported arrangement. It refuses the first four and
passes the fifth.

**And the general answer.** `scripts/check_web_boots.py` opens the built
bundle in a real browser and asks whether Flutter drew anything:

```
cd app && flutter build web --release
python3 scripts/check_web_boots.py
```

It needs a Chromium (`CHROME=`, default the Playwright one) and
`websocket-client`. It serves the SDK's own CanvasKit beside a copy of the
build, because a release bundle otherwise fetches it from `gstatic.com` and a
network that refuses that gives a blank page for a reason that is not the
code — the first version of this check reported a white screen on a bundle
that was fine. Network errors from the app's own back end are ignored; an
uncaught exception is not.

It is not in CI: it needs a web build, which happens only in the deploy job,
which is where the white screen already fired. It is the check to run by hand
before adding any plugin. Verified by injecting a throwing statement into the
bootstrap and watching it refuse, then removing it and watching it pass.
