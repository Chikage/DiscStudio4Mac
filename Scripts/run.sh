#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [[ ! -d "$ROOT/build/BR.app" ]]; then "$ROOT/Scripts/build.sh"; fi
open "$ROOT/build/BR.app" --args "$@"
