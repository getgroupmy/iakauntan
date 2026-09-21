# Releasing the Android app

**Actions → Android release → Run workflow.** Pick a track, press the
button, and a runner builds the app bundle and hands it to Google Play.

The counterpart of `docs/ios-release.md`, and worth reading alongside
it: the workflow is deliberately the same shape, so the parts that are
genuinely different are the parts worth your attention.

## Where this stands

**Nothing is set up yet.** The workflow, the signing configuration and
the upload script are written and gated; the five secrets are not
there, and until they are the workflow stops with a list of which are
missing rather than failing.

Unlike the iOS side, **none of this has ever run**. The iOS pipeline
took four failed runs to find two real traps. Expect the same here and
budget for it — though at a tenth the cost per attempt, because this
runs on Ubuntu.

## Three ways this is not the iOS release

**It runs on Ubuntu, not macOS.** Nothing in an Android build needs
Apple hardware. The iOS release bills at ten times an Ubuntu runner and
takes twenty-five minutes; this is about eight. The warning in
`docs/ios-release.md` about pressing the button carelessly does not
really apply.

**Play will not take the first bundle from the API.** The Publishing
API cannot create an app, and refuses the first upload for one that has
never had a release. That upload goes through the Play Console by hand,
once, and every upload after it can come from here.
`scripts/play_upload.ts` recognises the refusal and says so in those
words, because Google's own message talks about draft releases and
gives no hint that the answer is in a browser.

**The upload key cannot be replaced.** An Apple distribution
certificate that leaks is revoked and reissued in an afternoon. An
Android upload key is bound to the app by Play and can only be reset by
asking Google. Everything below treats the keystore accordingly: it is
written outside the checkout, gitignored twice over, and deleted at the
end of the job whatever happened.

## Part 1 — the upload key

Once, on any machine with a JDK. **Keep the file and the passwords**;
losing them means asking Google to reset the key.

```
keytool -genkey -v -keystore upload.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias upload
```

It asks for a password twice and then for a name and organisation. The
name goes in the certificate and is not shown to anybody installing the
app; the organisation is worth getting right.

Then, for the secret:

```
base64 -i upload.jks | tr -d '\n' | pbcopy
```

`base64 -i FILE` rather than `base64 -w0`: **macOS has no `-w`** and
answers `invalid option -- w`. That cost an evening on the iOS side.

## Part 2 — the Play service account

Two screens in two different products, and doing only the first is the
most common way this fails.

1. **Google Cloud Console** → the project linked to your Play
   developer account → *IAM & Admin* → *Service Accounts* → create one
   → *Keys* → *Add key* → *JSON*. That downloaded file, whole, braces
   included, is `PLAY_SERVICE_ACCOUNT`.
2. **Play Console** → *Users and permissions* → *Invite new users* →
   the service account's email address → give it **Release** access to
   this app.

Step 2 is a separate invitation in a separate product and is easy to
miss. `play_upload.ts` names it explicitly when Play answers 403,
because the raw message says only "the caller does not have
permission", which reads like step 1.

## Part 3 — the first upload, by hand

**Play Console** → create the app if it does not exist → build a
bundle locally and upload it through *Release → Testing → Internal
testing*.

```
cd app
flutter build appbundle --release --build-number=1
```

That needs `android/key.properties` pointing at your keystore — the
same four lines the workflow writes, in `docs/` terms:

```
storeFile=/absolute/path/to/upload.jks
storePassword=...
keyAlias=upload
keyPassword=...
```

The file is gitignored twice, here and at the repository root. Check
that `git status` does not show it before committing anything.

**Note the version code you used.** It matters in part 5.

## Part 4 — the five secrets

**Settings → Secrets and variables → Actions → New repository secret.**

| Secret | What it is |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | the keystore from part 1, base64, one line |
| `ANDROID_KEYSTORE_PASSWORD` | the password you typed twice |
| `ANDROID_KEY_ALIAS` | `upload`, unless you chose another |
| `ANDROID_KEY_PASSWORD` | the key password — usually the same as the store password |
| `PLAY_SERVICE_ACCOUNT` | the whole service account JSON from part 2 |

## Part 5 — the version code offset

**Settings → Secrets and variables → Actions → Variables →
`ANDROID_VERSION_CODE_OFFSET`.**

The workflow's version code is its run number plus this. Play refuses a
code it has seen, and run numbers start at 1 — so if part 3 uploaded
code 1, run 1 would collide with it. Set this to the highest code Play
has already seen.

Leave it unset and it is 0, which is right only if nothing was ever
uploaded by hand — which cannot be the case, because part 3 is
mandatory.

## After that

Actions → Android release → Run workflow → pick a track.

`internal` is the default and the equivalent of TestFlight: it reaches
the testers you list, without review. `production` rolls out to
everybody and still waits on Play's own review, which is hours to days
whatever this workflow does.

**The job summary prints the upload key's SHA-256.** That is not a
courtesy — `docs/passkeys.md` has been waiting on exactly that
fingerprint for `assetlinks.json`, and it is otherwise awkward to get
back out of a keystore. A certificate fingerprint is public by design,
so printing it into a summary is safe. You will also need the **Play
App Signing** certificate's fingerprint, which is a different key and
lives in *Play Console → Setup → App signing*; `assetlinks.json` needs
both, and one alone works on the developer's handset and nowhere else.

## What no button can do

**Skip Play review.** Internal testing is exempt; every other track is
not.

**Create the app.** Part 3 exists because of this.

**Recover a lost upload key.** Only Google can.

## When it goes wrong

| It says | What it means |
| --- | --- |
| "Not set up yet" with a list | exactly that; the secrets in part 4 are missing and nothing was built |
| "Google Play has no released version of this app yet" | part 3 has not been done |
| "The service account cannot see this app" | part 2 step 2 — the Play Console invitation, not the Cloud IAM role |
| "Play has seen this version code before" | part 5; raise `ANDROID_VERSION_CODE_OFFSET` |
| "The bundle is signed with the DEBUG key" | `key.properties` did not take effect. Caught BEFORE the upload on purpose — a debug-signed bundle is otherwise refused by Play after it |
| "Play refused the signature" | the keystore is not the one this app is registered to |
| the run is green and testers see nothing | check the track. An internal release reaches only the testers listed on that track in the console |

## Why not fastlane

The usual answer to this problem is fastlane, and it is a good tool.
`scripts/play_upload.ts` is about a hundred lines instead, for the
reason `ios-release.yml` calls `xcodebuild` directly rather than
`gym`: a second toolchain is a second place the signing key lives, and
a second thing to keep current.

It reuses `supabase/functions/_shared/google_auth.ts`, which already
turns a service account into an access token for Document AI and FCM
and has its own tests. The scope decides what the token is for, which
its own comment says. Ten assertions cover the parts of the upload that
decide what gets sent and what a refusal means; the upload itself
cannot be asserted without a real Play account, exactly as `altool`
could not.
