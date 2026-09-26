#!/usr/bin/env bash
#
# Assemble and validate an unsigned Rill.app from an existing SwiftPM Xcode build.
# This script intentionally does not build, test, sign, or invoke preflight.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

APP_NAME="Rill"
BUNDLE_ID="dev.zrr.Rill"
APP_EXECUTABLE_PRODUCT="RillApp"
SPEECH_WORKER_PRODUCT="RillSpeechWorker"
INPUT_METHOD_PRODUCT="RillInputMethod"
MIN_MACOS="14.0"
OWN_RESOURCE_BUNDLE="RillMacOS_RillApp.bundle"
MLX_RESOURCE_BUNDLE="mlx-swift_Cmlx.bundle"
WORKFLOW_MANIFEST="BuiltinWorkflowManifest.json"
PROJECT_DOCUMENTS=("LICENSE" "README.md")
THIRD_PARTY_NOTICES_NAME="THIRD_PARTY_NOTICES.md"
LOCAL_MODEL_NOTICES_NAME="LOCAL_MODEL_NOTICES.md"
PRIVACY_NOTICE_NAME="PRIVACY.md"
APP_BUNDLE_RESOURCES_ROOT="$PROJECT_DIR/Resources/AppBundle"
APP_ICON_SOURCE="$PROJECT_DIR/Resources/AppIcon/AppIcon-1024-routed-voice-cursor.png"
APP_ICON_NAME="Rill.icns"
INFO_PLIST_LOCALIZATIONS=("en" "zh-Hans")
INFO_PLIST_LOCALIZATION_KEYS=(
  "CFBundleDisplayName"
  "CFBundleName"
  "NSMicrophoneUsageDescription"
)

info() { echo "▸ $*"; }
error() {
  echo "✗ $*" >&2
  exit 1
}

verify_release_executable() {
  local executable="${1-}"
  local MIN_MACOS="14.0"
  local REQUIRED_ARCHITECTURE="arm64"
  local architectures=""

  [[ -n "$executable" ]] || error "usage: $0 verify-executable /path/to/executable"
  command -v lipo >/dev/null 2>&1 || error "Required command not found: lipo"
  command -v xcrun >/dev/null 2>&1 || error "Required command not found: xcrun"
  [[ -f "$executable" && -x "$executable" && ! -L "$executable" ]] \
    || error "Release executable must be an executable regular non-symlink file: $executable"
  if ! architectures="$(lipo "$executable" -archs 2>&1)"; then
    error "Cannot inspect release executable architecture: $executable"
  fi
  [[ "$architectures" == "$REQUIRED_ARCHITECTURE" ]] \
    || error "Release executable must contain only arm64: $executable"

  verify_build_version() {
    local architecture="$1"
    local build_output=""
    local summary=""
    local build_command_count=""
    local platform_count=""
    local macos_platform_count=""
    local minos_count=""
    local expected_minos_count=""

    if ! build_output="$(
      xcrun vtool -arch "$architecture" -show-build "$executable" 2>&1
    )"; then
      error "Cannot inspect LC_BUILD_VERSION for $architecture: $executable"
    fi
    summary="$(
      printf '%s\n' "$build_output" | awk -v expected_minos="$MIN_MACOS" '
        $1 == "cmd" && $2 == "LC_BUILD_VERSION" { build_command_count += 1 }
        $1 == "platform" {
          platform_count += 1
          if ($2 == "MACOS") { macos_platform_count += 1 }
        }
        $1 == "minos" {
          minos_count += 1
          if ($2 == expected_minos) { expected_minos_count += 1 }
        }
        END {
          printf "%d|%d|%d|%d|%d", build_command_count, platform_count,
            macos_platform_count, minos_count, expected_minos_count
        }
      '
    )"
    IFS='|' read -r \
      build_command_count \
      platform_count \
      macos_platform_count \
      minos_count \
      expected_minos_count <<<"$summary"
    [[ "$build_command_count" == "1" ]] \
      || error "Release executable $architecture slice must contain exactly one LC_BUILD_VERSION: $executable"
    [[ "$platform_count" == "1" && "$macos_platform_count" == "1" ]] \
      || error "Release executable $architecture slice must target the macOS platform: $executable"
    [[ "$minos_count" == "1" && "$expected_minos_count" == "1" ]] \
      || error "Release executable $architecture slice must require macOS $MIN_MACOS exactly: $executable"
  }

  verify_build_version "$REQUIRED_ARCHITECTURE"
}

