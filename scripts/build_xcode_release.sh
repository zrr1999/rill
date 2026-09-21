#!/usr/bin/env bash
# Build all runtime products through the locked, configuration-owned driver.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
exec "$SCRIPT_DIR/swift_locked.sh" release "$@"
