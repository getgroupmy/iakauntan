#!/usr/bin/env python3
"""Every plugin that needs a purpose string has one in Info.plist.

    python3 scripts/check_ios_purpose_strings.py

iOS does not refuse a permission an app asked for without a purpose
string. It **terminates the app**. So a plugin added to `pubspec.yaml`
without its key added to `Info.plist` is a crash the first time
somebody taps the thing it powers, on a device, after release — and
never on a simulator run that does not reach that screen.

Apple also warns on upload (90683) about keys it can see referenced by
a bundled SDK even where the app never calls them. That one arrives as
a build warning rather than a crash, and was how
`NSLocationWhenInUseUsageDescription` came to be missing here: nothing
in this repository asks for a location, and `DKImagePickerController`
references the API to read a photo's metadata.

The mapping below is the point of this file. Each entry says which
plugin makes which key necessary, so that adding a plugin fails here
rather than on somebody's phone.
"""
import plistlib
import re
import sys
from pathlib import Path

PUBSPEC = Path("app/pubspec.yaml")
PLIST = Path("app/ios/Runner/Info.plist")

# plugin in pubspec.yaml -> keys its presence makes necessary, and why.
REQUIRED: dict[str, dict[str, str]] = {
    "image_picker": {
        "NSCameraUsageDescription": "it opens the camera",
        "NSPhotoLibraryUsageDescription": "it opens the photo library",
    },
    "file_picker": {
        "NSPhotoLibraryUsageDescription":
            "DKImagePickerController reaches the library",
        "NSLocationWhenInUseUsageDescription":
            "DKImagePickerController references the location API to read "
            "where a photo was taken — Apple warns 90683 without it, even "
            "though nothing here asks for a location",
    },
    "record": {
        "NSMicrophoneUsageDescription": "it records audio",
    },
    "flutter_webrtc": {
        "NSCameraUsageDescription": "a video call shows your camera",
        "NSMicrophoneUsageDescription": "a call carries your voice",
    },
    "google_mlkit_text_recognition": {
        "NSCameraUsageDescription": "scanning a document uses the camera",
    },
}


def declared() -> set[str]:
    """Direct dependencies, read from the `dependencies:` block only.

    `dev_dependencies` cannot reach a release build, so a test-only
    package must not make a purpose string necessary.
    """
    text = PUBSPEC.read_text()
    block = re.search(r"\ndependencies:\n(.*?)(?=\n[a-z_]+:\n)", text, re.S)
    if not block:
        sys.exit(f"{PUBSPEC}: no dependencies: block found")
    return set(re.findall(r"^  ([a-z_0-9]+):", block.group(1), re.M))


def main() -> None:
    plist = plistlib.loads(PLIST.read_bytes())
    have = declared()

    problems: list[str] = []
    checked = 0
    for plugin, keys in REQUIRED.items():
        if plugin not in have:
            continue
        for key, why in keys.items():
            checked += 1
            value = plist.get(key)
            if not isinstance(value, str) or not value.strip():
                problems.append(
                    f"  {key} is missing or empty, and {plugin} needs it "
                    f"because {why}"
                )

    # A purpose string nobody needs is worth knowing about too: it asks
    # somebody for a permission the app has no use for, which is the
    # kind of thing a reviewer asks about.
    needed = {k for p, ks in REQUIRED.items() if p in have for k in ks}
    for key in sorted(k for k in plist if k.startswith("NS") and
                      k.endswith("UsageDescription")):
        if key not in needed:
            problems.append(
                f"  {key} is declared and no plugin in pubspec.yaml needs "
                "it — either the plugin went and this did not, or this "
                "table is out of date"
            )

    if problems:
        print("iOS purpose strings and plugins disagree:")
        print("\n".join(problems))
        sys.exit(1)

    print(f"every purpose string the plugins need is present "
          f"({checked} checked across {len(needed)} keys)")


if __name__ == "__main__":
    main()