write_info_plist() {
  uv run --quiet --no-project --python '>=3.11' python - "$@" <<'PY'
import plistlib
import sys
from pathlib import Path

if len(sys.argv) != 9:
    print(
        "usage: assemble_app_bundle.sh write-info-plist PATH VERSION BUILD_NUMBER "
        "BUILD_KIND SOURCE_REVISION SOURCE_DIRTY VERSION_LABEL MICROPHONE_DESCRIPTION",
        file=sys.stderr,
    )
    raise SystemExit(2)
(
    path,
    version,
    build_number,
    build_kind,
    source_revision,
    source_dirty,
    version_label,
    microphone_usage_description,
) = sys.argv[1:]
payload = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleExecutable": "Rill",
    "CFBundleGetInfoString": version_label,
    "CFBundleIconFile": "Rill.icns",
    "CFBundleIdentifier": "dev.zrr.Rill",
    "CFBundleName": "Rill",
    "CFBundleDisplayName": "Rill",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": version,
    "CFBundleVersion": build_number,
    "CFBundleInfoDictionaryVersion": "6.0",
    "LSMinimumSystemVersion": "14.0",
    "LSUIElement": True,
    "NSMicrophoneUsageDescription": microphone_usage_description,
    "NSPrincipalClass": "NSApplication",
    "RillBuildKind": build_kind,
    "RillSourceDirty": source_dirty == "true",
    "RillSourceRevision": source_revision,
    "RillVersionLabel": version_label,
}
try:
    with Path(path).open("wb") as output:
        plistlib.dump(payload, output, fmt=plistlib.FMT_XML, sort_keys=True)
except (OSError, ValueError) as error:
    print(f"cannot write Info.plist: {error}", file=sys.stderr)
    raise SystemExit(2)
PY
}

generate_app_icon() {
  local source_png="${1-}"
  local output_icns="${2-}"
  local rendition_renderer="$SCRIPT_DIR/render_app_icon_renditions.swift"
  local expected_source_sha256="c6c6bd3647ca2cc2ae860c27832d2f8150c5832320ed7b4b7b95eae902fe2642"
  local max_source_bytes=$((500 * 1024))
  local temporary_directory=""
  local iconset=""
  local reviewed_source=""
  local source_sha256=""
  local source_bytes=""
  local pixel_width=""
  local pixel_height=""

  [[ -n "$source_png" && -n "$output_icns" ]] || error "usage: $0 app-icon SOURCE_PNG OUTPUT_ICNS"
  command -v sips >/dev/null 2>&1 || error "sips is required"
  command -v iconutil >/dev/null 2>&1 || error "iconutil is required"
  command -v shasum >/dev/null 2>&1 || error "shasum is required"
  command -v swift >/dev/null 2>&1 || error "Swift is required"
  [[ -f "$source_png" ]] || error "app icon source is missing: $source_png"
  [[ -f "$rendition_renderer" ]] || error "app icon rendition renderer is missing: $rendition_renderer"
  temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/rill-app-icon.XXXXXX")"
  iconset="$temporary_directory/Rill.iconset"
  reviewed_source="$temporary_directory/AppIcon-1024-reviewed.png"
  mkdir -p "$iconset" "$(dirname "$output_icns")"
  cp "$source_png" "$reviewed_source"
  source_sha256="$(shasum -a 256 "$reviewed_source" | awk '{ print $1 }')"
  [[ "$source_sha256" == "$expected_source_sha256" ]] \
    || error "app icon source SHA-256 does not match the reviewed asset"
  source_bytes="$(wc -c <"$reviewed_source" | tr -d '[:space:]')"
  [[ "$source_bytes" -le "$max_source_bytes" ]] \
    || error "app icon source exceeds the 500 KiB repository limit"
  pixel_width="$(sips -g pixelWidth "$reviewed_source" | awk '/pixelWidth:/ { print $2 }')"
  pixel_height="$(sips -g pixelHeight "$reviewed_source" | awk '/pixelHeight:/ { print $2 }')"
  [[ "$pixel_width" == "1024" && "$pixel_height" == "1024" ]] \
    || error "app icon source must be exactly 1024 x 1024 pixels"
  swift "$rendition_renderer" render "$reviewed_source" "$iconset"
  swift "$rendition_renderer" verify "$iconset"
  rm -f "$output_icns"
  iconutil -c icns "$iconset" -o "$output_icns"
  rm -rf "$temporary_directory"
  [[ -s "$output_icns" ]] || error "iconutil did not create a non-empty ICNS file"
}

