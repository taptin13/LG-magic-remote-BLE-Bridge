#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=${TMPDIR:-/tmp}/MagicRemoteBLE-build-$$
DD="$WORK/DerivedData"
OUT="$ROOT/build/MagicRemoteBLE.app"
ENT="$ROOT/MagicRemoteBLE/MagicRemoteBLE.entitlements"

trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK" "$ROOT/build"

# Build without Xcode's final signing step.  The clean copy below avoids
# Finder/provenance metadata that can make codesign reject generated assets.
xcodebuild \
  -project "$ROOT/MagicRemoteBLEBridge.xcodeproj" \
  -scheme MagicRemoteBLE \
  -configuration Debug \
  -sdk macosx \
  -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO \
  build

rm -rf "$OUT"
ditto --noextattr --norsrc "$DD/Build/Products/Debug/MagicRemoteBLE.app" "$OUT"
codesign --force --deep --sign - --entitlements "$ENT" "$OUT"

echo "Built signed Debug app: $OUT"
codesign -dvvv --entitlements :- "$OUT" 2>&1 | tail -18
