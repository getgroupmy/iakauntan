#!/usr/bin/env bash
# Builds the iAkauntan promotional film from docs/promo/storyboard.json.
#
#   cd docs/promo && npm install && ./build.sh
#
# Output lands in .promo-build/ at the repository root, which is gitignored —
# the film is a build artefact, the storyboard is the source.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$HERE/../../.promo-build}"
mkdir -p "$OUT_DIR"

FFMPEG="$(node -p "require('ffmpeg-static')" 2>/dev/null || echo ffmpeg)"
SILENT="$OUT_DIR/iakauntan-promo-silent.mp4"
SCORE="$OUT_DIR/score.wav"
FINAL="$OUT_DIR/iakauntan-promo-1080p.mp4"

echo "==> frames"
node "$HERE/render.mjs" --out "$SILENT"

echo "==> score"
python3 "$HERE/music.py" --out "$SCORE"

echo "==> mux"
# -shortest would trim to whichever ends first; both are exactly as long as the
# storyboard says, and the render already failed if they were not.
"$FFMPEG" -y -hide_banner -loglevel error \
  -i "$SILENT" -i "$SCORE" \
  -map 0:v:0 -map 1:a:0 \
  -c:v copy \
  -c:a aac -b:a 192k -ar 48000 -ac 2 \
  -movflags +faststart \
  "$FINAL"

echo "==> done"
"$FFMPEG" -hide_banner -i "$FINAL" 2>&1 | sed -n '/Input #0/,/^$/p'
ls -lh "$FINAL"
