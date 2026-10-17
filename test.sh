#!/bin/bash
set -euo pipefail
CAPTURE_ROOT="$(cd "$(dirname "$0")" && pwd)"
bash "$CAPTURE_ROOT/Tests/BuildTests.sh"
CAPTURE_TEST_APP="$CAPTURE_ROOT/.build/CaptureTests.app"
mkdir -p "$CAPTURE_TEST_APP/Contents/MacOS" "$CAPTURE_TEST_APP/Contents/Resources"
cat > "$CAPTURE_TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CaptureTests</string>
<key>CFBundleIdentifier</key><string>local.capturestudio.tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ko</string><string>ja</string><string>zh-Hans</string></array>
</dict></plist>
PLIST
for CAPTURE_LANGUAGE in en ko ja zh-Hans; do
  ditto "$CAPTURE_ROOT/Resources/$CAPTURE_LANGUAGE.lproj" "$CAPTURE_TEST_APP/Contents/Resources/$CAPTURE_LANGUAGE.lproj"
done
xcrun swiftc -swift-version 5 -D CAPTURE_TESTING -parse-as-library \
  "$CAPTURE_ROOT"/Sources/*.swift "$CAPTURE_ROOT"/Tests/*.swift \
  -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers -framework Carbon \
  -o "$CAPTURE_TEST_APP/Contents/MacOS/CaptureTests"
"$CAPTURE_TEST_APP/Contents/MacOS/CaptureTests" --test
