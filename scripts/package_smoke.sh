#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/stage_report.sh
source "$(dirname "${BASH_SOURCE[0]}")/stage_report.sh"

REPORT_LANE=release
REPORT_TITLE='macOS package smoke test'
WORKER_CACHE=auto
MLX_RESOURCE_BUNDLE_NAME=mlx-swift_Cmlx.bundle

verify_xcode_resource_accessor() {
  local bundle_name="$1"
  local accessor=""
  local candidate
  local accessor_root
  accessor_root="$(dirname "$(dirname "$RAW_BUILD_DIR")")/Intermediates.noindex"

  while IFS= read -r candidate; do
    if grep -Fq "let bundleName = \"$bundle_name\"" "$candidate"; then
      accessor="$candidate"
      break
    fi
  done < <(find "$accessor_root" -type f -name resource_bundle_accessor.swift -print)

  [[ -n "$accessor" ]] || error "Xcode resource accessor not found for: $bundle_name"
  grep -Fq "Bundle.main.resourceURL" "$accessor" \
    || error "Resource accessor does not support app Contents/Resources: $bundle_name"
  if grep -Fq "let buildPath =" "$accessor"; then
    error "Resource accessor contains a machine-local build path: $bundle_name"
  fi
}

check_package() (
  PACKAGE_SMOKE_ROOT="$(mktemp -d)"
  trap 'rm -rf -- "$PACKAGE_SMOKE_ROOT"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  BUILD_RESULT="$PACKAGE_SMOKE_ROOT/build-result.json"
  info "Building the release configuration..."
  locked_swift release --worker-cache "$WORKER_CACHE" --result-file "$BUILD_RESULT"
  RAW_BUILD_DIR="$(locked_swift receipt "$BUILD_RESULT" --field buildDirectory)"

  info "Checking relocatable SwiftPM resource accessors..."
  verify_xcode_resource_accessor "RillMacOS_RillApp"
  verify_xcode_resource_accessor "RillMacOS_RillUI"

  info "Smoke-testing app bundle assembly and ad-hoc signing..."
  "$SCRIPT_DIR/assemble_app_bundle.sh" \
    --build-result "$BUILD_RESULT" \
    --app-bundle "$PACKAGE_SMOKE_ROOT/Rill.app" \
    --version "0.0.0" \
    --build-number "0" \
    --build-kind "preflight" \
    --source-revision "$SOURCE_REVISION" \
    --source-dirty "$SOURCE_DIRTY" \
    --version-label "0.0.0-preflight+${SOURCE_REVISION:0:12}"
  codesign --force --sign - \
    "$PACKAGE_SMOKE_ROOT/Rill.app/Contents/Helpers/$MLX_RESOURCE_BUNDLE_NAME"
  codesign --force --options runtime --sign - \
    "$PACKAGE_SMOKE_ROOT/Rill.app/Contents/Helpers/RillSpeechWorker"
  uv run --no-build --script "$SCRIPT_DIR/assemble_input_method.py" \
    --sign-existing "$PACKAGE_SMOKE_ROOT/Rill.app/Contents/Helpers/RillInputMethod.app"
  codesign --force --options runtime --sign - "$PACKAGE_SMOKE_ROOT/Rill.app"
  codesign --verify --deep --strict --verbose=2 "$PACKAGE_SMOKE_ROOT/Rill.app"
  "$PACKAGE_SMOKE_ROOT/Rill.app/Contents/Helpers/RillSpeechWorker" </dev/null

  uv run --no-build --script "$SCRIPT_DIR/validate_input_method.py" bundle \
    "$PACKAGE_SMOKE_ROOT/Rill.app/Contents/Helpers/RillInputMethod.app"
  if [[ -n "${RILL_PREFLIGHT_APP_DIR:-}" ]]; then
    check_working_diff
    verify_report_source verify
    info "Saving the smoke-tested app for native interaction QA..."
    mkdir -p "$RILL_PREFLIGHT_APP_DIR"
    local archive="Rill-preflight-$SOURCE_REVISION.zip"
    [[ ! -e "$RILL_PREFLIGHT_APP_DIR/$archive" && ! -L "$RILL_PREFLIGHT_APP_DIR/$archive" ]] \
      || error "Smoke-test app archive already exists: $RILL_PREFLIGHT_APP_DIR/$archive"
    ditto -c -k --sequesterRsrc --keepParent \
      "$PACKAGE_SMOKE_ROOT/Rill.app" "$RILL_PREFLIGHT_APP_DIR/$archive"
    (
      cd "$RILL_PREFLIGHT_APP_DIR"
      shasum -a 256 "$archive" >"$archive.sha256"
      printf 'source_revision=%s\nsource_dirty=%s\nsource_fingerprint=%s\nbuild_kind=preflight\nsigning=ad-hoc\n' \
        "$SOURCE_REVISION" "$SOURCE_DIRTY" "$SOURCE_FINGERPRINT" >"$archive.source.txt"
    )
  fi
)

run_package_smoke() {
  cd "$PROJECT_DIR"
  start_report
  trap 'finish_report "$?"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  run_stage toolchain check_toolchain
  require_command codesign
  if $CLEAN_BUILD; then
    run_stage clean locked_swift clean --configuration release
  fi
  run_stage release check_package
  run_stage working-diff check_working_diff
  report_source_evidence
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1-}" in
  '') ;;
  --clean)
    [[ "$#" -eq 1 ]] || error "Usage: $0 [--clean]"
    CLEAN_BUILD=true
    WORKER_CACHE=off
    ;;
  --help | -h)
    echo "Usage: $0 [--clean]"
    exit
    ;;
  *) error "Usage: $0 [--clean]" ;;
  esac
  run_package_smoke
fi