render_brand_assets() {
  local source_dir="$PROJECT_DIR/Resources/AppIcon"
  local output_dir="$PROJECT_DIR/Sources/RillApp/Resources"
  local temporary_directory=""

  command -v rsvg-convert >/dev/null 2>&1 || error "rsvg-convert is required (brew install librsvg)"
  temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/rill-brand-assets.XXXXXX")"
  rsvg-convert "$source_dir/Rill.svg" \
    --output "$source_dir/AppIcon-1024-routed-voice-cursor.png"
  export SOURCE_DATE_EPOCH=0
  rsvg-convert --format pdf --dpi-x 72 --dpi-y 72 \
    "$source_dir/RillMenuBar.svg" \
    --output "$output_dir/RillMenuBarTemplate.pdf"
  echo '#records-indicator { opacity: 1; }' >"$temporary_directory/records.css"
  rsvg-convert --format pdf --dpi-x 72 --dpi-y 72 \
    --stylesheet "$temporary_directory/records.css" \
    "$source_dir/RillMenuBar.svg" \
    --output "$output_dir/RillMenuBarRecordsTemplate.pdf"
  shasum -a 256 "$source_dir/Rill.svg" \
    "$source_dir/AppIcon-1024-routed-voice-cursor.png" \
    "$source_dir/RillMenuBar.svg" \
    "$output_dir/RillMenuBarTemplate.pdf" \
    "$output_dir/RillMenuBarRecordsTemplate.pdf"
  rm -rf "$temporary_directory"
}

case "${1-}" in
verify-executable)
  shift
  verify_release_executable "$@"
  exit
  ;;
write-info-plist)
  shift
  write_info_plist "$@"
  exit
  ;;
app-icon)
  shift
  generate_app_icon "$@"
  exit
  ;;
render-brand)
  render_brand_assets
  exit
  ;;
esac

usage() {
  cat <<EOF
Usage: $0 (--build-dir DIR | --build-result JSON) --app-bundle PATH --version VERSION --build-number NUMBER \\
  --build-kind KIND --source-revision REVISION --source-dirty BOOL --version-label LABEL

Assembles an unsigned ${APP_NAME}.app from an existing SwiftPM Xcode release build.
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || error "Required command not found: $1"
}

BUILD_DIR=""
BUILD_RESULT=""
CHECKOUTS_DIR="$PROJECT_DIR/.build/checkouts"
APP_BUNDLE=""
VERSION=""
BUILD_NUMBER=""
BUILD_KIND=""
SOURCE_REVISION=""
SOURCE_DIRTY=""
VERSION_LABEL=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
  --build-dir | --build-result | --checkouts-dir | --app-bundle | --version | --build-number | --build-kind | --source-revision | --source-dirty | --version-label)
    [[ "$#" -ge 2 ]] || error "Missing value for $1"
    case "$1" in
    --build-dir) BUILD_DIR="$2" ;;
    --build-result) BUILD_RESULT="$2" ;;
    --checkouts-dir) CHECKOUTS_DIR="$2" ;;
    --app-bundle) APP_BUNDLE="$2" ;;
    --version) VERSION="$2" ;;
    --build-number) BUILD_NUMBER="$2" ;;
    --build-kind) BUILD_KIND="$2" ;;
    --source-revision) SOURCE_REVISION="$2" ;;
    --source-dirty) SOURCE_DIRTY="$2" ;;
    --version-label) VERSION_LABEL="$2" ;;
    esac
    shift 2
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    error "Unknown argument: $1"
    ;;
  esac
done

