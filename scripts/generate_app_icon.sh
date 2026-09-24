#!/usr/bin/env bash

set -euo pipefail

SOURCE_PNG="${1:?usage: generate_app_icon.sh SOURCE_PNG OUTPUT_ICNS}"
OUTPUT_ICNS="${2:?usage: generate_app_icon.sh SOURCE_PNG OUTPUT_ICNS}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
RENDITION_RENDERER="$SCRIPT_DIR/render_app_icon_renditions.swift"
EXPECTED_SOURCE_SHA256="c6c6bd3647ca2cc2ae860c27832d2f8150c5832320ed7b4b7b95eae902fe2642"
MAX_SOURCE_BYTES=$((500 * 1024))

error() {
  echo "error: $*" >&2
  exit 1
}

command -v sips >/dev/null 2>&1 || error "sips is required"
command -v iconutil >/dev/null 2>&1 || error "iconutil is required"
command -v shasum >/dev/null 2>&1 || error "shasum is required"
command -v swift >/dev/null 2>&1 || error "Swift is required"
[[ -f "$SOURCE_PNG" ]] || error "app icon source is missing: $SOURCE_PNG"
[[ -f "$RENDITION_RENDERER" ]] || error "app icon rendition renderer is missing: $RENDITION_RENDERER"

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/rill-app-icon.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT
iconset="$temporary_directory/Rill.iconset"
reviewed_source="$temporary_directory/AppIcon-1024-reviewed.png"
mkdir -p "$iconset" "$(dirname "$OUTPUT_ICNS")"
cp "$SOURCE_PNG" "$reviewed_source"

source_sha256="$(shasum -a 256 "$reviewed_source" | awk '{ print $1 }')"
[[ "$source_sha256" == "$EXPECTED_SOURCE_SHA256" ]] \
  || error "app icon source SHA-256 does not match the reviewed asset"
source_bytes="$(wc -c < "$reviewed_source" | tr -d '[:space:]')"
[[ "$source_bytes" -le "$MAX_SOURCE_BYTES" ]] \
  || error "app icon source exceeds the 500 KiB repository limit"

pixel_width="$(sips -g pixelWidth "$reviewed_source" | awk '/pixelWidth:/ { print $2 }')"
pixel_height="$(sips -g pixelHeight "$reviewed_source" | awk '/pixelHeight:/ { print $2 }')"
[[ "$pixel_width" == "1024" && "$pixel_height" == "1024" ]] \
  || error "app icon source must be exactly 1024 x 1024 pixels"

swift "$RENDITION_RENDERER" render "$reviewed_source" "$iconset"
swift "$RENDITION_RENDERER" verify "$iconset"

rm -f "$OUTPUT_ICNS"
iconutil -c icns "$iconset" -o "$OUTPUT_ICNS"
[[ -s "$OUTPUT_ICNS" ]] || error "iconutil did not create a non-empty ICNS file"
