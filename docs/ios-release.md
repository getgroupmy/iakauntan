# Releasing the iOS app from the console

**Mobile Application → Release the iOS app.** Pick TestFlight or App
Store, press the button, and a Mac builds the app and hands it to Apple.

This page is what has to exist first, and what the button can and
cannot do.

## The one constraint everything here follows from

**Xcode runs on Apple hardware and nowhere else.** Neither Supabase nor
Vercel — the two places this application's server code lives — can
compile an iOS app. So the console does not build anything. It asks a
machine that can:

```
Console button
  → supabase/functions/ios-release   (holds the GitHub token)
  → .github/workflows/ios-release.yml  (runs on macos-latest)
  → fastlane-free xcodebuild + altool
  → App Store Connect
```

A GitHub Actions macOS runner rather than Codemagic or EAS, chosen
because CI is already GitHub Actions and already builds iOS — this is a
second workflow rather than a second vendor, and a second vendor would
mean a second place the signing certificate lives.

**It bills at ten times an Ubuntu runner.** An archive is twenty to
thirty minutes, so a release costs a few hundred Linux-equivalent
minutes. That is why the button asks before it starts, and why
`ci.yml`'s ordinary iOS job is gated behind "did anything native
change".

## What no button can do

**Skip App Review.**

* **TestFlight** — the build reaches your own testers, usually within
  minutes of Apple finishing processing. Nothing waits on a reviewer.
* **App Store** — the build is uploaded and is then ready to submit.
  Review takes hours to days and is Apple's. Whether an approved build
  goes live by itself is a setting in App Store Connect, not here.

The console's copy says this in both places, and
`app/test/ios_release_card_test.dart` asserts that the App Store lane's
sentence mentions review — because a screen that implied the button
ships the app would be the one thing here that could actually mislead
somebody.

## What has to exist before the button works

The workflow checks its secrets first and stops with a list of the
missing ones. It does not fail: a release nobody has set up yet is not
a broken build.

### In the Apple developer account

| | |
| --- | --- |
| Apple Developer Program | US$99 a year. Everything below needs it. |
| App ID | `my.iakauntan.iakauntan`, with **Push Notifications** and **Associated Domains** enabled — see `docs/push-notifications.md` and `docs/passkeys.md` |
| App record | Created in App Store Connect against that bundle identifier |
| Distribution certificate | Apple Distribution, exported as a `.p12` with a password |
| Provisioning profile | An **App Store** profile for that App ID |
| App Store Connect API key | Users and Access → Integrations → App Store Connect API. Gives an Issuer ID, a Key ID and a `.p8` that downloads once |

### In this repository's Actions secrets

Settings → Secrets and variables → Actions.

| Name | What it is |
| --- | --- |
| `IOS_DIST_CERT_P12` | `base64 -i dist.p12` |
| `IOS_DIST_CERT_PASSWORD` | the password that `.p12` was exported with |
| `IOS_PROVISIONING_PROFILE` | `base64 -i profile.mobileprovision` |
| `APP_STORE_CONNECT_KEY_ID` | the 10-character Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | the issuer UUID |
| `APP_STORE_CONNECT_KEY_P8` | the whole `AuthKey_XXXXXXXXXX.p8`, including its BEGIN and END lines |

### In the Supabase function secrets

| Name | What it is |
| --- | --- |
| `GITHUB_RELEASE_TOKEN` | a fine-grained PAT with **Actions: read and write** on this repository and nothing else |
| `GITHUB_REPOSITORY` | `owner/name` |
| `GITHUB_RELEASE_REF` | optional; the branch to build. Defaults to `main` |

**The console never sees any of the Apple secrets.** It holds nothing:
it calls the function with the operator's own session, the function
checks `am_i_platform_admin()` through that same session, and only then
uses the token. The signing certificate and the App Store key are read
by a job running on GitHub's runner and by nothing else — the same
posture `APNS_KEY_P8` has.

## Two things that go wrong, and what they look like

**The profile is for the wrong bundle identifier.** The commonest
signing failure by a distance, and normally it surfaces as an Xcode
error about a mismatch deep in a log. The workflow reads the
`application-identifier` out of the profile before it builds and stops
with a sentence naming what it found.

**The build number repeats.** App Store Connect refuses a build number
it has seen for a version. The workflow uses `github.run_number`, which
is the only counter here that never goes backwards — so the marketing
version stays in `pubspec.yaml`, where somebody sets it deliberately,
and the build number looks after itself. A `concurrency` group of one
keeps two releases from racing for it.

## Where the audit trail is

There is no table. The card reads GitHub's run list through the
function, so what it shows is what actually happened — including a
build somebody started by hand from the Actions tab, and one that
failed to start at all. A row written here when the button was pressed
would be this application's opinion of what happened, which is a
different thing.

Each row links to its log.
