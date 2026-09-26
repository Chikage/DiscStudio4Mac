#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [[ ! -d "$ROOT/build/Disc Studio.app" ]]; then "$ROOT/Scripts/build.sh"; fi
open "$ROOT/build/Disc Studio.app" --args "$@"
