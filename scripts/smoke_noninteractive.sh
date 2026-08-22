#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

SOURCE_APP="${APP_PATH:-packaging/Pesty.app}"
EXPECTED_ID="${EXPECTED_BUNDLE_ID:-com.greycorelabs.pesty}"
KEEP="${KEEP_SMOKE_ARTIFACTS:-0}"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pesty-bundle-smoke.XXXXXX")"
APP="$ROOT/Pesty.app"
HOME_DIR="$ROOT/home"
mkdir -p "$HOME_DIR"

cleanup() {
  rc=$?
  if [ "$rc" -ne 0 ] || [ "$KEEP" = "1" ]; then
    echo "Bundle smoke artifacts retained at: $ROOT" >&2
  else
    rm -rf "$ROOT" || echo "Warning: failed to remove $ROOT" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -d "$SOURCE_APP" ] || fail "missing app bundle: $SOURCE_APP"
cp -R "$SOURCE_APP" "$APP"

PLIST="$APP/Contents/Info.plist"
BIN="$APP/Contents/MacOS/Pesty"

[ -f "$PLIST" ] || fail "missing Info.plist"
[ -x "$BIN" ] || fail "missing executable"

plutil -lint "$PLIST"

bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")"
[ "$bundle_id" = "$EXPECTED_ID" ] || fail "bundle id $bundle_id != $EXPECTED_ID"

executable="$(plutil -extract CFBundleExecutable raw -o - "$PLIST")"
[ "$executable" = "Pesty" ] || fail "unexpected executable name: $executable"

archs="$(lipo -archs "$BIN")"
case " $archs " in
  *" arm64 "*) ;;
  *) fail "arm64 missing: $archs" ;;
esac
case " $archs " in
  *" x86_64 "*) ;;
  *) fail "x86_64 missing: $archs" ;;
esac

codesign --verify --strict --verbose=2 "$APP"
requirement="$(codesign -d -r- "$APP" 2>&1 || true)"
printf '%s\n' "$requirement" | grep -F "identifier \"$EXPECTED_ID\"" >/dev/null \
  || fail "designated requirement does not contain $EXPECTED_ID"

# This script intentionally does not launch the app. It must not touch the real
# clipboard, TCC state, Application Support, iCloud, or user files.
HOME="$HOME_DIR" plutil -p "$PLIST" >/dev/null

echo "PASS: non-interactive bundle smoke"
echo "bundle_id=$bundle_id"
echo "architectures=$archs"
