#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SOURCE_DIR="$PROJECT_DIR/Resources/AppIcon"
OUTPUT_DIR="$PROJECT_DIR/Sources/RillApp/Resources"

# SVG editing tools are needed only when changing the artwork. Builds consume
# the reviewed PNG and vector PDFs committed alongside their SVG sources.
command -v rsvg-convert >/dev/null 2>&1 || {
  echo "error: rsvg-convert is required (brew install librsvg)" >&2
  exit 1
}

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/rill-brand-assets.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT

rsvg-convert "$SOURCE_DIR/Rill.svg" \
  --output "$SOURCE_DIR/AppIcon-1024-routed-voice-cursor.png"

# At 72 dpi, the SVG's 20 × 18 coordinates become a 20 × 18 point PDF.
# Fix Cairo's timestamp so regenerating unchanged vectors is deterministic.
export SOURCE_DATE_EPOCH=0
rsvg-convert --format pdf --dpi-x 72 --dpi-y 72 \
  "$SOURCE_DIR/RillMenuBar.svg" \
  --output "$OUTPUT_DIR/RillMenuBarTemplate.pdf"

echo '#records-indicator { opacity: 1; }' > "$temporary_directory/records.css"
rsvg-convert --format pdf --dpi-x 72 --dpi-y 72 \
  --stylesheet "$temporary_directory/records.css" \
  "$SOURCE_DIR/RillMenuBar.svg" \
  --output "$OUTPUT_DIR/RillMenuBarRecordsTemplate.pdf"

shasum -a 256 "$SOURCE_DIR/Rill.svg" \
  "$SOURCE_DIR/AppIcon-1024-routed-voice-cursor.png" \
  "$SOURCE_DIR/RillMenuBar.svg" \
  "$OUTPUT_DIR/RillMenuBarTemplate.pdf" \
  "$OUTPUT_DIR/RillMenuBarRecordsTemplate.pdf"