if [[ -n "$BUILD_RESULT" ]]; then
  [[ -z "$BUILD_DIR" ]] || error "--build-dir and --build-result are mutually exclusive"
  BUILD_DIR="$("$SCRIPT_DIR/preflight.sh" swift receipt "$BUILD_RESULT" --field productsDirectory)"
  CHECKOUTS_DIR="$("$SCRIPT_DIR/preflight.sh" swift receipt "$BUILD_RESULT" --field checkoutsDirectory)"
fi
[[ -n "$BUILD_DIR" ]] || error "--build-dir or --build-result is required"
[[ -n "$APP_BUNDLE" ]] || error "--app-bundle is required"
[[ -n "$VERSION" ]] || error "--version is required"
[[ -n "$BUILD_NUMBER" ]] || error "--build-number is required"
[[ -n "$BUILD_KIND" ]] || error "--build-kind is required"
[[ -n "$SOURCE_REVISION" ]] || error "--source-revision is required"
[[ -n "$SOURCE_DIRTY" ]] ||
  error "--source-dirty is required"
[[ -n "$VERSION_LABEL" ]] || error "--version-label is required"
[[ "$APP_BUNDLE" == *.app ]] || error "--app-bundle must end in .app"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  error "--version must be a numeric semantic version"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || error "--build-number must be numeric"
[[ "$BUILD_KIND" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || error "--build-kind is invalid"
[[ "$SOURCE_REVISION" =~ ^[[:xdigit:]]{40,64}$ ]] || error "--source-revision is invalid"
[[ "$SOURCE_DIRTY" == "true" || "$SOURCE_DIRTY" == "false" ]] ||
  error "--source-dirty must be true or false"
[[ "$VERSION_LABEL" =~ ^[0-9A-Za-z][0-9A-Za-z.+-]{0,127}$ ]] ||
  error "--version-label is invalid"

require_command ditto
require_command diff
require_command cmp
require_command plutil
require_command uv

for document in "${PROJECT_DOCUMENTS[@]}"; do
  [[ -s "$PROJECT_DIR/$document" ]] || error "Project document not found or empty: $document"
done

THIRD_PARTY_NOTICES_SOURCE="$PROJECT_DIR/$THIRD_PARTY_NOTICES_NAME"
LOCAL_MODEL_NOTICES_SOURCE="$PROJECT_DIR/$LOCAL_MODEL_NOTICES_NAME"
PRIVACY_NOTICE_SOURCE="$PROJECT_DIR/$PRIVACY_NOTICE_NAME"
THIRD_PARTY_NOTICES_GENERATOR="$SCRIPT_DIR/generate_third_party_notices.py"
[[ -f "$THIRD_PARTY_NOTICES_GENERATOR" ]] ||
  error "Third-party notice generator not found: $THIRD_PARTY_NOTICES_GENERATOR"
uv run --script "$THIRD_PARTY_NOTICES_GENERATOR" --check --checkouts-dir "$CHECKOUTS_DIR"
[[ -f "$THIRD_PARTY_NOTICES_SOURCE" ]] ||
  error "Generated third-party notices not found: $THIRD_PARTY_NOTICES_SOURCE"
[[ -f "$LOCAL_MODEL_NOTICES_SOURCE" ]] ||
  error "Local model notices not found: $LOCAL_MODEL_NOTICES_SOURCE"
[[ -f "$PRIVACY_NOTICE_SOURCE" ]] ||
  error "Technical privacy notice not found: $PRIVACY_NOTICE_SOURCE"
[[ -f "$APP_ICON_SOURCE" ]] || error "App icon source not found: $APP_ICON_SOURCE"
[[ -f "$SCRIPT_DIR/render_app_icon_renditions.swift" ]] || error "App icon rendition renderer not found"

for localization in "${INFO_PLIST_LOCALIZATIONS[@]}"; do
  localized_info_source="$APP_BUNDLE_RESOURCES_ROOT/$localization.lproj/InfoPlist.strings"
  [[ -f "$localized_info_source" ]] ||
    error "Localized Info.plist strings not found: $localization"
  plutil -lint "$localized_info_source" >/dev/null ||
    error "Invalid localized Info.plist strings: $localization"
  for localized_key in "${INFO_PLIST_LOCALIZATION_KEYS[@]}"; do
    plutil -extract "$localized_key" raw -o - "$localized_info_source" >/dev/null ||
      error "Missing $localized_key in localized Info.plist strings: $localization"
  done
done

MICROPHONE_USAGE_DESCRIPTION="$(
  plutil -extract NSMicrophoneUsageDescription raw -o - \
    "$APP_BUNDLE_RESOURCES_ROOT/en.lproj/InfoPlist.strings"
)"

[[ -d "$BUILD_DIR" ]] || error "Build directory not found: $BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd -P)"

case "$APP_BUNDLE" in
/*) ;;
*) APP_BUNDLE="$PWD/$APP_BUNDLE" ;;
esac

EXECUTABLE_SOURCE="$BUILD_DIR/$APP_EXECUTABLE_PRODUCT"
SPEECH_WORKER_SOURCE="$BUILD_DIR/$SPEECH_WORKER_PRODUCT"
INPUT_METHOD_SOURCE="$BUILD_DIR/$INPUT_METHOD_PRODUCT"
[[ -x "$INPUT_METHOD_SOURCE" ]] || error "Input method executable not found: $INPUT_METHOD_SOURCE"
[[ -x "$EXECUTABLE_SOURCE" ]] ||
  error "Release executable not found or not executable: $EXECUTABLE_SOURCE"
[[ -x "$SPEECH_WORKER_SOURCE" ]] ||
  error "Speech worker not found or not executable: $SPEECH_WORKER_SOURCE"
verify_release_executable "$EXECUTABLE_SOURCE"
verify_release_executable "$SPEECH_WORKER_SOURCE"
verify_release_executable "$INPUT_METHOD_SOURCE"

shopt -s nullglob
RESOURCE_SOURCES=("$BUILD_DIR"/*.bundle)
shopt -u nullglob
[[ "${#RESOURCE_SOURCES[@]}" -gt 0 ]] || error "No SwiftPM resource bundles found in: $BUILD_DIR"

own_bundle_found=false
mlx_bundle_found=false
dependency_bundle_count=0
for source_bundle in "${RESOURCE_SOURCES[@]}"; do
  bundle_name="$(basename "$source_bundle")"
  bundle_info_plist="$source_bundle/Contents/Info.plist"
  [[ -f "$bundle_info_plist" ]] ||
    error "Resource bundle is not an Xcode build product: $bundle_name"
  plutil -lint "$bundle_info_plist" >/dev/null ||
    error "Invalid resource bundle Info.plist: $bundle_name"
  if [[ "$bundle_name" == "$OWN_RESOURCE_BUNDLE" ]]; then
    own_bundle_found=true
  elif [[ "$bundle_name" == "$MLX_RESOURCE_BUNDLE" ]]; then
    mlx_bundle_found=true
    ((dependency_bundle_count += 1))
  else
    ((dependency_bundle_count += 1))
  fi
done

$own_bundle_found || error "Required app resource bundle not found: $OWN_RESOURCE_BUNDLE"
$mlx_bundle_found ||
  error "Required MLX resource bundle not found: $MLX_RESOURCE_BUNDLE"

rm -rf "$APP_BUNDLE"
mkdir -p \
  "$APP_BUNDLE/Contents/MacOS" \
  "$APP_BUNDLE/Contents/Helpers" \
  "$APP_BUNDLE/Contents/Resources"

ditto "$EXECUTABLE_SOURCE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
ditto \
  "$SPEECH_WORKER_SOURCE" \
  "$APP_BUNDLE/Contents/Helpers/$SPEECH_WORKER_PRODUCT"

uv run --no-build --locked --script "$SCRIPT_DIR/assemble_input_method.py" --unsigned \
  --executable "$INPUT_METHOD_SOURCE" --output "$APP_BUNDLE/Contents/Helpers/RillInputMethod.app"

# Verify the exact bytes that will be signed. The build directory can be
# replaced by a concurrent build after the source checks above; validating the
# packaged destinations closes that copy-time race.
verify_release_executable \
  "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
verify_release_executable \
  "$APP_BUNDLE/Contents/Helpers/$SPEECH_WORKER_PRODUCT"

for source_bundle in "${RESOURCE_SOURCES[@]}"; do
  bundle_name="$(basename "$source_bundle")"
  if [[ "$bundle_name" == "$MLX_RESOURCE_BUNDLE" ]]; then
    # Cmlx discovers its Metal shader bundle relative to the executable that
    # loads it. RillSpeechWorker is an independent command-line helper, so its
    # MLX resources must be colocated with that helper rather than the app's
    # main Resources directory.
    resource_destination="$APP_BUNDLE/Contents/Helpers/$bundle_name"
  else
    resource_destination="$APP_BUNDLE/Contents/Resources/$bundle_name"
  fi

  ditto "$source_bundle" "$resource_destination"
  [[ -n "$(find "$resource_destination" -mindepth 1 -print -quit)" ]] ||
    error "Resource bundle is empty: $bundle_name"
done

for document in "${PROJECT_DOCUMENTS[@]}"; do
  ditto "$PROJECT_DIR/$document" "$APP_BUNDLE/Contents/Resources/$document"
  cmp -s "$PROJECT_DIR/$document" "$APP_BUNDLE/Contents/Resources/$document" ||
    error "Packaged project document differs from the repository source: $document"
done

THIRD_PARTY_NOTICES_DESTINATION="$APP_BUNDLE/Contents/Resources/$THIRD_PARTY_NOTICES_NAME"
ditto "$THIRD_PARTY_NOTICES_SOURCE" "$THIRD_PARTY_NOTICES_DESTINATION"
LOCAL_MODEL_NOTICES_DESTINATION="$APP_BUNDLE/Contents/Resources/$LOCAL_MODEL_NOTICES_NAME"
ditto "$LOCAL_MODEL_NOTICES_SOURCE" "$LOCAL_MODEL_NOTICES_DESTINATION"
PRIVACY_NOTICE_DESTINATION="$APP_BUNDLE/Contents/Resources/$PRIVACY_NOTICE_NAME"
ditto "$PRIVACY_NOTICE_SOURCE" "$PRIVACY_NOTICE_DESTINATION"
cmp -s "$PRIVACY_NOTICE_SOURCE" "$PRIVACY_NOTICE_DESTINATION" ||
  error "Packaged technical privacy notice differs from the repository source"
APP_ICON_DESTINATION="$APP_BUNDLE/Contents/Resources/$APP_ICON_NAME"
generate_app_icon "$APP_ICON_SOURCE" "$APP_ICON_DESTINATION"

for localization in "${INFO_PLIST_LOCALIZATIONS[@]}"; do
  localized_info_source="$APP_BUNDLE_RESOURCES_ROOT/$localization.lproj/InfoPlist.strings"
  localized_info_destination="$APP_BUNDLE/Contents/Resources/$localization.lproj/InfoPlist.strings"
  mkdir -p "$(dirname "$localized_info_destination")"
  ditto "$localized_info_source" "$localized_info_destination"
done

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
write_info_plist \
  "$INFO_PLIST" \
  "$VERSION" \
  "$BUILD_NUMBER" \
  "$BUILD_KIND" \
  "$SOURCE_REVISION" \
  "$SOURCE_DIRTY" \
  "$VERSION_LABEL" \
  "$MICROPHONE_USAGE_DESCRIPTION"

plutil -lint "$INFO_PLIST" >/dev/null

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"
}

[[ "$(plist_value CFBundleExecutable)" == "$APP_NAME" ]] || error "Invalid CFBundleExecutable"
[[ "$(plist_value CFBundleGetInfoString)" == "$VERSION_LABEL" ]] || error "Invalid display version"
[[ "$(plist_value CFBundleIconFile)" == "$APP_ICON_NAME" ]] || error "Invalid CFBundleIconFile"
[[ "$(plist_value CFBundleIdentifier)" == "$BUNDLE_ID" ]] || error "Invalid CFBundleIdentifier"
[[ "$(plist_value CFBundlePackageType)" == "APPL" ]] || error "Invalid CFBundlePackageType"
[[ "$(plist_value CFBundleShortVersionString)" == "$VERSION" ]] || error "Invalid release version"
[[ "$(plist_value CFBundleVersion)" == "$BUILD_NUMBER" ]] || error "Invalid build number"
[[ "$(plist_value RillBuildKind)" == "$BUILD_KIND" ]] || error "Invalid build kind"
[[ "$(plist_value RillSourceRevision)" == "$SOURCE_REVISION" ]] || error "Invalid source revision"
[[ "$(plutil -extract RillSourceDirty raw -o - "$INFO_PLIST")" == "$SOURCE_DIRTY" ]] ||
  error "Invalid source dirty flag"
[[ "$(plist_value RillVersionLabel)" == "$VERSION_LABEL" ]] || error "Invalid version label"
[[ "$(plist_value LSMinimumSystemVersion)" == "$MIN_MACOS" ]] || error "Invalid minimum macOS version"
[[ -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ]] || error "Assembled executable is not executable"
[[ -x "$APP_BUNDLE/Contents/Helpers/$SPEECH_WORKER_PRODUCT" ]] ||
  error "Assembled speech worker is not executable"
[[ -s "$APP_ICON_DESTINATION" ]] || error "Packaged app icon is missing or empty"

for source_bundle in "${RESOURCE_SOURCES[@]}"; do
  bundle_name="$(basename "$source_bundle")"
  if [[ "$bundle_name" == "$MLX_RESOURCE_BUNDLE" ]]; then
    resource_destination="$APP_BUNDLE/Contents/Helpers/$bundle_name"
    [[ ! -e "$APP_BUNDLE/Contents/Resources/$bundle_name" ]] ||
      error "MLX resource bundle must be owned by the speech worker"
  else
    resource_destination="$APP_BUNDLE/Contents/Resources/$bundle_name"
  fi

  [[ -d "$resource_destination" ]] || error "Missing copied bundle: $bundle_name"
  [[ ! -e "$APP_BUNDLE/$bundle_name" ]] || error "Resource bundle must not be placed in the app root: $bundle_name"
  plutil -lint "$resource_destination/Contents/Info.plist" >/dev/null ||
    error "Packaged resource bundle has an invalid Info.plist: $bundle_name"
  diff -qr "$source_bundle" "$resource_destination" >/dev/null ||
    error "Packaged resource bundle differs from build output: $bundle_name"
done

MANIFEST_SOURCE="$BUILD_DIR/$OWN_RESOURCE_BUNDLE/Contents/Resources/$WORKFLOW_MANIFEST"
MANIFEST_DESTINATION="$APP_BUNDLE/Contents/Resources/$OWN_RESOURCE_BUNDLE/Contents/Resources/$WORKFLOW_MANIFEST"
[[ -f "$MANIFEST_SOURCE" ]] || error "Built-in workflow manifest not found: $MANIFEST_SOURCE"
[[ -f "$MANIFEST_DESTINATION" ]] || error "Built-in workflow manifest was not packaged"
cmp -s "$MANIFEST_SOURCE" "$MANIFEST_DESTINATION" || error "Packaged workflow manifest differs from build output"
[[ -f "$THIRD_PARTY_NOTICES_DESTINATION" ]] || error "Third-party notices were not packaged"
cmp -s "$THIRD_PARTY_NOTICES_SOURCE" "$THIRD_PARTY_NOTICES_DESTINATION" ||
  error "Packaged third-party notices differ from the reviewed source"
[[ -f "$LOCAL_MODEL_NOTICES_DESTINATION" ]] || error "Local model notices were not packaged"
cmp -s "$LOCAL_MODEL_NOTICES_SOURCE" "$LOCAL_MODEL_NOTICES_DESTINATION" ||
  error "Packaged local model notices differ from the reviewed source"

for localization in "${INFO_PLIST_LOCALIZATIONS[@]}"; do
  localized_info_source="$APP_BUNDLE_RESOURCES_ROOT/$localization.lproj/InfoPlist.strings"
  localized_info_destination="$APP_BUNDLE/Contents/Resources/$localization.lproj/InfoPlist.strings"
  [[ -f "$localized_info_destination" ]] ||
    error "Localized Info.plist strings were not packaged: $localization"
  plutil -lint "$localized_info_destination" >/dev/null ||
    error "Packaged localized Info.plist strings are invalid: $localization"
  cmp -s "$localized_info_source" "$localized_info_destination" ||
    error "Packaged localized Info.plist strings differ from source: $localization"
done

uv run --script "$SCRIPT_DIR/generate_builtin_workflows.py" --validate \
  "$MANIFEST_DESTINATION"

info "Assembled unsigned $APP_BUNDLE (${#RESOURCE_SOURCES[@]} resource bundles; $dependency_bundle_count dependencies)"
