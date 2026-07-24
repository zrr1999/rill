#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
FOUND=false

while IFS= read -r -d '' script; do
  FOUND=true
  bash -n "$script"
done < <(find "$PROJECT_DIR/scripts" -type f -name '*.sh' -print0)

$FOUND || {
  echo "No shell scripts found under $PROJECT_DIR/scripts" >&2
  exit 1
}
