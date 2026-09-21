#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/.."

# Native windows share the macOS application/focus environment across processes.
echo 'Running domain tests in parallel...'
"$SCRIPT_DIR/swift_locked.sh" test --parallel --num-workers 4 --skip 'RillUITests|RillAppTests'
echo 'Running native UI and app tests serially...'
"$SCRIPT_DIR/swift_locked.sh" test --skip-build --filter 'RillUITests|RillAppTests'
