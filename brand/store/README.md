# Play Store assets

`python3 brand/store/build.py` writes the whole Play listing set into
`brand/store/out/` and zips it. Needs Pillow; nothing else.

| Folder | Size | Slot |
| --- | --- | --- |
| `01-feature-graphic` | 1024×500 | Feature graphic |
| `02-phone` | 1080×1920 | Phone screenshots, 8 |
| `03-tablet-7in` | 1920×1080 | 7-inch tablet, 8 |
| `04-tablet-10in` | 2560×1440 | 10-inch tablet, 8 |
| `05-screenshots-min-1080px` | 3840×2160 | the slot wanting sides 1,080–7,680px, ≤8 MB |
| `06-screenshots-min-720px` | 1280×720 | the slot wanting sides 720–7,680px, ≤15 MB |
| `99-all-screens-phone` | 1080×1920 | every screen in the catalogue, 97 |

`verify.py <outdir>` checks all of it against those limits — format,
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

Google Play requires store screenshots to represent the actual in-app
experience. Before publishing, capture the same eight from a real build
and swap them in, or satisfy yourself that each of these still matches
what the app shows. The feature graphic is marketing artwork and carries
no such constraint.

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
| `build.py` | Emits every set and zips them. |
| `verify.py` | Checks the output against Play's limits. |
