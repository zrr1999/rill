#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
DEFAULT_PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
PROJECT_DIR="${1:-$DEFAULT_PROJECT_DIR}"

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "✗ Release artifact hygiene root is not a directory: $PROJECT_DIR" >&2
  exit 1
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"

FOUND=()
for name in Rill.app Rill.dmg Rill.dmg.sha256; do
  path="$PROJECT_DIR/$name"
  if [[ -e "$path" || -L "$path" ]]; then
    FOUND+=("$name")
  fi
done

if [[ "${#FOUND[@]}" -gt 0 ]]; then
  echo "✗ Repository-root release artifacts are forbidden: ${FOUND[*]}" >&2
  echo "  Preserve local artifacts under .artifacts/ or use a directory outside the repository." >&2
  exit 1
fi

echo "Release artifact hygiene check passed."
