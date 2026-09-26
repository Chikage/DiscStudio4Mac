#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
FIXTURES=$(mktemp -d "$ROOT/.build-fixtures.XXXXXX")
trap 'rm -rf "$FIXTURES"' EXIT
mkdir -p "$FIXTURES/content"
printf 'BR test fixture\n' > "$FIXTURES/content/readme.txt"
hdiutil makehybrid -iso -joliet -o "$FIXTURES/fixture.iso" "$FIXTURES/content"
BR_TEST_IMAGE="$FIXTURES/fixture.iso" swift test
