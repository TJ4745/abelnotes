#!/usr/bin/env bash
# Build an AppImage for AbelNotes (Linux desktop).
# Usage: ./tool/build_appimage.sh [--rebuild] [-- <extra flutter build args>]
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

REBUILD=0
[[ "${1:-}" == "--rebuild" ]] && { REBUILD=1; shift; }
[[ "${1:-}" == "--" ]] && shift
BUILD_ARGS=("$@")

BUNDLE="${PROJECT_ROOT}/build/linux/x64/release/bundle"
OUT="${PROJECT_ROOT}/build/appimage"
APPDIR="${OUT}/AbelNotes.AppDir"

if (( REBUILD )) || [[ ! -x "${BUNDLE}/abelnotes" ]]; then
  echo "→ flutter build linux --release"
  flutter build linux --release "${BUILD_ARGS[@]}"
fi

rm -rf "${APPDIR}"
mkdir -p "${APPDIR}/usr/bin" "${OUT}"

echo "→ Staging bundle"
cp -r "${BUNDLE}/abelnotes" "${BUNDLE}/lib" "${BUNDLE}/data" "${APPDIR}/usr/bin/"

echo "→ Rewriting plugin runpaths"
"${PROJECT_ROOT}/tool/strip_build_rpath.py" "${APPDIR}/usr/bin/lib"

cp web/icons/Icon-512.png "${APPDIR}/abelnotes.png"

cat > "${APPDIR}/abelnotes.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=AbelNotes
Comment=Handwriting note-taking app with Nextcloud sync
Exec=abelnotes %F
Icon=abelnotes
Categories=Office;Graphics;
Terminal=false
EOF

cat > "${APPDIR}/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/abelnotes" "$@"
EOF
chmod +x "${APPDIR}/AppRun"

TOOL="${OUT}/appimagetool-x86_64.AppImage"
if [[ ! -x "${TOOL}" ]]; then
  echo "→ Downloading appimagetool"
  wget -q -O "${TOOL}" \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x "${TOOL}"
fi

echo "→ Building AppImage"
ARCH=x86_64 "${TOOL}" --appimage-extract-and-run "${APPDIR}" "${OUT}/AbelNotes-x86_64.AppImage"

echo ""
echo "═══ Done ═══"
ls -lh "${OUT}/AbelNotes-x86_64.AppImage"
