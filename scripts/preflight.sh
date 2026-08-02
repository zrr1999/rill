#!/usr/bin/env bash
#
# Rill deterministic preflight shared by local releases and CI.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
BUILD_DIR=""
SOURCE_REVISION=""
SOURCE_DIRTY="false"
MLX_RESOURCE_BUNDLE_NAME="mlx-swift_Cmlx.bundle"

info() { echo "▸ $*"; }
error() {
  echo "✗ $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || error "Required command not found: $1"
}

verify_python_toolchain() {
  local output=""
  local major=""
  local minor=""
  local patch=""
  local version=""

  if ! output="$(python3 --version 2>&1)"; then
    error "Cannot determine the Python version"
  fi
  if [[ ! "$output" =~ Python[[:space:]]+([0-9]+)\.([0-9]+)(\.([0-9]+))? ]]; then
    error "Cannot parse the Python version: $output"
  fi
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[4]:-0}"
  version="$major.$minor.$patch"
  if ((major < 3 || (major == 3 && minor < 11))); then
    error "Python 3.11 or newer is required (found $version)"
  fi
  info "Python toolchain: $version"
}

verify_swift_toolchain() {
  local output=""
  local major=""
  local minor=""
  local patch=""
  local version=""

  if ! output="$(swift --version 2>&1)"; then
    error "Cannot determine the Swift version"
  fi
  if [[ ! "$output" =~ Swift[[:space:]]+version[[:space:]]+([0-9]+)\.([0-9]+)(\.([0-9]+))? ]]; then
    error "Cannot parse the Swift version: $output"
  fi
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[4]:-0}"
  version="$major.$minor.$patch"
  if ((major < 6 || (major == 6 && minor < 2))); then
    error "Swift 6.2 or newer is required (found $version)"
  fi
  info "Swift toolchain: $version"
}

verify_toolchain_versions() {
  verify_python_toolchain
  verify_swift_toolchain
}

report_preflight_evidence() {
  info \
    "Preflight evidence: class=working-source source_revision=$SOURCE_REVISION source_dirty=$SOURCE_DIRTY"
}

verify_xcode_resource_accessor() {
  local bundle_name="$1"
  local accessor=""
  local candidate
  local accessor_root="$PROJECT_DIR/.build/out/Intermediates.noindex"

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

# Keep pure preflight helpers sourceable so release-policy tests exercise the
# same version parsing and minimums used by the actual build.
if [[ "${BASH_SOURCE[0]-}" != "$0" ]]; then
  return 0
fi

require_command git
require_command codesign
require_command python3
require_command swift
verify_toolchain_versions

cd "$PROJECT_DIR"

info "Checking shell syntax..."
bash "$SCRIPT_DIR/check_shell_syntax.sh"

info "Checking repository release artifact hygiene..."
bash "$SCRIPT_DIR/check_release_artifact_hygiene.sh"

info "Checking dependency security policy..."
python3 "$SCRIPT_DIR/tests/dependency_security_test.py"

info "Checking any locked source-control dependencies against the reviewed offline advisory baseline..."
python3 "$SCRIPT_DIR/check_dependency_security.py"

info "Checking secret scan policy..."
bash "$SCRIPT_DIR/tests/secret_scan_test.sh"

info "Scanning Git history and the current source snapshot for secrets..."
bash "$SCRIPT_DIR/check_secrets.sh"

info "Cleaning SwiftPM build artifacts for a deterministic preflight..."
swift package clean

info "Checking generated built-in workflow artifacts..."
python3 "$SCRIPT_DIR/generate_builtin_workflows.py" --check

info "Checking release signing and notarization policy..."
bash "$SCRIPT_DIR/tests/release_config_test.sh"

info "Checking app icon generation..."
bash "$SCRIPT_DIR/tests/app_icon_test.sh"

info "Building the release configuration..."
"$SCRIPT_DIR/build_xcode_release.sh"
BUILD_DIR="$("$SCRIPT_DIR/build_xcode_release.sh" --show-bin-path)"

info "Checking arm64 release executable architectures..."
bash "$SCRIPT_DIR/verify_release_executable.sh" "$BUILD_DIR/RillApp"
bash "$SCRIPT_DIR/verify_release_executable.sh" "$BUILD_DIR/RillSpeechWorker"

info "Checking locked third-party license and notice provenance..."
python3 "$SCRIPT_DIR/tests/third_party_notices_test.py"

info "Checking relocatable SwiftPM resource accessors..."
verify_xcode_resource_accessor "RillMacOS_RillApp"

info "Smoke-testing unsigned app bundle assembly..."
PACKAGE_SMOKE_ROOT="$(mktemp -d)"
SOURCE_REVISION="$(git rev-parse 'HEAD^{commit}')" \
  || error "Cannot determine the preflight source revision"
if [[ -n "$(git status --porcelain=v1 --untracked-files=normal)" ]]; then
  SOURCE_DIRTY="true"
fi
cleanup() {
  rm -rf "$PACKAGE_SMOKE_ROOT"
}
trap cleanup EXIT INT TERM
"$SCRIPT_DIR/assemble_app_bundle.sh" \
  --build-dir "$BUILD_DIR" \
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
codesign --force --options runtime --sign - "$PACKAGE_SMOKE_ROOT/Rill.app"
codesign --verify --deep --strict --verbose=2 "$PACKAGE_SMOKE_ROOT/Rill.app"
cmp -s \
  "$PROJECT_DIR/PRIVACY.md" \
  "$PACKAGE_SMOKE_ROOT/Rill.app/Contents/Resources/PRIVACY.md" \
  || error "Packaged technical privacy notice does not match PRIVACY.md"
cmp -s \
  "$PROJECT_DIR/LOCAL_MODEL_NOTICES.md" \
  "$PACKAGE_SMOKE_ROOT/Rill.app/Contents/Resources/LOCAL_MODEL_NOTICES.md" \
  || error "Packaged local model notices do not match LOCAL_MODEL_NOTICES.md"
cleanup
trap - EXIT INT TERM

info "Cleaning Release build artifacts before the Debug test suite..."
swift package clean

info "Running the test suite..."
"$SCRIPT_DIR/swift_locked.sh" test

info "Checking the working diff for whitespace errors..."
git diff --check
git diff --cached --check

report_preflight_evidence
info "Preflight passed"
