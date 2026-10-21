#!/bin/bash
set -euo pipefail
CAPTURE_ROOT="$(cd "$(dirname "$0")" && pwd)"
CAPTURE_BUILD="${CAPTURE_BUILD_DIR:-$CAPTURE_ROOT/.build}"
CAPTURE_DIST="${CAPTURE_DIST_DIR:-$CAPTURE_ROOT/dist}"
CAPTURE_DESTINATION="$CAPTURE_DIST/Capture Studio.app"
CAPTURE_VERSION="$(cat "$CAPTURE_ROOT/VERSION")"
CAPTURE_NUMBER="$(cat "$CAPTURE_ROOT/BUILD_NUMBER")"
[[ "$CAPTURE_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && "$CAPTURE_NUMBER" =~ ^[0-9]+$ ]] || { echo 'Invalid version metadata.' >&2; exit 1; }
CAPTURE_ARCHS="${CAPTURE_ARCHS:-arm64 x86_64}"
CAPTURE_SIGNING_IDENTITY="${CAPTURE_SIGNING_IDENTITY:--}"
ensure_app_is_stopped() {
  # Match the executable file, including launches with arguments or a relative path.
  if [ -f "$CAPTURE_DESTINATION/Contents/MacOS/CaptureStudio" ] &&
     /usr/sbin/lsof -t -a -d txt "$CAPTURE_DESTINATION/Contents/MacOS/CaptureStudio" >/dev/null 2>&1; then
    printf 'Quit Capture Studio before rebuilding it.\n' >&2
    exit 1
  fi
}
ensure_app_is_stopped
mkdir -p "$CAPTURE_BUILD" "$CAPTURE_DIST"
CAPTURE_STAGE="$(mktemp -d "$CAPTURE_BUILD/package.XXXXXX")"
CAPTURE_APP="$CAPTURE_STAGE/Capture Studio.app"
cleanup() {
  if [ -d "$CAPTURE_STAGE/previous.app" ] && [ ! -e "$CAPTURE_DESTINATION" ]; then
    mv "$CAPTURE_STAGE/previous.app" "$CAPTURE_DESTINATION"
  fi
  rm -rf "$CAPTURE_STAGE"
}
trap cleanup EXIT
mkdir -p "$CAPTURE_APP/Contents/MacOS" "$CAPTURE_APP/Contents/Resources"
CAPTURE_BINARIES=()
for CAPTURE_ARCH in $CAPTURE_ARCHS; do
  [[ "$CAPTURE_ARCH" == arm64 || "$CAPTURE_ARCH" == x86_64 ]] || { echo 'Unsupported architecture.' >&2; exit 1; }
  CAPTURE_BINARY="$CAPTURE_STAGE/CaptureStudio-$CAPTURE_ARCH"
  xcrun swiftc -swift-version 5 -O -parse-as-library -target "$CAPTURE_ARCH-apple-macosx14.0" \
    "$CAPTURE_ROOT"/Sources/*.swift -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers -framework Carbon -framework ServiceManagement \
    -o "$CAPTURE_BINARY"
  CAPTURE_BINARIES+=("$CAPTURE_BINARY")
done
[[ ${#CAPTURE_BINARIES[@]} -gt 0 ]] || { echo 'Choose at least one architecture.' >&2; exit 1; }
xcrun lipo -create "${CAPTURE_BINARIES[@]}" -output "$CAPTURE_APP/Contents/MacOS/CaptureStudio"
cat > "$CAPTURE_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CaptureStudio</string>
<key>CFBundleIdentifier</key><string>local.capturestudio.app</string>
<key>CFBundleName</key><string>Capture Studio</string>
<key>CFBundleDisplayName</key><string>Capture Studio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$CAPTURE_VERSION</string>
<key>CFBundleVersion</key><string>$CAPTURE_NUMBER</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ko</string><string>ja</string><string>zh-Hans</string></array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Image</string>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>public.image</string></array>
</dict></array>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Acogkr. MIT License.</string>
</dict></plist>
PLIST
cp "$CAPTURE_ROOT/LICENSE" "$CAPTURE_APP/Contents/Resources/LICENSE.txt"
for CAPTURE_LANGUAGE in en ko ja zh-Hans; do
  ditto "$CAPTURE_ROOT/Resources/$CAPTURE_LANGUAGE.lproj" "$CAPTURE_APP/Contents/Resources/$CAPTURE_LANGUAGE.lproj"
done
# Generate resources before signing. Never launch an intermediate signed copy
# at the installed path: TCC may retain that copy's code requirement.
"$CAPTURE_APP/Contents/MacOS/CaptureStudio" --write-icon "$CAPTURE_BUILD/icon.png"
mkdir -p "$CAPTURE_BUILD/AppIcon.iconset"
for CAPTURE_SIZE in 16 32 128 256 512; do
  sips -z "$CAPTURE_SIZE" "$CAPTURE_SIZE" "$CAPTURE_BUILD/icon.png" --out "$CAPTURE_BUILD/AppIcon.iconset/icon_${CAPTURE_SIZE}x${CAPTURE_SIZE}.png" >/dev/null
  CAPTURE_DOUBLE=$((CAPTURE_SIZE * 2))
  sips -z "$CAPTURE_DOUBLE" "$CAPTURE_DOUBLE" "$CAPTURE_BUILD/icon.png" --out "$CAPTURE_BUILD/AppIcon.iconset/icon_${CAPTURE_SIZE}x${CAPTURE_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$CAPTURE_BUILD/AppIcon.iconset" -o "$CAPTURE_APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$CAPTURE_SIGNING_IDENTITY" "$CAPTURE_APP"
codesign --verify --deep --strict "$CAPTURE_APP"
# The user may have reopened the app while compilation was in progress.
ensure_app_is_stopped
if [ -e "$CAPTURE_DESTINATION" ]; then
  mv "$CAPTURE_DESTINATION" "$CAPTURE_STAGE/previous.app"
fi
mv "$CAPTURE_APP" "$CAPTURE_DESTINATION"
printf 'Built: %s\n' "$CAPTURE_DESTINATION"
if [ "$CAPTURE_SIGNING_IDENTITY" = '-' ]; then
  printf 'Local ad-hoc build: replacing an authorized build may require renewing its screen recording permission.\n'
fi
