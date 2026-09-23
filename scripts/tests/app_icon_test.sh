#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
SOURCE_PNG="$PROJECT_DIR/Resources/AppIcon/AppIcon-1024-routed-voice-cursor.png"
SOURCE_README="$PROJECT_DIR/Resources/AppIcon/README.md"
GENERATOR="$PROJECT_DIR/scripts/generate_app_icon.sh"
RENDITION_RENDERER="$PROJECT_DIR/scripts/render_app_icon_renditions.swift"
EXPECTED_SOURCE_SHA256="bff6a4c0ffb39a31ca09eb43953eb58113161c81308d5012578f89c205f3f876"
MAX_SOURCE_BYTES=$((500 * 1024))
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rill-app-icon-tests.XXXXXX")"
OUTPUT_ICNS="$TEST_ROOT/Rill.icns"
EXTRACTED_ICONSET="$TEST_ROOT/extracted.iconset"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

[[ -x "$GENERATOR" ]] || {
  echo "FAIL: app icon generator is not executable" >&2
  exit 1
}
[[ -f "$SOURCE_PNG" ]] || {
  echo "FAIL: 1024 px app icon source is missing" >&2
  exit 1
}
[[ -f "$SOURCE_README" ]] || {
  echo "FAIL: app icon provenance README is missing" >&2
  exit 1
}
[[ -f "$RENDITION_RENDERER" ]] || {
  echo "FAIL: app icon rendition renderer is missing" >&2
  exit 1
}

actual_source_sha256="$(shasum -a 256 "$SOURCE_PNG" | awk '{ print $1 }')"
[[ "$actual_source_sha256" == "$EXPECTED_SOURCE_SHA256" ]] || {
  echo "FAIL: app icon source SHA-256 does not match the reviewed asset" >&2
  exit 1
}
source_bytes="$(wc -c < "$SOURCE_PNG" | tr -d '[:space:]')"
[[ "$source_bytes" -le "$MAX_SOURCE_BYTES" ]] || {
  echo "FAIL: app icon source exceeds the 500 KiB repository limit" >&2
  exit 1
}
grep -Fq "$EXPECTED_SOURCE_SHA256" "$SOURCE_README" || {
  echo "FAIL: app icon README is not synchronized with the reviewed SHA-256" >&2
  exit 1
}

source_property() {
  local property="$1"
  sips -g "$property" "$SOURCE_PNG" \
    | awk -F': ' -v property="$property" '$1 ~ property "$" { print $2 }'
}

[[ "$(source_property pixelWidth)" == "1024" ]] || {
  echo "FAIL: app icon source width is not 1024 pixels" >&2
  exit 1
}
[[ "$(source_property pixelHeight)" == "1024" ]] || {
  echo "FAIL: app icon source height is not 1024 pixels" >&2
  exit 1
}
[[ "$(source_property format)" == "png" ]] || {
  echo "FAIL: app icon source is not a PNG" >&2
  exit 1
}
[[ "$(source_property hasAlpha)" == "no" ]] || {
  echo "FAIL: app icon source must use a full-bleed opaque background" >&2
  exit 1
}
[[ "$(source_property space)" == "RGB" ]] || {
  echo "FAIL: app icon source must use an RGB color space" >&2
  exit 1
}

"$GENERATOR" "$SOURCE_PNG" "$OUTPUT_ICNS"
[[ -s "$OUTPUT_ICNS" ]] || {
  echo "FAIL: app icon generator produced no ICNS artifact" >&2
  exit 1
}

iconutil -c iconset "$OUTPUT_ICNS" -o "$EXTRACTED_ICONSET"
swift "$RENDITION_RENDERER" verify "$EXTRACTED_ICONSET"
for expected_and_pixels in \
  icon_16x16.png:16 \
  icon_16x16@2x.png:32 \
  icon_32x32.png:32 \
  icon_32x32@2x.png:64 \
  icon_128x128.png:128 \
  icon_128x128@2x.png:256 \
  icon_256x256.png:256 \
  icon_256x256@2x.png:512 \
  icon_512x512.png:512 \
  icon_512x512@2x.png:1024; do
  expected="${expected_and_pixels%%:*}"
  expected_pixels="${expected_and_pixels##*:}"
  [[ -f "$EXTRACTED_ICONSET/$expected" ]] || {
    echo "FAIL: generated ICNS is missing $expected" >&2
    exit 1
  }
  actual_width="$(sips -g pixelWidth "$EXTRACTED_ICONSET/$expected" \
    | awk -F': ' '$1 ~ /pixelWidth$/ { print $2 }')"
  actual_height="$(sips -g pixelHeight "$EXTRACTED_ICONSET/$expected" \
    | awk -F': ' '$1 ~ /pixelHeight$/ { print $2 }')"
  [[ "$actual_width" == "$expected_pixels" && "$actual_height" == "$expected_pixels" ]] || {
    echo "FAIL: generated $expected is not ${expected_pixels}x${expected_pixels}" >&2
    exit 1
  }
done

echo "App icon generation test passed."
