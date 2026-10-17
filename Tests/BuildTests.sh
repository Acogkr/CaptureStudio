#!/bin/bash
set -euo pipefail
CAPTURE_SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAPTURE_TEMP_ROOT="${TMPDIR:-/tmp}"
CAPTURE_FIXTURE="$(mktemp -d "${CAPTURE_TEMP_ROOT%/}/capture-build-test.XXXXXX")"
CAPTURE_TEST_ROOT="$CAPTURE_FIXTURE/Project [test].(copy)+"
CAPTURE_TEST_APP="$CAPTURE_TEST_ROOT/dist/Capture Studio.app/Contents/MacOS/CaptureStudio"
CAPTURE_TEST_PID=''
cleanup() {
  if [ -n "$CAPTURE_TEST_PID" ]; then
    kill "$CAPTURE_TEST_PID" 2>/dev/null || true
    wait "$CAPTURE_TEST_PID" 2>/dev/null || true
  fi
  rm -rf "$CAPTURE_FIXTURE"
}
trap cleanup EXIT
mkdir -p "$(dirname "$CAPTURE_TEST_APP")" "$CAPTURE_FIXTURE/bin"
cp "$CAPTURE_SOURCE_ROOT/build.sh" "$CAPTURE_TEST_ROOT/build.sh"
cp "$CAPTURE_SOURCE_ROOT/VERSION" "$CAPTURE_SOURCE_ROOT/BUILD_NUMBER" "$CAPTURE_TEST_ROOT/"
printf '#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n' |
  xcrun clang -x c - -o "$CAPTURE_TEST_APP"
# Reaching the compiler proves the guard allowed this fixture. Never build an app.
printf '#!/bin/bash\nexit 86\n' > "$CAPTURE_FIXTURE/bin/xcrun"
chmod +x "$CAPTURE_FIXTURE/bin/xcrun"
check_build() {
  local expected="$1" actual=0
  CAPTURE_BUILD_DIR="$CAPTURE_TEST_ROOT/.build" CAPTURE_DIST_DIR="$CAPTURE_TEST_ROOT/dist" \
    PATH="$CAPTURE_FIXTURE/bin:$PATH" bash "$CAPTURE_TEST_ROOT/build.sh" > "$CAPTURE_FIXTURE/result" 2>&1 || actual=$?
  if [ "$actual" != "$expected" ]; then
    cat "$CAPTURE_FIXTURE/result" >&2
    printf 'Build guard: expected exit %s, got %s\n' "$expected" "$actual" >&2
    exit 1
  fi
  if [ "$expected" = 1 ]; then
    [[ "$(cat "$CAPTURE_FIXTURE/result")" = 'Quit Capture Studio before rebuilding it.' ]]
  fi
}
stop_fixture() {
  kill "$CAPTURE_TEST_PID"
  wait "$CAPTURE_TEST_PID" 2>/dev/null || true
  CAPTURE_TEST_PID=''
}
for argument in '' '--permission-recovered' '--another-argument'; do
  if [ -z "$argument" ]; then "$CAPTURE_TEST_APP" & else "$CAPTURE_TEST_APP" "$argument" & fi
  CAPTURE_TEST_PID=$!
  # Let exec replace the launching shell before inspecting the executable.
  sleep 0.1
  check_build 1
  stop_fixture
done
(cd "$CAPTURE_TEST_ROOT" && exec './dist/Capture Studio.app/Contents/MacOS/CaptureStudio' --permission-recovered) &
CAPTURE_TEST_PID=$!
sleep 0.1
check_build 1
stop_fixture
check_build 86
cp "$CAPTURE_TEST_APP" "${CAPTURE_TEST_APP}-other"
"${CAPTURE_TEST_APP}-other" &
CAPTURE_TEST_PID=$!
sleep 0.1
check_build 86
stop_fixture
printf '6 build safety checks passed.\n'
