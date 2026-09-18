#!/usr/bin/env python3
"""Refuse a passkey association that will fail silently.

    python3 scripts/check_passkey_association.py

A passkey is bound to a DOMAIN. The operating system runs a ceremony
only once it has verified that the app may act for that domain, and it
verifies that by fetching one file:

  * Android: /.well-known/assetlinks.json
  * iOS:     /.well-known/apple-app-site-association

Both live in `app/web/.well-known/`, which Flutter copies into the build.

## Why this gate exists

Every way of getting these wrong fails IDENTICALLY, and the failure is
a button that does nothing:

  * the file absent;
  * the file present with the wrong fingerprint or team id;
  * the right file served as `text/plain`, which Apple rejects outright
    (and then caches the rejection for about a day);
  * `assetlinks.json` listing the UPLOAD key only, which works on the
    developer's handset and on no device that installed from Play,
    because Play re-signs with its own certificate.

`docs/passkeys.md` argues that a placeholder is worse than nothing: it
is a file that says the association is configured while failing every
ceremony. This gate is what makes that argument enforceable rather than
advisory.

## Absent is allowed. Wrong is not.

The files are NOT in this repository as of writing, deliberately, because
neither can be written without a value that is not here: the Play App
Signing certificate's SHA-256 and the Apple team id. So a repository
without them is a valid state and this gate passes.

What it refuses is a file that EXISTS and is wrong, including one still
carrying a placeholder. That is the state somebody reaches by copying
the snippet out of the documentation and meaning to come back to it.
"""

from __future__ import annotations

import json
import pathlib
import plistlib
import re
import sys

WELL_KNOWN = pathlib.Path("app/web/.well-known")
ASSETLINKS = WELL_KNOWN / "assetlinks.json"
AASA = WELL_KNOWN / "apple-app-site-association"

#: Read from the build files rather than typed here, so the gate cannot
#: pass against an association naming an app this repository no longer
#: builds.
IOS_PROJECT = pathlib.Path("app/ios/Runner.xcodeproj/project.pbxproj")
ANDROID_GRADLE = pathlib.Path("app/android/app/build.gradle.kts")
ENTITLEMENTS = pathlib.Path("app/ios/Runner/Runner.entitlements")
VERCEL = pathlib.Path("deploy/vercel-output-config.json")

#: An Apple team id is ten characters of upper-case alphanumerics.
TEAM_ID = re.compile(r"^[A-Z0-9]{10}$")
#: A SHA-256 fingerprint is 32 bytes as colon-separated upper-case hex.
FINGERPRINT = re.compile(r"^(?:[0-9A-F]{2}:){31}[0-9A-F]{2}$")
#: The shapes a placeholder takes when somebody means to come back.
PLACEHOLDER = re.compile(
    r"<[^>]*>|TEAMID|TEAM_ID|XXXX|PLACEHOLDER|YOUR[_ ]|TODO|FIXME|\.\.\.",
    re.I,
)

problems: list[str] = []


def fail(message: str) -> None:
    problems.append(message)


def bundle_id() -> str | None:
    if not IOS_PROJECT.exists():
        return None
    ids = set(
        re.findall(
            r"PRODUCT_BUNDLE_IDENTIFIER = ([A-Za-z0-9.\-]+);",
            IOS_PROJECT.read_text(),
        )
    )
    # The test target's id is the app's with a suffix; the app's is the
    # shortest.
    app_ids = {i for i in ids if not i.endswith(".RunnerTests")}
    return min(app_ids, key=len) if app_ids else None


def package_name() -> str | None:
    if not ANDROID_GRADLE.exists():
        return None
    m = re.search(r'applicationId\s*=\s*"([^"]+)"', ANDROID_GRADLE.read_text())
    return m.group(1) if m else None


