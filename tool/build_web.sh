#!/usr/bin/env bash
# Build the AbelNotes web app (PWA) into build/web, ready to upload to any
# static host.
#
#   tool/build_web.sh                    # served from the site root
#   tool/build_web.sh /abelnotes/        # served from a sub-path
#
# What it adds on top of `flutter build web`:
#   * --no-web-resources-cdn  CanvasKit and fonts are bundled, not fetched from
#                             gstatic, so the app can start with no network.
#   * an offline service worker (tool/web_sw.js) replacing Flutter's stub.
set -euo pipefail
cd "$(dirname "$0")/.."

BASE_HREF="${1:-/}"
# SOURCE_MAPS=1 adds main.dart.js.map, to read stack traces from a device log.
flutter build web --release --no-web-resources-cdn --base-href "$BASE_HREF" \
  ${SOURCE_MAPS:+--source-maps}

OUT=build/web
BUILD_ID="$(date +%Y%m%d%H%M%S)"

# Everything the app can need, relative to the site root. The CanvasKit
# variants for other renderers (skwasm, webparagraph) are never loaded.
FILES="$(cd "$OUT" && find . -type f \
  ! -name 'flutter_service_worker.js' ! -name '*.symbols' ! -name '*.map' \
  ! -name '.last_build_id' ! -name 'update.html' ! -path './canvaskit/skwasm*' \
  ! -path './canvaskit/experimental_webparagraph/*' \
  | sed 's|^\./||' | sort | python3 -c \
  'import sys,json; print(json.dumps(["./"]+[l.strip() for l in sys.stdin if l.strip()]))')"

python3 - "$OUT/flutter_service_worker.js" "$BUILD_ID" "$FILES" <<'PY'
import sys
out, build_id, files = sys.argv[1:4]
src = open('tool/web_sw.js').read()
open(out, 'w').write(src.replace('__BUILD_ID__', build_id).replace('__FILES__', files))
PY

echo "Built $OUT (offline cache id $BUILD_ID), $(du -sh "$OUT" | cut -f1)"
