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

The console says the same thing in the same way. Before
`GITHUB_RELEASE_TOKEN` exists, the function answers 503 with a
sentence, the card draws **Not set up yet** with that sentence under
it, and the button is off. It is not an error state and does not
pretend to be one — `app/test/ios_release_card_test.dart` asserts that
503 is the only status treated that way, because a 403 is a person
without the right to release and a 502 is GitHub being unreachable,
and neither is fixed by adding a secret.

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

## Setting it up, step by step

Four parts. **Part 1 alone makes the card work** — it lists builds and
lights the button. Parts 2 and 3 are what a build actually needs, and
they are the slow ones because Apple is involved. Part 4 is pressing
it.

Nothing here is reversible in the sense of being wasted: every secret
below is re-creatable, and every one of them can be replaced later
without touching this repository.

### Part 1 — two secrets, and the card works (10 minutes)

**1.1 Make a GitHub token.**

GitHub → your avatar → **Settings** → **Developer settings** →
**Personal access tokens** → **Fine-grained tokens** → **Generate new
token**.

| Field | What to put |
| --- | --- |
| Token name | `iakauntan ios release` |
| Expiration | your choice; a year is usual. It has to be replaced when it expires, and the card will say 502 when it does |
| Resource owner | **`getgroupmy`** — not your personal account |
| Repository access | **Only select repositories** → `getgroupmy/iakauntan` |
| Permissions → Repository permissions → **Actions** | **Read and write** |

Nothing else. `Metadata: Read-only` switches itself on and is required;
leave it. Generate, and copy the `github_pat_…` string — GitHub shows
it once.

> If `getgroupmy` is an organization with fine-grained tokens
> restricted, the token is created in a *pending* state and an owner
> has to approve it. Until then every call answers 403 and the card
> says so. Organization settings → Personal access tokens → Pending
> requests.

**1.2 Put it in Supabase.**

Supabase dashboard → the project → **Edge Functions** → **Secrets**
(older dashboards: Project Settings → Edge Functions → Secrets) → **Add
new secret**, twice:

| Name | Value |
| --- | --- |
| `GITHUB_RELEASE_TOKEN` | the `github_pat_…` string |
| `GITHUB_REPOSITORY` | `getgroupmy/iakauntan` |

Optionally a third, `GITHUB_RELEASE_REF`, naming the branch to build.
It defaults to `main`, so set it if you want releases cut from
somewhere else.

**1.3 Check.** Reload Mobile Application in the console. "Not set up
yet" becomes either a list of runs or **Nothing yet** — both mean it is
working — and **Start the build** stops being greyed out.

Pressing it now will start a workflow that stops politely with a list
of the Apple secrets it still needs. That is a legitimate way to check
Part 1 without doing Part 2 first, and it costs about a minute of
runner time.

### Part 2 — Apple, once (the slow part)

**2.1 Apple Developer Program**, US$99 a year, at
developer.apple.com/programs. Everything below needs the membership
active. An organization membership needs a D-U-N-S number and takes
days; an individual one is usually same-day.

**2.2 The App ID.** developer.apple.com → **Certificates, Identifiers &
Profiles** → **Identifiers** → **+** → App IDs → App.

* Bundle ID: **Explicit**, `my.iakauntan.iakauntan` — exactly this. The
  workflow reads the bundle ID out of the profile and refuses anything
  else, because a profile for the wrong identifier is the commonest
  signing failure there is.
* Capabilities: tick **Push Notifications** and **Associated Domains**.
  Neither is needed to build, both are needed for features already
  written — see `docs/push-notifications.md` and `docs/passkeys.md`.

**2.3 The app record.** appstoreconnect.apple.com → **My Apps** → **+**
→ **New App**. Platform iOS, pick the bundle ID from 2.2, give it a
name and an SKU (any string you will recognise). Without this record
the upload is rejected with a message about the app not existing.

**2.4 The distribution certificate.** This is the one that normally
wants a Mac. It does not have to.

*First, on a Mac, ask whether this is needed at all:*

```bash
security find-identity -v -p codesigning
```

If a line names `Apple Distribution: <your company>`, the account
already has a certificate AND this machine already has its private
key. Skip everything below: Keychain Access → **login** → **My
Certificates** → find that row → it must expand to show a private key
under it → right-click → **Export** → Personal Information Exchange
(`.p12`) → set a password, which is `IOS_DIST_CERT_PASSWORD`. It then
asks for the Mac login password to unlock the keychain; that is a
different thing and is not the secret.

That path uses the certificate the account already has and consumes
none of the two Apple Distribution slots. Only make a new certificate
when it finds nothing.

> **Downloading the existing certificate from the portal is NOT the
> same thing** and is the trap here. The `.cer` Apple serves is the
> public half; the private half was only ever on the machine that made
> the request. Pairing a downloaded `.cer` with a freshly generated
> key gives `No certificate matches private key`, and the giveaway is
> the certificate's `notBefore` date being older than the CSR —
> `openssl x509 -in dist.pem -noout -subject -dates` shows both.

