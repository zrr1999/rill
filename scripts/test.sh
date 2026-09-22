#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/.."

# Native windows, focus, and pasteboards share macOS services across processes.
native_tests='RillPlatformTests|RillUITests|RillAppTests'
echo 'Running domain tests in parallel...'
"$SCRIPT_DIR/swift_locked.sh" test --parallel --num-workers 4 --skip "$native_tests"
echo 'Running native platform, UI, and app tests serially...'
"$SCRIPT_DIR/swift_locked.sh" test --skip-build --filter "$native_tests"
