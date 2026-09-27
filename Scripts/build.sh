#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
CONFIGURATION=${1:-Release}
xcodebuild -project BR.xcodeproj -scheme BR -configuration "$CONFIGURATION" \
  -derivedDataPath build/Xcode CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build
BUILT_APP="$ROOT/build/Xcode/Build/Products/$CONFIGURATION/Disc Studio.app"
if [[ "$(xcrun lipo -archs "$BUILT_APP/Contents/MacOS/Disc Studio")" != "arm64" ]]; then
  printf 'Error: the application must contain only the arm64 architecture.\n' >&2
  exit 1
fi
APP="$ROOT/build/Disc Studio.app"
# This location contains only the generated application bundle.
if [[ -d "$APP" ]]; then rm -rf "$APP"; fi
ditto "$BUILT_APP" "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf '\nApplication: %s\n' "$APP"