def check_content_types() -> None:
    """The route that serves both files as application/json.

    `apple-app-site-association` has NO EXTENSION, so a static host
    serves it as `text/plain` and Apple rejects it — and then caches the
    rejection, so a correct file fails for a day after it is fixed. The
    route is in place ahead of the files for exactly that reason, and
    this asserts it stays.
    """
    if not VERCEL.exists():
        fail(f"{VERCEL} is missing, so nothing sets the content types")
        return
    text = VERCEL.read_text()
    for name in ("apple-app-site-association", "assetlinks"):
        if name not in text:
            fail(
                f"{VERCEL} has no route for {name}. Without one it is "
                "served as text/plain, which Apple rejects and then "
                "caches the rejection of for about a day."
            )


def check_entitlement() -> None:
    """The iOS half that lives in the app rather than on the domain."""
    if not ENTITLEMENTS.exists():
        fail(
            f"{ENTITLEMENTS} is missing. Without the Associated Domains "
            "entitlement iOS refuses the ceremony however correct the "
            "association file is."
        )
        return
    # PARSED, not searched. The first version of this read the file as
    # text and refused it for the words "?mode=developer" appearing in
    # the COMMENT that warns against them -- a gate failing on its own
    # documentation. What matters is the VALUES in the array.
    try:
        with ENTITLEMENTS.open("rb") as f:
            entitlements = plistlib.load(f)
    except Exception as e:  # noqa: BLE001 - any refusal is the finding
        fail(f"{ENTITLEMENTS} is not a readable plist: {e}")
        return

    domains = entitlements.get("com.apple.developer.associated-domains")
    if not domains:
        fail(f"{ENTITLEMENTS} declares no associated domains")
        return

    domains = [str(d) for d in domains]
    if not any(d.startswith("webcredentials:") for d in domains):
        fail(
            f"{ENTITLEMENTS} has no `webcredentials:` domain, only "
            f"{domains}. `applinks:` is a different service on the same "
            "mechanism and does not carry passkeys."
        )
    for d in domains:
        if "?mode=developer" in d:
            fail(
                f"{ENTITLEMENTS} carries `?mode=developer` on {d!r}. That "
                "bypasses Apple's CDN during development and MUST NOT "
                "SHIP: a build with it does not validate against the real "
                "service."
            )
    # The entitlement is useless unless the build settings point at it.
    if IOS_PROJECT.exists():
        wired = IOS_PROJECT.read_text().count(
            "CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;"
        )
        if wired == 0:
            fail(
                "No build configuration sets CODE_SIGN_ENTITLEMENTS, so "
                f"{ENTITLEMENTS} is a file nothing reads."
            )
        elif wired < 3:
            fail(
                f"Only {wired} of the 3 Runner configurations set "
                "CODE_SIGN_ENTITLEMENTS. The ones that do not produce a "
                "build with no entitlement, which fails only at the "
                "ceremony."
            )


