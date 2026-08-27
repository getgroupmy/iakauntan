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
- **The mark's green is `#0BD00B`; the app's theme colour is whatever is set
  under Branding.** Neither file carries a colour any more. `index.html` and
  `manifest.json` are stamped from `landing_page()` by
  `scripts/ci/branding_icon.sh` before each build, and the running app sets the
  same tags again once it has the payload — so changing the browser chrome is a
  console setting rather than an edit here. A build with no database
  credentials ships them unstamped, which means no theme colour at all: a
  browser then uses its own, which is a truthful "this platform has not said"
  rather than somebody else's green.
- The sign-in screen no longer draws a built-in icon at all. `0337` removed the
  `Icons.account_balance_wallet` fallback — it was this product's mark on
  somebody else's page, and a visitor cannot tell it from a real logo — so a
  platform with no uploaded logo gets its wordmark alone. `0338` made the logo
  and the name two separate switches under **Sign in page**.