*Otherwise, on a Mac:* Keychain Access → Certificate Assistant →
**Request a Certificate From a Certificate Authority**, save to disk.
Then
developer.apple.com → Certificates → **+** → **Apple Distribution** →
upload the CSR → download the `.cer` → double-click to install →
find it in Keychain Access under **My Certificates** → right-click →
**Export** → `.p12`, and set a password. Remember the password.

*Anywhere with `openssl` — macOS, Linux, WSL, a container, a cloud
shell.* This works on a Mac too, and is fewer steps than Keychain
Access.

> **These are THREE steps with Apple in the middle, not one block to
> paste.** The `.cer` in step (c) does not exist until Apple has been
> given the CSR from step (a), so pasting all of it at once fails the
> last two commands with `No such file or directory` — correctly, and
> after the first two have already succeeded.
>
> Do not mark the middle step with a `#` comment line either. **zsh
> does not treat `#` as a comment interactively** (`interactive_comments`
> is off by default), so a pasted comment runs as a command and
> answers `zsh: command not found: #`. That is noise in the middle of
> real output, and it is how this gets misread as the whole thing
> having failed.

**(a)** Make the key and the signing request:

```bash
[ -f dist.key ] || openssl genrsa -out dist.key 2048
openssl req -new -key dist.key -out dist.csr \
  -subj "/emailAddress=you@example.com/CN=iAkauntan/C=MY"
```

**The `[ -f dist.key ] ||` is not decoration.** It means "only if the
key does not already exist", and it is there because running this
block a second time is the one mistake that cannot be undone from
here. A fresh `dist.key` does not match a certificate Apple already
issued against the old one, the old key is gone, and the only way out
is a whole new certificate. Regenerating the CSR from an existing key
is harmless — same key, same public half — so the guard belongs on
that line and nowhere else.

Put your own address in, or don't. Apple ignores the subject and
issues the certificate with one of its own, so nothing depends on it.

**(b)** **Stop here and go to Apple.** developer.apple.com →
Certificates, Identifiers & Profiles → **Certificates** → **+** →
**Apple Distribution** → Continue → Choose File → `dist.csr` →
Continue → **Download**. That gives you `distribution.cer`.

**(c)** Convert it and pair it with the key you kept:

```bash
openssl x509 -in distribution.cer -inform DER -out dist.pem -outform PEM
openssl pkcs12 -export -inkey dist.key -in dist.pem -out dist.p12
```

It asks for an export password twice. That password is
`IOS_DIST_CERT_PASSWORD` below. **Keep `dist.key`** — losing it means
revoking the certificate and starting 2.4 again.

> **`-legacy` is an OpenSSL 3 flag and macOS does not have it.** macOS
> ships LibreSSL, which writes the older format the runner wants
> anyway; adding `-legacy` there is an error, not a fix. On Linux with
> OpenSSL 3, if the runner later fails to import the `.p12`, re-export
> with `-legacy` added to the `pkcs12` line. Check which you have with
> `openssl version`.

**2.5 The provisioning profile.** developer.apple.com → **Profiles** →
**+** → Distribution → **App Store Connect** → App ID from 2.2 →
certificate from 2.4 → name it → **Download**. You get a
`.mobileprovision` file.

This is the piece that has to be re-made whenever the certificate
changes, and it expires after a year.

**2.6 The App Store Connect API key.** appstoreconnect.apple.com →
**Users and Access** → **Integrations** → **App Store Connect API** →
**Team Keys** → **+**.

* Name it, Access: **App Manager**.
* Generate. The page then shows an **Issuer ID** (a UUID, at the top of
  the list) and a **Key ID** (10 characters).
* Download `AuthKey_XXXXXXXXXX.p8`. **It downloads exactly once.** If
  you lose it, revoke the key and make another.

### Part 3 — six secrets in GitHub Actions

`github.com/getgroupmy/iakauntan` → **Settings** → **Secrets and
variables** → **Actions** → **New repository secret**, six times.

Two of them are base64 of a binary file, and one is a text file pasted
whole. Getting that distinction wrong is the likeliest mistake in this
whole page.

| Secret | Value | How |
| --- | --- | --- |
| `IOS_DIST_CERT_P12` | base64 of `dist.p12` | `base64 -i dist.p12 \| tr -d '\n' \| pbcopy` (macOS) or `base64 -w0 dist.p12` (Linux) |
| `IOS_DIST_CERT_PASSWORD` | the password from 2.4 | as typed |
| `IOS_PROVISIONING_PROFILE` | base64 of the `.mobileprovision` | the same command, on that file |
| `APP_STORE_CONNECT_KEY_ID` | the 10-character Key ID | as shown |
| `APP_STORE_CONNECT_ISSUER_ID` | the issuer UUID | as shown |
| `APP_STORE_CONNECT_KEY_P8` | **the `.p8` file's text, NOT base64** | macOS: `pbcopy < AuthKey_XXXXXXXXXX.p8`. Otherwise `cat` it and paste all of it, including the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines |

