#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

cd "$PROJECT_DIR"

fail() {
  echo "✗ $*" >&2
  exit 1
}

legacy_domain_pattern='\b(DeliveryStack|ClipboardHistoryItem|ClipboardGroup|ClipboardPasteMode|ClipboardItemDryRun)\b'
if rg -n "$legacy_domain_pattern" Sources --glob '*.swift' --glob '!LegacyClipboardMigration.swift'; then
  fail "Legacy Stack/Clipboard domain types escaped LegacyClipboardMigration"
fi

if rg -n \
  '^\s*(public |internal |private |fileprivate )?(final )?(struct|class|enum|protocol|actor|typealias) Clipboard[A-Z]' \
  Sources \
  --glob '*.swift' \
  --glob '!LegacyClipboardMigration.swift'; then
  fail "Clipboard-prefixed domain declarations must be SystemClipboard-prefixed or migration-only"
fi

legacy_sources="$(
  find Sources -type f \
    \( -name 'DeliveryStack*.swift' -o -name 'Clipboard*.swift' -o -name 'StackPasteController.swift' \) \
    ! -name 'LegacyClipboardMigration.swift' \
    -print
)"
if [[ -n "$legacy_sources" ]]; then
  printf '%s\n' "$legacy_sources" >&2
  fail "Legacy Stack/Clipboard source files remain outside the migration boundary"
fi

if rg -n 'id\s*=\s*"(stack\.push|clipboard\.copy)"|strategy\s*=\s*"(stack-first|clipboard-only)"' \
  Sources/RillApp/Resources \
  --glob '*.toml'; then
  fail "Built-in workflow resources must emit canonical Record action IDs and strategies"
fi

echo "Record domain boundary check passed"
