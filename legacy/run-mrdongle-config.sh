#!/bin/sh
# Tắt app cũ → build → mở bản mới (tránh phải Quit tay).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

stop_app() {
  osascript -e 'tell application "MRDongleConfig" to quit' >/dev/null 2>&1 || true
  sleep 0.2
  pkill -9 -x MRDongleConfig 2>/dev/null || true
  pkill -9 -f '/MRDongleConfig.app/Contents/MacOS/MRDongleConfig' 2>/dev/null || true
  killall -9 MRDongleConfig 2>/dev/null || true
  sleep 0.3
}

stop_app
xcodebuild -project MagicRemoteBLEBridge.xcodeproj -target MRDongleConfig -configuration Debug build
stop_app
open "$ROOT/build/Debug/MRDongleConfig.app"
