#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=${TMPDIR:-/tmp}/MagicRemoteBLE-release-$$
DD="$WORK/DerivedData"
OUT="$ROOT/build/Release/MagicRemoteBLE.app"
ENT="$ROOT/MagicRemoteBLE/MagicRemoteBLERelease.entitlements"

trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK" "$ROOT/build/Release"

# Build without Xcode's final signing step, then apply the minimal release
# entitlements explicitly so the artifact is portable for test machines.
xcodebuild \
  -project "$ROOT/MagicRemoteBLEBridge.xcodeproj" \
  -scheme MagicRemoteBLE \
  -configuration Release \
  -sdk macosx \
  -derivedDataPath "$DD" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

rm -rf "$OUT"
ditto --noextattr --norsrc "$DD/Build/Products/Release/MagicRemoteBLE.app" "$OUT"
codesign --force --deep --sign - --entitlements "$ENT" "$OUT"

echo "Built signed Release app: $OUT"
lipo -info "$OUT/Contents/MacOS/MagicRemoteBLE"
codesign -dvvv --entitlements :- "$OUT" 2>&1 | tail -18