**The wrapping is what catches people.** `base64` without `-w0` on
Linux wraps at 76 characters, and those newlines make the decode fail
on the runner. macOS has **no `-w` option at all** — `base64 -w0`
there answers `invalid option -- w` — so the `tr -d '\n'` above is the
portable way to say the same thing, and is harmless where nothing
wrapped.

Two commands that check the values before they go anywhere:

```bash
# one very long line, no spaces, no newlines
base64 -i dist.p12 | tr -d '\n' | wc -l     # prints 0
# and the .p8 keeps its newlines — this one prints 3 or more
wc -l < AuthKey_XXXXXXXXXX.p8
```

### Part 4 — press it

Console → **Mobile Application** → **Release the iOS app** → pick a
lane → **Start the build** → confirm.

Twenty to thirty minutes. The card polls, and each row links to its
log.

**The two lanes upload the same thing.** Both export with
`method: app-store` and both call `xcrun altool --upload-app`; the lane
changes only what the run summary says. That is not a shortcut being
taken — a TestFlight build and an App Store build ARE the same binary
in the same place. What differs is what you do in App Store Connect
afterwards: leave it for your testers, or add it to a version and
submit it. **Neither lane submits for review**, and nothing here could.

### When it goes wrong

| What you see | What it is |
| --- | --- |
| Card: "Not set up yet" | Part 1 is not done, or the token expired |
| Card: "GitHub answered 403" | the token lacks **Actions: read and write**, or an org owner has not approved it |
| Card: "GitHub answered 404" | `GITHUB_REPOSITORY` is wrong, or the token cannot see that repository |
| Run summary: "Not set up yet" with a list | those Actions secrets are missing. The run is green because nothing failed |
| `The profile is for X, not my.iakauntan.iakauntan` | the profile in 2.5 was made against the wrong App ID |
| `security import` fails | the `.p12` base64 wrapped (Linux needs `-w0`; macOS `base64 -i` does not wrap), or the password is wrong, or OpenSSL 3 on Linux needs `-legacy` — LibreSSL on macOS does not and rejects the flag |
| Upload rejected, app not found | 2.3 was skipped |
| `Error opening Certificate distribution.cer` | step (b) has not been done yet — the file comes back FROM Apple |
| `No certificate matches private key` | the `.cer` was not issued from THIS `dist.csr`. Either an existing certificate was downloaded instead of a new one being created from the CSR — check the subject says `Apple Distribution:` and not `Apple Development` — or `dist.key` was regenerated after the upload. Compare timestamps: a `dist.key` NEWER than `dist.csr` means the key was replaced and is unrecoverable; equal timestamps mean the key is fine and only the certificate is wrong. Confirm either way with the two `-modulus` commands below |
| `dist.p12` exists but is 0 bytes | a failed `pkcs12 -export` still creates its output file. It looks present to `ls` and is empty. Delete it, or it passes for done |
| `zsh: command not found: #` | a `#` comment line was pasted; zsh does not honour them interactively. Harmless, and it means the block was pasted whole |

**To tell whether a key and a certificate are a pair**, compare their
public halves. Same digest, same pair:

```bash
openssl rsa  -in dist.key -noout -modulus | openssl md5
openssl x509 -in dist.pem -noout -modulus | openssl md5
```

Different digests mean the key that matches the certificate no longer
exists. Apple cannot re-issue against a key it never had, so the fix
is a new certificate: revoke the unusable one at developer.apple.com
(it is useless without its key, and Apple Distribution is limited to
two), then do (a), (b) and (c) again — once.
| Upload rejected, duplicate build number | should not happen — `github.run_number` never repeats — unless a build was uploaded by hand with a number above it |


## Two things that go wrong, and what they look like

**The profile is for the wrong bundle identifier.** The commonest
signing failure by a distance, and normally it surfaces as an Xcode
error about a mismatch deep in a log. The workflow reads the
`application-identifier` out of the profile before it builds and stops
with a sentence naming what it found.

**The console shows a raw `FunctionException`.** It did once, and the
cause is worth knowing if anything else here starts talking to an edge
function: `functions.invoke` **throws** `FunctionException` on a
non-2xx answer. It does not return a response with a status to check.
Code shaped like

    final res = await client.functions.invoke('...');
    if (res.status >= 400) { ... }

is a branch that never runs, and whatever was inside it never happens.
`ssm_search_service.dart` had this right first; `repository.dart` now
catches, and the assertions live in `ios_release_card_test.dart`.

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
