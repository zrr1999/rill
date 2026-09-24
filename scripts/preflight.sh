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
CLEAN_BUILD=false
WORKER_CACHE="auto"
RAW_BUILD_DIR=""
MLX_RESOURCE_BUNDLE_NAME="mlx-swift_Cmlx.bundle"

info() { echo "▸ $*"; }
error() {
  echo "✗ $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || error "Required command not found: $1"
}

verify_uv_toolchain() {
  local output=""
  local python_version=""

  if ! output="$(uv --version 2>&1)"; then
    error "Cannot determine the uv version"
  fi
  if ! python_version="$(uv run --script "$SCRIPT_DIR/report_python_version.py" 2>&1)"; then
    error "Cannot start the uv-managed Python runtime: $python_version"
  fi
  info "uv toolchain: $output; Python runtime: $python_version"
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
  verify_uv_toolchain
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
  local accessor_root
  accessor_root="$(dirname "$(dirname "$RAW_BUILD_DIR")")/Intermediates.noindex"

  while IFS= read -r candidate; do
    if grep -Fq "let bundleName = \"$bundle_name\"" "$candidate"; then
      accessor="$candidate"
      break
    fi
  done < <(find "$accessor_root" -type f -name resource_bundle_accessor.swift -print)

  [[ -n "$accessor" ]] || error "Xcode resource accessor not found for: $bundle_name"
  grep -Fq "Bundle.main.resourceURL" "$accessor" ||
    error "Resource accessor does not support app Contents/Resources: $bundle_name"
  if grep -Fq "let buildPath =" "$accessor"; then
    error "Resource accessor contains a machine-local build path: $bundle_name"
  fi
}

# Keep pure preflight helpers sourceable so release-policy tests exercise the
# same uv-managed Python and Swift minimums used by the actual build.
if [[ "${BASH_SOURCE[0]-}" != "$0" ]]; then
  return 0
fi

while [[ "$#" -gt 0 ]]; do
  case "$1" in
  --clean) CLEAN_BUILD=true; WORKER_CACHE="off" ;;
  --help | -h) echo "Usage: $0 [--clean]"; exit 0 ;;
  *) error "Unknown argument: $1" ;;
  esac
  shift
done

require_command git
require_command codesign
require_command uv
require_command swift
verify_toolchain_versions

cd "$PROJECT_DIR"

info "Checking shell syntax..."
bash "$SCRIPT_DIR/check_shell_syntax.sh"

info "Checking repository release artifact hygiene..."
bash "$SCRIPT_DIR/check_release_artifact_hygiene.sh"

info "Checking Swift module dependencies..."
uv run --no-build --locked --script "$SCRIPT_DIR/check_module_boundaries.py"

info "Checking Record domain boundary..."
bash "$SCRIPT_DIR/check_record_domain_boundary.sh"

info "Running script policy tests..."
bash "$SCRIPT_DIR/tests/run.sh"

info "Checking any locked source-control dependencies against the reviewed offline advisory baseline..."
uv run --script "$SCRIPT_DIR/check_dependency_security.py"

info "Scanning Git history and the current source snapshot for secrets..."
bash "$SCRIPT_DIR/check_secrets.sh"

if $CLEAN_BUILD; then
  "$SCRIPT_DIR/swift_locked.sh" clean
  "$SCRIPT_DIR/swift_locked.sh" clean --configuration release
fi

info "Checking generated built-in workflow artifacts..."
uv run --script "$SCRIPT_DIR/generate_builtin_workflows.py" --check

info "Checking performance benchmark workloads..."
bash "$SCRIPT_DIR/build_benchmarks.sh" --preview-only

PACKAGE_SMOKE_ROOT="$(mktemp -d)"
cleanup() {
  rm -rf "$PACKAGE_SMOKE_ROOT"
}
trap cleanup EXIT INT TERM
BUILD_RESULT="$PACKAGE_SMOKE_ROOT/build-result.json"
info "Building the release configuration..."
"$SCRIPT_DIR/build_xcode_release.sh" --worker-cache "$WORKER_CACHE" --result-file "$BUILD_RESULT"
BUILD_DIR="$("$SCRIPT_DIR/swift_locked.sh" receipt "$BUILD_RESULT" --field productsDirectory)"
RAW_BUILD_DIR="$("$SCRIPT_DIR/swift_locked.sh" receipt "$BUILD_RESULT" --field buildDirectory)"

info "Checking arm64 release executable architectures..."
bash "$SCRIPT_DIR/verify_release_executable.sh" "$BUILD_DIR/RillApp"
bash "$SCRIPT_DIR/verify_release_executable.sh" "$BUILD_DIR/RillSpeechWorker"

info "Checking locked third-party license and notice provenance..."
RILL_TEST_CHECKOUTS_DIR="$("$SCRIPT_DIR/swift_locked.sh" receipt "$BUILD_RESULT" --field checkoutsDirectory)" \
  uv run --script "$SCRIPT_DIR/tests/third_party_notices_test.py"

info "Checking relocatable SwiftPM resource accessors..."
verify_xcode_resource_accessor "RillMacOS_RillApp"

info "Smoke-testing unsigned app bundle assembly..."
SOURCE_REVISION="$(git rev-parse 'HEAD^{commit}')" ||
  error "Cannot determine the preflight source revision"
if [[ -n "$(git status --porcelain=v1 --untracked-files=normal)" ]]; then
  SOURCE_DIRTY="true"
fi
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
codesign --force --options runtime --sign - "$PACKAGE_SMOKE_ROOT/Rill.app"
codesign --verify --deep --strict --verbose=2 "$PACKAGE_SMOKE_ROOT/Rill.app"
"$PACKAGE_SMOKE_ROOT/Rill.app/Contents/Helpers/RillSpeechWorker" </dev/null

for document in LICENSE README.md; do
  cmp -s "$PROJECT_DIR/$document" "$PACKAGE_SMOKE_ROOT/Rill.app/Contents/Resources/$document" ||
    error "Packaged project document does not match $document"
done
cmp -s \
  "$PROJECT_DIR/PRIVACY.md" \
  "$PACKAGE_SMOKE_ROOT/Rill.app/Contents/Resources/PRIVACY.md" ||
  error "Packaged technical privacy notice does not match PRIVACY.md"
cmp -s \
  "$PROJECT_DIR/LOCAL_MODEL_NOTICES.md" \
  "$PACKAGE_SMOKE_ROOT/Rill.app/Contents/Resources/LOCAL_MODEL_NOTICES.md" ||
  error "Packaged local model notices do not match LOCAL_MODEL_NOTICES.md"
cleanup
trap - EXIT INT TERM

info "Running the test suite..."
bash "$SCRIPT_DIR/test.sh"

info "Checking the working diff for whitespace errors..."
git diff --check
git diff --cached --check

report_preflight_evidence
info "Preflight passed"
