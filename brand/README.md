# Brand mark

The iAkauntan mark: a green **J** (dotted stem over a bowl) with an **A**
chevron rising out of the bowl's right shoulder.

## Provenance — read this before treating these files as the master

These are a **reconstruction of the supplied artwork, not a conversion of it.**
The logo was supplied to me as an image in conversation; the bytes never
reached the filesystem, so there was no file to trace or vectorise. The
geometry in `mark.py` was rebuilt by eye against the supplied picture: stroke
weight, the bowl radius, the chevron's angle and its apex height are all
measured judgements, not extracted paths.

They are close enough to ship as placeholders and they render cleanly at every
size we emit, but if the true master exists as SVG or AI, **replace these
rather than keep editing them** — drop the master in as
`brand/iakauntan-mark.svg` and regenerate the raster set from it.

## Files

| File | What it is |
| --- | --- |
| `mark.py` | The geometry, on a 1000-unit grid. The single source of truth. |
| `render.py` | Rasterises the geometry with Pillow, 4x supersampled, centred on the mark's own ink bounds rather than on the grid. |
| `build.py` | Emits the SVG masters and every PNG the app needs. |
| `iakauntan-mark.svg` | Vector master, transparent, tight to the ink. |
| `iakauntan-mark-maskable.svg` | Vector master with the padding Android's maskable icons require. |
| `iakauntan-mark-512.png` | 512px reference raster. |

Regenerate everything with `python3 brand/build.py` (needs Pillow). It writes
the masters here and the app icons into `app/web/`.

## Known limits

- **Below about 48px the two-letter lockup stops being legible** — the dot,
  the bowl and the chevron collapse into a green blob. That is inherent to the
  artwork, not to the rendering. `favicon.png` is 32px and is affected. A
  single-letter or solid-silhouette variant would be the fix if small sizes
  matter.
- **The mark's green is `#0BD00B`; the app's theme colour is still the teal
  `#0B7A6B`** in `app/web/manifest.json` and `app/web/index.html`. They
  disagree on purpose — changing the theme colour recolours the browser chrome
  and the splash, which is a design call, not an asset swap.
- The sign-in screen still uses `Icons.account_balance_wallet` with a text
  wordmark (`app/lib/src/features/auth/sign_in_screen.dart`). Placing the mark
  in-app is likewise a design call and was left alone.
