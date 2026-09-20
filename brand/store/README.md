# Store assets

`python3 brand/store/build.py` writes the whole Play listing set into
`brand/store/out/` and zips it; `--ios` writes the App Store set into
`brand/store/out-ios/`. Needs Pillow; nothing else.

## Google Play — `build.py`

| Folder | Size | Slot |
| --- | --- | --- |
| `01-feature-graphic` | 1024×500 | Feature graphic |
| `02-phone` | 1080×1920 | Phone screenshots, 8 |
| `03-tablet-7in` | 1920×1080 | 7-inch tablet, 8 |
| `04-tablet-10in` | 2560×1440 | 10-inch tablet, 8 |
| `05-screenshots-min-1080px` | 3840×2160 | the slot wanting sides 1,080–7,680px, ≤8 MB |
| `06-screenshots-min-720px` | 1280×720 | the slot wanting sides 720–7,680px, ≤15 MB |
| `99-all-screens-phone` | 1080×1920 | every screen in the catalogue, 97 |

## App Store — `build.py --ios`

| Folder | Size | Slot |
| --- | --- | --- |
| `01-iphone-6.5in` | 1284×2778 | iPhone 6.5-inch, 10 |
| `02-ipad-12.9in-portrait` | 2048×2732 | iPad Pro 12.9-inch, 10 |
| `03-ipad-12.9in-landscape` | 2732×2048 | the same ten, landscape |

Ten rather than eight: the two extra are Bills and Company secretarial,
which are the modules the Play eight leave out. Upload one iPad set or
the other, not both — the pair is generated so the orientation is a
choice rather than a rebuild.

Only two things differ from the Play screenshots, and iOS draws them
both: the status bar (clock in the left ear, radios in the right) and the
home indicator. Everything under them is the same drawing, because
`app_shell.dart` builds `NavigationBar` and `NavigationRail` on both
platforms — there is no Cupertino widget in this app.

App Store Connect rejects a screenshot carrying an alpha channel, so
`verify.py --ios` fails the build on one.

`verify.py <outdir> [--ios]` checks all of it against those limits — format,
exact size, 16:9 or 9:16, side bounds, file size. It is the thing to run
after changing a layout, because the failure it catches otherwise
happens in the upload form.

## Where the content comes from

- **The screen list** is parsed out of
  `app/lib/src/features/feedback/screen_catalogue.dart` and
  `documents/doc_types.dart` by `catalogue.py` — never typed out again
  here. That catalogue is already asserted against `core/router.dart` by
  `test/screen_catalogue_test.dart`, so a screen that is renamed or
  deleted changes these assets on the next build instead of leaving Play
  showing somewhere that no longer exists.
- **The palette and type** are `app/lib/src/core/theme.dart`'s: seed
  `#0B7A6B`, scaffold `#F6F8F8`, the four `AppColors` tones, Plus Jakarta
  Sans from `app/assets/fonts`.
- **The mark** is drawn from `brand/mark.py`'s own geometry.
- **The figures are invented.** No real company's books appear here.

## What these are not

They are **rendered mockups, not captures of a running build.** This
machine has no Flutter toolchain and no reachable Supabase — the same
wall `app/screenshots/*.dart` documents at length. The layouts follow the
app: the phone set has the bottom bar built from the five `primary: true`
destinations in `app_shell.dart` plus More; the tablet set has the rail
and the list-and-detail split.

Both stores require store screenshots to represent the actual in-app
experience. Before publishing, capture the same screens from a real build
— a device or emulator for Play, an iPhone 6.5-inch and an iPad Pro
12.9-inch simulator for the App Store — and swap them in, or satisfy
yourself that each of these still matches what the app shows. The feature
graphic is marketing artwork and carries no such constraint.

## Screens that have to fill a screen

An iPhone 6.5-inch is 926pt tall and an iPad Pro 1,366pt, against the
640pt the Play phone set is laid out for, so several screens that ended
neatly on a 360×640 phone ended halfway down an iPad with nothing under
them. What fills them now is content, not stretched furniture: the
dashboard gains a net-cash band and an activity list, the invoice detail
pane gains the document's history, the pipeline has six stages, and the
lists that were nine rows long are as long as they claim to be.

Three of those figures are now summed rather than typed, because a screen
long enough to show a whole statement is long enough to show it
disagreeing with itself: the profit and loss totals and its tax
(`specs._pnl`, at the 15/17/24% SME bands), and each pipeline column's
heading (`specs._pipeline`).

## Files

| File | What it is |
| --- | --- |
| `catalogue.py` | Parses the app's screen list out of the Dart. |
| `content.py` | The invented sample data, seeded off each route so builds are stable. |
| `specs.py` | What each screen shows: eight written by hand, the rest generated. |
| `ui.py` | Pillow primitives, the palette, and the drawn icon set. |
| `frame.py` | A device frame that takes dp and emits pixels, plus the chrome. |
| `bodies.py` | One renderer per screen archetype. |
| `shot.py` | Composes a screenshot at a device profile. |
| `featured.py` | The 1024×500 feature graphic. |
| `build.py` | Emits every set for a store and zips them. |
| `verify.py` | Checks the output against each store's limits. |
