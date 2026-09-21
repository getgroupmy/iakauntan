# R8 rules for the release build.
#
# R8 runs on RELEASE builds only. A debug build never shrinks, so
# nothing in this file has any effect on `flutter run` — and a CI job
# that builds debug cannot prove any of it. That is why `ci.yml` builds
# the Android app in release: this whole class of failure is invisible
# until the day somebody tries to publish.
#
# ---------------------------------------------------------------------
# ML Kit text recognition: four scripts this app does not use
#
# `google_mlkit_text_recognition` ships one Android plugin that can
# build a recognizer for any of five scripts. Its `initialize()`
# switches over all five and so REFERENCES all five options classes:
#
#     com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
#     com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
#     com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
#     com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
#     com.google.mlkit.vision.text.latin.TextRecognizerOptions
#
# Each non-Latin script is a SEPARATE Maven artifact, and only the
# Latin one is a dependency here. So the other four are referenced and
# absent, and R8 stops the build rather than silently producing a
# bundle with dangling references.
#
# `app/lib/src/features/shared/text_reader_io.dart` asks for
# `TextRecognitionScript.latin` and nothing else, so those four classes
# can never be reached. Telling R8 not to warn about them is therefore
# accurate rather than a way of quietening it.
#
# ## The trap this leaves, and what holds it
#
# `-dontwarn` turns a BUILD failure into a RUNTIME one. Change that
# Dart line to `TextRecognitionScript.japanese` and the app compiles,
# ships, and throws NoClassDefFoundError the first time somebody scans
# a document — on a device, after release.
#
# `scripts/check_mlkit_scripts.py` is what makes that safe. It reads
# the scripts the Dart actually asks for and refuses any that is
# suppressed here, naming the Gradle dependency to add instead. The
# alternative — adding all four artifacts up front — is several
# megabytes of recognizer models for languages nothing reads.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
