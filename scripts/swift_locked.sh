#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
exec uv run --no-build --locked --script "$SCRIPT_DIR/build_driver.py" "$@"
