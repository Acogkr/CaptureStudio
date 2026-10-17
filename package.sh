#!/bin/bash
set -euo pipefail
CAPTURE_SOURCE="$(cd "$(dirname "$0")" && pwd)"
CAPTURE_BUILD="${CAPTURE_BUILD_DIR:-$CAPTURE_SOURCE/.build}"
CAPTURE_DIST="${CAPTURE_DIST_DIR:-$CAPTURE_SOURCE/dist}"
CAPTURE_APP="$CAPTURE_DIST/Capture Studio.app"
CAPTURE_VERSION="$(cat "$CAPTURE_SOURCE/VERSION")"
CAPTURE_ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$CAPTURE_APP/Contents/Info.plist")"
[[ "$CAPTURE_VERSION" == "$CAPTURE_ACTUAL_VERSION" ]] || { echo 'Build version differs from VERSION. Run build.sh first.' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$CAPTURE_APP/Contents/Info.plist")" == "$(cat "$CAPTURE_SOURCE/BUILD_NUMBER")" ]] || { echo 'Build number is stale. Run build.sh first.' >&2; exit 1; }
xcrun lipo "$CAPTURE_APP/Contents/MacOS/CaptureStudio" -verify_arch arm64 x86_64
/usr/bin/codesign --verify --deep --strict "$CAPTURE_APP"
mkdir -p "$CAPTURE_BUILD"
CAPTURE_STAGE="$(mktemp -d "$CAPTURE_BUILD/dmg.XXXXXX")"
trap 'rm -rf "$CAPTURE_STAGE"' EXIT
if [[ -n "${CAPTURE_DMG_PYTHON:-}" ]]; then
  [[ -x "$CAPTURE_DMG_PYTHON" ]] || { echo 'CAPTURE_DMG_PYTHON must point to an existing Python executable.' >&2; exit 1; }
else
  CAPTURE_DMG_PYTHON="$CAPTURE_BUILD/dmg-venv/bin/python"
  if [[ ! -x "$CAPTURE_DMG_PYTHON" ]]; then
    CAPTURE_PYTHON=""
    for CAPTURE_CANDIDATE in python3 python3.13 python3.12 python3.11 python3.10; do
      if command -v "$CAPTURE_CANDIDATE" >/dev/null && "$CAPTURE_CANDIDATE" -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
        CAPTURE_PYTHON="$CAPTURE_CANDIDATE"; break
      fi
    done
    [[ -n "$CAPTURE_PYTHON" ]] || { echo 'Packaging requires Python 3.10 or later.' >&2; exit 1; }
    "$CAPTURE_PYTHON" -m venv "$CAPTURE_BUILD/dmg-venv"
  fi
fi
"$CAPTURE_DMG_PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 10))'
"$CAPTURE_DMG_PYTHON" -m pip --disable-pip-version-check install -q -r "$CAPTURE_SOURCE/Scripts/dmg-requirements.txt"
xcrun swift "$CAPTURE_SOURCE/Scripts/DMGBackground.swift" "$CAPTURE_STAGE/background"
CAPTURE_NAME="Capture-Studio-$CAPTURE_VERSION-universal.dmg"
"$CAPTURE_DMG_PYTHON" -m dmgbuild -s "$CAPTURE_SOURCE/Scripts/dmg-settings.py" \
  -D "app=$CAPTURE_APP" -D "assets=$CAPTURE_STAGE/background" \
  'Capture Studio' "$CAPTURE_STAGE/$CAPTURE_NAME"
/usr/bin/hdiutil verify "$CAPTURE_STAGE/$CAPTURE_NAME"
mv "$CAPTURE_STAGE/$CAPTURE_NAME" "$CAPTURE_DIST/$CAPTURE_NAME"
(cd "$CAPTURE_DIST" && /usr/bin/shasum -a 256 "$CAPTURE_NAME" > "$CAPTURE_NAME.sha256")
printf 'Packaged: %s\n' "$CAPTURE_DIST/$CAPTURE_NAME"
