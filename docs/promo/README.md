# The promotional film

A 62.5-second 1920×1080 film about iAkauntan, built from this repository.

```
cd docs/promo
npm install          # playwright + a static ffmpeg; the browser is not downloaded
./build.sh           # → .promo-build/iakauntan-promo-1080p.mp4
```

`.promo-build/` is gitignored. **The storyboard is the source; the film is a
build artefact.** Nothing about the cut is typed into the encoder.

| File | What it is |
| --- | --- |
| `storyboard.json` | Every scene: timing, on-screen copy, and the AI prompt for its plate. The single source of truth. |
| `scene.html` | Renders one frame. `window.__render(t)` is a pure function of `t`. |
| `render.mjs` | Drives `scene.html` frame by frame and pipes the frames into ffmpeg. |
| `music.py` | Synthesises the score, taking its cues from `storyboard.json`. |
| `generate_shots.mjs` | Generates the plates through Open Higgsfield AI's backend. |
| `build.sh` | Frames, score, mux. |

## Everything on screen is a claim this repository already makes

The copy is taken from `README.md`, not written for the film. The journal
entry in the ledger scene is the one under **Verified end to end**; the filing
deadlines are the table under **The dates are the product**; 662 and 329 are
the counts in `docs/api/`. If one of those numbers changes, the film is wrong
and `storyboard.json` is where it gets fixed.

Two statements were deliberately left out because the repository does not
support them: nothing claims the seeded statutory schedules are verified (they
ship `is_verified = false`), and nothing claims a figure is correct merely
because a test passes.

No identity document number — IC, NRIC or passport — appears anywhere in the
film, and none should be added. The SmartScan scene uses a supplier name, a
date, a document number and a total, which is what that screen reads.

## Why a browser renders the frames

`scene.html` is laid out in CSS with the product's own typeface
(`app/assets/fonts/PlusJakartaSans-*.ttf`), so the film is set in the same face
as the app rather than in whatever ffmpeg's `drawtext` can reach. The page
never animates on a clock: `render.mjs` sets the time, waits, and screenshots.
Two runs of `./build.sh` produce the same frames.

`render.mjs` refuses to start if the scenes in `storyboard.json` leave a gap,
overlap, or do not add up to `duration_seconds` — a seam is invisible in the
output and wrong.

### The browser it uses

Playwright's browser download is skipped on machines that already carry a
Chromium. `render.mjs` looks at `CHROMIUM_PATH`, then
`PLAYWRIGHT_BROWSERS_PATH`, then `/opt/pw-browsers`, and only then falls back
to Playwright's own copy. Where none of those hold a browser, run
`npx playwright install chromium` once.

## The score

`music.py` reads the scene starts out of `storyboard.json` and puts one struck
bell on each, so a scene that moves in the edit takes its cue with it. The bed
is an eight-chord progression under the whole film, and it is written to open
and close on silence.

It needs `numpy` and nothing else:

```
pip install numpy
python3 music.py --out ../../.promo-build/score.wav
```

## Plates, through Open Higgsfield AI

Every scene in `storyboard.json` carries a `shot` — a prompt and a model id
for [Open Higgsfield AI](https://github.com/Autom8AI/Open-Higgsfield-AI), the
open-source studio over muapi.ai. The film as committed is typographic and
needs none of them; a plate is an optional layer behind the type.

```
export MUAPI_KEY=...
node generate_shots.mjs --dry-run --repo ../../../autom8ai/open-higgsfield-ai
node generate_shots.mjs --only ledger,close
```

`--repo` points at a checkout of the studio and checks every model id against
`src/lib/models.js` **before** anything is submitted, so a typo costs nothing
instead of a generation. `--dry-run` prints the requests and spends nothing.
The submit-then-poll protocol mirrors `src/lib/muapi.js` in that repository.

Plates land in `.promo-build/shots/<scene-id>.mp4`. To use one, name it on its
scene and rebuild:

```json
{ "id": "ledger", "plate": "ledger.mp4", ... }
```

`scene.html` composites it behind the type under a scrim, and stretches it
across the whole scene rather than looping — a five-second generation under an
eight-second scene would otherwise jump. A plate that fails to load is skipped
rather than hanging the render.

Generations cost money and are not reproducible: the same prompt returns a
different clip each time. That is why they are optional and why the committed
film does not depend on one.

## Changing the film

Edit `storyboard.json` and rebuild. To look at a moment without waiting for a
full encode:

```
node render.mjs --preview 16.8,30.5,47.5     # PNGs into .promo-preview/
```

A full render is about 1,875 frames at roughly 2.7 fps — eleven or twelve
minutes on a warm machine, and the encode is the cheap half.