def check_assetlinks() -> None:
    if not ASSETLINKS.exists():
        return  # Absent is allowed. See the module docstring.

    try:
        data = json.loads(ASSETLINKS.read_text())
    except json.JSONDecodeError as e:
        fail(f"{ASSETLINKS} is not valid JSON: {e}")
        return

    if not isinstance(data, list) or not data:
        fail(f"{ASSETLINKS} must be a non-empty JSON array of statements")
        return

    want = package_name()
    seen_packages: set[str] = set()
    fingerprints: list[str] = []

    for i, statement in enumerate(data):
        if not isinstance(statement, dict):
            fail(f"{ASSETLINKS}[{i}] is not an object")
            continue
        relations = statement.get("relation") or []
        # `get_login_creds` is the relation that matters. `handle_all_urls`
        # is App Links and carries no credentials, so a file with only
        # that one is a file that does nothing for passkeys.
        if not any("get_login_creds" in str(r) for r in relations):
            continue
        target = statement.get("target") or {}
        package = target.get("package_name")
        if package:
            seen_packages.add(package)
        for f in target.get("sha256_cert_fingerprints") or []:
            fingerprints.append(str(f))

    if not seen_packages:
        fail(
            f"{ASSETLINKS} has no statement with the "
            "`delegate_permission/common.get_login_creds` relation. "
            "`handle_all_urls` is App Links and carries no credentials."
        )
    elif want and want not in seen_packages:
        fail(
            f"{ASSETLINKS} names {sorted(seen_packages)} but this "
            f"repository builds {want!r}."
        )

    if not fingerprints:
        fail(f"{ASSETLINKS} lists no sha256_cert_fingerprints")
    for f in fingerprints:
        if PLACEHOLDER.search(f):
            fail(
                f"{ASSETLINKS} still carries a placeholder fingerprint "
                f"({f!r}). A file that says the association is configured "
                "while failing every ceremony is worse than no file."
            )
        elif not FINGERPRINT.match(f):
            fail(
                f"{ASSETLINKS} has a fingerprint that is not 32 "
                f"colon-separated upper-case hex bytes: {f!r}"
            )

    # THE COMMONEST WAY THIS GOES WRONG, and it is invisible until an
    # installed build is tested: listing the upload key only. Play
    # re-signs with its own certificate, so the app on a real device is
    # signed by something this file does not name.
    if len(set(fingerprints)) == 1:
        fail(
            f"{ASSETLINKS} lists ONE fingerprint. That is usually the "
            "upload key alone, which works on a handset you installed to "
            "directly and on no device that installed from Play, because "
            "Play re-signs with its own certificate. List both: the "
            "upload key AND the Play App Signing certificate (Play "
            "Console, Setup, App signing). If this deployment genuinely "
            "does not use Play App Signing, say so here in a comment and "
            "relax this check deliberately."
        )


def check_aasa() -> None:
    if not AASA.exists():
        return  # Absent is allowed.

    if AASA.suffix:
        fail(
            f"{AASA} has an extension. Apple fetches the path "
            "`/.well-known/apple-app-site-association` exactly."
        )

    try:
        data = json.loads(AASA.read_text())
    except json.JSONDecodeError as e:
        fail(f"{AASA} is not valid JSON: {e}")
        return

    creds = (data.get("webcredentials") or {}).get("apps")
    if not creds:
        fail(
            f"{AASA} has no `webcredentials.apps`. `applinks` is a "
            "different service on the same file and does not carry "
            "passkeys."
        )
        return

    want = bundle_id()
    for entry in creds:
        entry = str(entry)
        if PLACEHOLDER.search(entry):
            fail(
                f"{AASA} still carries a placeholder ({entry!r}). Put the "
                "real ten-character Apple team id in front of the bundle "
                "id."
            )
            continue
        # The format is TEAMID.bundle.id — one dot after the team id and
        # the bundle id's own dots after that.
        team, _, bundle = entry.partition(".")
        if not TEAM_ID.match(team):
            fail(
                f"{AASA} entry {entry!r} does not start with a "
                "ten-character Apple team id."
            )
        if want and bundle != want:
            fail(
                f"{AASA} entry {entry!r} names bundle {bundle!r}, but "
                f"this repository builds {want!r}."
            )


def main() -> int:
    if not pathlib.Path("app/pubspec.yaml").exists():
        print("run this from the repository root")
        return 2

    check_content_types()
    check_entitlement()
    check_assetlinks()
    check_aasa()

    if problems:
        print(f"{len(problems)} passkey association problem(s):\n")
        for p in problems:
            print(f"  * {p}\n")
        return 1

    present = [p.name for p in (ASSETLINKS, AASA) if p.exists()]
    if present:
        print(f"Passkey association files check out: {', '.join(present)}.")
    else:
        print(
            "The entitlement and the content-type routes are in place. "
            "Neither association file is deployed yet, which is a valid "
            "state — they need the Play App Signing SHA-256 and the "
            "Apple team id, and a placeholder would be worse than "
            "nothing. See docs/passkeys.md."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
