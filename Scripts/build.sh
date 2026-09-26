#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
CONFIGURATION=${1:-Release}
xcodebuild -project BR.xcodeproj -scheme BR -configuration "$CONFIGURATION" \
  -derivedDataPath build/Xcode CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO build
APP="$ROOT/build/BR.app"
# This location contains only the generated application bundle.
if [[ -d "$APP" ]]; then rm -rf "$APP"; fi
ditto "build/Xcode/Build/Products/$CONFIGURATION/BR.app" "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf '\nApplication: %s\n' "$APP"
