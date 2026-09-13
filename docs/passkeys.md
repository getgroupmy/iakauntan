# Passkeys

A passkey is a key pair the device holds and the screen lock unlocks. The
private half never leaves the phone or the laptop, there is nothing to type,
nothing to remember, and nothing a phishing page can be given — the browser
will only sign for the domain the key was made for, which is the whole
security argument and the reason it is worth the setup below.

None of it works until somebody with a dashboard password does four things,
and a button drawn before they have is a button that fails for everybody who
presses it. That is why `signin_show_passkey` ships **off**.

## What is already built

* **The database.** `signin_show_passkey` is a column on the landing page,
  read into `brand` so the sign-in screen sees it whether or not a marketing
  site has been published. Migration `0579`.
* **The console.** Platform console → Site pages → "Offer a passkey".
* **The web.** `passkey_web.dart` calls the browser's own WebAuthn JSON
  converters. Nothing to install.
* **The phone.** NOT SHIPPED. See the section at the bottom — the obvious
  plugin cannot be added to this app without taking the web build down
  with it, and it did.

The button appears only when all three of these are true: the switch is on,
the platform can reach an authenticator, and — the one nobody can see from
the app — passkeys are enabled for the Supabase project. It is *absent*
rather than disabled when any is missing, because a disabled control invites
somebody to work out why and there is nothing they can do about any of them.

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

## 2. The console switch

Platform console → Site pages → Sign-in → **Offer a passkey**. Off until
step 1 is done. There is no harm in it being on afterwards: a browser with
no authenticator still draws nothing.

## 3. Android

Credential Manager will not offer a passkey for a domain the app has not
been associated with. The association is a file served by the domain, not
anything in the APK:

`https://iakauntan.com/.well-known/assetlinks.json`

```json
[
  {
    "relation": ["delegate_permission/common.handle_all_urls",
                 "delegate_permission/common.get_login_creds"],
    "target": {
      "namespace": "android_app",
      "package_name": "my.iakauntan.iakauntan",
      "sha256_cert_fingerprints": ["<upload key>", "<Play signing key>"]
    }
  }
]
```

`get_login_creds` is the relation that matters; an `assetlinks.json` written
for deep links alone has only the first and passkeys will fail on it.

**Both fingerprints.** The build signed locally carries the upload key; the
build a tester installs from Play carries Google's Play App Signing key,
which is a different certificate. Listing only the first is the commonest
way this ships broken — it works on the developer's handset and nowhere
else. Play Console → Setup → App signing has both.

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
where they go — with `vercel-output-config.json` given a `Content-Type` of
`application/json` for both, since neither has a `.json` extension in the
iOS case and a static host will otherwise serve it as `text/plain`, which
Apple rejects.

## When it does not work

On a phone, the failure is almost always the association, and it presents as
a button that does nothing. The app says "This app is not set up for
passkeys on this system yet" rather than staying silent, which is what
`PasskeyFailure` exists for.

A debug build goes further: the `passkeys` plugin's doctor runs only when
`debugMode` is set, which is `kDebugMode` here, and it fetches the two files
above and prints what it found wrong with them. A release build makes no
such call.

## Why the phone is still not done

The obvious route is the `passkeys` plugin (Corbado). It was added, it
worked, and it white-screened production the moment it deployed. The
reason is worth writing down, because nothing about it is visible from
the pub page, from `flutter analyze`, or from a successful
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

### What a second attempt has to do

Keep `passkeys_web` out of the bundle. The supportable way is a
`dependency_overrides` entry pointing `passkeys_web` at a local no-op
package that implements `PasskeysPlatform` and registers without touching
any JS. The web half of this app has never needed the plugin — it calls
the browser's own WebAuthn through `passkey_web.dart` — so a no-op there
loses nothing.

Whatever the approach, the test that would have caught this is the one to
write first: build for web and assert that
`.dart_tool/flutter_build/*/web_plugin_registrant.dart` does not mention
`passkeys_web`.
