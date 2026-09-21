#!/usr/bin/env python3
"""No ML Kit script is both asked for in Dart and suppressed in R8.

    python3 scripts/check_mlkit_scripts.py

`google_mlkit_text_recognition` can recognise five scripts, and each
non-Latin one is a separate Maven artifact. Only Latin is a dependency
here, so the other four are referenced by the plugin and absent from
the classpath, and R8 stops the release build over them.
`app/android/app/proguard-rules.pro` tells it not to.

That is correct today and is a trap tomorrow. `-dontwarn` does not
make a class exist; it stops R8 objecting that it does not. So:

    TextRecognizer(script: TextRecognitionScript.japanese)

would compile, pass every test here, ship, and throw
NoClassDefFoundError the first time somebody scanned a document — on a
device, after release, in the one code path that reaches it. The
symptom is a crash in a feature that works perfectly in debug, because
DEBUG BUILDS DO NOT RUN R8 at all.

So this refuses that combination, and names the dependency to add.

It is the same shape as `check_ios_purpose_strings.py`: a permission
or a class that the shipped app needs and the build does not carry is
a crash nobody sees until it is in somebody's hands.
"""
import re
import sys
from pathlib import Path

DART = Path("app/lib/src/features/shared/text_reader_io.dart")
RULES = Path("app/android/app/proguard-rules.pro")

# The Dart enum name -> the Gradle dependency that makes it work, and
# the Java package the R8 rule would name.
ARTIFACTS = {
    "chinese": ("com.google.mlkit:text-recognition-chinese",
                "com.google.mlkit.vision.text.chinese"),
    "devanagari": ("com.google.mlkit:text-recognition-devanagari",
                   "com.google.mlkit.vision.text.devanagari"),
    "japanese": ("com.google.mlkit:text-recognition-japanese",
                 "com.google.mlkit.vision.text.japanese"),
    "korean": ("com.google.mlkit:text-recognition-korean",
               "com.google.mlkit.vision.text.korean"),
    # Latin is the one artifact that IS a dependency, through the
    # plugin itself. It must never be suppressed.
    "latin": (None, "com.google.mlkit.vision.text.latin"),
}


def asked_for() -> set[str]:
    """The scripts the Dart constructs a recognizer for."""
    if not DART.exists():
        sys.exit(f"{DART} is not where this gate looks for it. If the "
                 "text reader moved, move this too.")
    return set(re.findall(r"TextRecognitionScript\.(\w+)", DART.read_text()))


def suppressed() -> set[str]:
    """The scripts `-dontwarn` covers."""
    if not RULES.exists():
        return set()
    text = RULES.read_text()
    found = set()
    for name, (_, package) in ARTIFACTS.items():
        # Only a live rule counts. A commented-out one suppresses
        # nothing, and treating it as if it did would report a
        # conflict that is not there.
        pattern = rf"^\s*-dontwarn\s+{re.escape(package)}\."
        if re.search(pattern, text, re.M):
            found.add(name)
    return found


def main() -> None:
    used, quiet = asked_for(), suppressed()

    problems = []
    if not used:
        problems.append(
            "  no TextRecognitionScript at all in the Dart — either the "
            "text reader stopped using ML Kit, in which case the rules "
            "and this gate should go, or it moved"
        )

    for name in sorted(used & quiet):
        artifact = ARTIFACTS[name][0]
        problems.append(
            f"  the app asks for TextRecognitionScript.{name} and "
            f"proguard-rules.pro tells R8 not to warn about it — so it "
            f"builds and then throws NoClassDefFoundError on a device. "
            f"Add `implementation(\"{artifact}:16.0.1\")` to "
            f"app/android/app/build.gradle.kts and drop the -dontwarn "
            f"line, or use a script that is already carried."
        )

    for name in sorted(used - quiet - {"latin"}):
        if ARTIFACTS.get(name, (None, None))[0]:
            problems.append(
                f"  the app asks for TextRecognitionScript.{name}, which "
                "is a separate ML Kit artifact. Nothing suppresses it, so "
                "the release build will fail at R8 — add the dependency."
            )

    if problems:
        print("ML Kit scripts and the R8 rules disagree:")
        print("\n".join(problems))
        sys.exit(1)

    print(f"every ML Kit script the app asks for is carried "
          f"({', '.join(sorted(used))}; "
          f"{len(quiet)} suppressed and unused)")


if __name__ == "__main__":
    main()
