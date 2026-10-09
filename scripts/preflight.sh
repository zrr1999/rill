#!/usr/bin/env bash
#
# Rill deterministic preflight shared by local releases and CI.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
BUILD_DIR=""
SOURCE_REVISION=""
SOURCE_DIRTY="false"
SOURCE_FINGERPRINT=""
CLEAN_BUILD=false
WORKER_CACHE="auto"
RAW_BUILD_DIR=""
MLX_RESOURCE_BUNDLE_NAME="mlx-swift_Cmlx.bundle"
NATIVE_TESTS='RillPlatformTests|RillUITests|RillAppTests'
DESKTOP_TESTS='/testDesktop'
STORAGE_STRESS='RillRuntimeTests.RecordCatalogStressTests'
PANEL_STRESS='RillAppTests.RecordPanelControllerTests/testWarmPanelReadyToSearchWithTenThousandRecords'
REPORT_DIR=""
CURRENT_STAGE=""
STAGE_STARTED=0

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
  if ! python_version="$(uv run --quiet --no-project --python '>=3.11' python --version 2>&1)"; then
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
    "Preflight evidence: class=working-source source_revision=$SOURCE_REVISION source_dirty=$SOURCE_DIRTY source_fingerprint=$SOURCE_FINGERPRINT"
}

preflight_source() {
  uv run --no-build --locked --script "$SCRIPT_DIR/build_driver.py" \
    preflight-source "$1" "$PROJECT_DIR" "$REPORT_DIR/source.json"
}

start_preflight_report() {
  local report_root="${RILL_PREFLIGHT_REPORT_DIR:-$PROJECT_DIR/.artifacts/preflight}"
  local source_metadata=""
  mkdir -p "$report_root"
  report_root="$(cd "$report_root" && pwd -P)"
  REPORT_DIR="$(mktemp -d "$report_root/run.XXXXXX")"
  source_metadata="$(preflight_source snapshot)"
  read -r SOURCE_REVISION SOURCE_DIRTY SOURCE_FINGERPRINT <<<"$source_metadata"
  {
    printf '# Rill preflight\n\n'
    printf -- '- Started (UTC): `%s`\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf -- '- Source revision: `%s`\n' "$SOURCE_REVISION"
    printf -- '- Source dirty: `%s`\n' "$SOURCE_DIRTY"
    printf -- '- Source fingerprint: `%s`\n' "$SOURCE_FINGERPRINT"
    printf -- '- Source baseline: `source.json` (verified before and after each stage)\n'
    printf -- '- PR base: `%s`\n' "${RILL_PR_BASE_SHA:-not applicable}"
    printf -- '- PR head: `%s`\n' "${RILL_PR_HEAD_SHA:-not applicable}"
    printf -- '- Clean build: `%s`\n' "$CLEAN_BUILD"
    printf -- '- Toolchain and OS versions: `toolchain.log`\n\n'
    printf '| Stage | Result | Seconds | Exit code |\n'
    printf '| --- | --- | ---: | ---: |\n'
  } >"$REPORT_DIR/summary.md"
  info "Preflight reports: $REPORT_DIR"
}

record_preflight_stage() {
  local status="$1"
  local result="$2"
  local elapsed=$(( $(date +%s) - STAGE_STARTED ))
  printf '| %s | %s | %s | %s |\n' "$CURRENT_STAGE" "$result" "$elapsed" "$status" \
    >>"$REPORT_DIR/summary.md"
  info "Stage $CURRENT_STAGE: $result (${elapsed}s, exit $status)"
  CURRENT_STAGE=""
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    echo '::endgroup::'
  fi
}

run_preflight_stage() {
  CURRENT_STAGE="$1"
  shift
  STAGE_STARTED="$(date +%s)"
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    printf '::group::Preflight: %s\n' "$CURRENT_STAGE"
  fi
  info "Stage $CURRENT_STAGE started"
  # A conditional around this pipeline would disable errexit inside stage functions.
  {
    preflight_source verify
    "$@"
    preflight_source verify
  } 2>&1 | tee "$REPORT_DIR/$CURRENT_STAGE.log"
  record_preflight_stage 0 passed
}

finish_preflight_report() {
  local status="$1"
  local result=passed
  trap - EXIT
  set +e
  if [[ -n "$CURRENT_STAGE" ]]; then
    record_preflight_stage "$status" failed
  fi
  if [[ "$status" -ne 0 ]]; then result=failed; fi
  printf '\nResult: **%s** (exit %s). Stages absent from the table were not run.\n' \
    "$result" "$status" >>"$REPORT_DIR/summary.md"
  info "Preflight reports: $REPORT_DIR"
  exit "$status"
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

locked_swift() {
  uv run --no-build --locked --script "$SCRIPT_DIR/build_driver.py" "$@"
}

check_shell_syntax() {
  local root="$1"
  local found=false
  local script=""

  [[ -d "$root/scripts" ]] || error "No scripts directory: $root/scripts"
  while IFS= read -r -d '' script; do
    found=true
    bash -n "$script"
  done < <(find "$root/scripts" -type f -name '*.sh' -print0)
  "$found" || error "No shell scripts found under $root/scripts"
}

check_release_artifact_hygiene() {
  local root="$1"
  local name=""
  local path=""
  local found=()

  [[ -d "$root" ]] || error "Release artifact hygiene root is not a directory: $root"
  root="$(cd "$root" && pwd -P)"
  for name in Rill.app Rill.dmg Rill.dmg.sha256; do
    path="$root/$name"
    if [[ -e "$path" || -L "$path" ]]; then
      found+=("$name")
    fi
  done
  if [[ "${#found[@]}" -gt 0 ]]; then
    echo "✗ Repository-root release artifacts are forbidden: ${found[*]}" >&2
    echo "  Preserve local artifacts under .artifacts/ or use a directory outside the repository." >&2
    exit 1
  fi
  echo "Release artifact hygiene check passed."
}

check_record_domain_boundary() {
  local legacy_domain_pattern='(^|[^A-Za-z0-9_])(DeliveryStack|ClipboardHistoryItem|ClipboardGroup|ClipboardPasteMode|ClipboardItemDryRun)([^A-Za-z0-9_]|$)'
  local declaration_pattern='^[[:space:]]*(public |internal |private |fileprivate )?(final )?(struct|class|enum|protocol|actor|typealias) Clipboard[A-Z]'
  local resource_pattern='id[[:space:]]*=[[:space:]]*"(stack\.push|clipboard\.copy)"|strategy[[:space:]]*=[[:space:]]*"(stack-first|clipboard-only)"'
  local legacy_sources=""

  if git grep -n -E -e "$legacy_domain_pattern" -- Sources ':!**/LegacyClipboardMigration.swift'; then
    error "Legacy Stack/Clipboard domain types escaped LegacyClipboardMigration"
  fi
  if git grep -n -E -e "$declaration_pattern" -- Sources ':!**/LegacyClipboardMigration.swift'; then
    error "Clipboard-prefixed domain declarations must be SystemClipboard-prefixed or migration-only"
  fi
  legacy_sources="$(
    find Sources -type f \
      \( -name 'DeliveryStack*.swift' -o -name 'Clipboard*.swift' -o -name 'StackPasteController.swift' \) \
      ! -name 'LegacyClipboardMigration.swift' \
      -print
  )"
  if [[ -n "$legacy_sources" ]]; then
    printf '%s\n' "$legacy_sources" >&2
    error "Legacy Stack/Clipboard source files remain outside the migration boundary"
  fi
  if git grep -n -E -e "$resource_pattern" -- Sources/RillApp/Resources; then
    error "Built-in workflow resources must emit canonical Record action IDs and strategies"
  fi
  echo "Record domain boundary check passed"
}

run_domain_swift_tests() {
  echo 'Running domain tests in parallel...'
  locked_swift test --parallel --num-workers 4 --skip "$NATIVE_TESTS|$DESKTOP_TESTS|RillQualityEvaluations|$STORAGE_STRESS"
}

run_native_swift_tests() {
  local discovered_tests stress_filter
  discovered_tests="$(locked_swift test list --skip-build)"
  for stress_filter in "$STORAGE_STRESS" "$PANEL_STRESS"; do
    if ! grep -E "$stress_filter" <<< "$discovered_tests" >/dev/null; then
      error "Required performance tests were not discovered: $stress_filter"
    fi
  done
  echo 'Running native platform, UI, and app tests without desktop interaction...'
  locked_swift test --skip-build --filter "$NATIVE_TESTS" --skip "$DESKTOP_TESTS|$PANEL_STRESS"
  echo 'Running 10,000-record storage performance tests in a fresh serial process...'
  locked_swift test --skip-build --filter "$STORAGE_STRESS"
  echo 'Running 10,000-record native panel performance tests in a fresh serial process...'
  if locked_swift test --skip-build --filter "$PANEL_STRESS"; then
    return
  fi
  info "Native panel stress failed; sampling one diagnostic replay"
  if ! RILL_RECORD_PROFILE_DIR="$PROJECT_DIR/.artifacts/ui-renders/panel-profile" \
    locked_swift test --skip-build --filter "$PANEL_STRESS"; then
    info "Diagnostic replay also failed; the original failure remains authoritative"
  fi
  error "Native panel stress failed; diagnostic samples are in .artifacts/ui-renders/panel-profile"
}

run_desktop_swift_tests() {
  echo 'Running desktop tests; an unlocked interactive macOS session is required...'
  locked_swift test "$@" --filter "$DESKTOP_TESTS" --skip RillQualityEvaluations
}

run_swift_tests() {
  run_domain_swift_tests
  run_native_swift_tests
  info 'Desktop interaction was not tested. Run just test-desktop in an unlocked session; just ci requires both suites.'
}

run_script_tests() {
  local test_dir="$SCRIPT_DIR/tests"
  echo 'Testing dependency security policy...'
  uv run --script "$test_dir/dependency_security_test.py"
  echo 'Testing evaluation and performance analysis tools...'
  uv run --script "$test_dir/asr_analysis_test.py"
  uv run --script "$test_dir/quality_evaluation_test.py"
  uv run --script "$test_dir/asr_replay_test.py"
  uv run --script "$test_dir/product_path_replay_test.py"
  echo 'Testing diagnostic export...'
  uv run --script "$test_dir/diagnostic_export_test.py"
  echo 'Testing secret scanning...'
  bash "$test_dir/secret_scan_test.sh"
  echo 'Testing build ownership and receipts...'
  uv run --no-build --locked --script "$test_dir/build_driver_test.py"
  echo 'Testing worker artifact caching...'
  uv run --no-build --locked --script "$test_dir/worker_cache_test.py"
  echo 'Testing release configuration...'
  bash "$test_dir/release_config_test.sh"
  echo 'Testing preflight stage reporting...'
  bash "$test_dir/preflight_report_test.sh"
  echo 'Testing GitHub Release drafts...'
  bash "$test_dir/github_release_test.sh"
  echo 'Testing app icon generation...'
  bash "$test_dir/app_icon_test.sh"
  echo 'Testing input method signing boundaries...'
  uv run --no-build --locked --script "$test_dir/input_method_assembly_test.py"
}

install_gitleaks() {
  local destination=""
  local version="8.30.1"
  local asset_name=""
  local expected_sha256=""
  local temp_root=""
  local archive_path=""
  local extract_dir=""
  local installed_version=""

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
    --destination)
      [[ "$#" -ge 2 ]] || error "Missing value for --destination"
      destination="$2"
      shift 2
      ;;
    --help | -h)
      echo "Usage: $0 install-gitleaks --destination DIR"
      exit 0
      ;;
    *) error "Unknown argument: $1" ;;
    esac
  done
  [[ -n "$destination" ]] || error "--destination is required"
  case "$(uname -s)/$(uname -m)" in
  Darwin/arm64)
    asset_name="gitleaks_${version}_darwin_arm64.tar.gz"
    expected_sha256="b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"
    ;;
  Darwin/x86_64)
    asset_name="gitleaks_${version}_darwin_x64.tar.gz"
    expected_sha256="dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709"
    ;;
  Linux/x86_64)
    asset_name="gitleaks_${version}_linux_x64.tar.gz"
    expected_sha256="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"
    ;;
  *) error "Unsupported platform: $(uname -s)/$(uname -m)" ;;
  esac
  for command_name in curl install mktemp shasum tar; do
    command -v "$command_name" >/dev/null 2>&1 || error "Required command not found: $command_name"
  done
  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/rill-gitleaks-install.XXXXXX")"
  trap '[[ -n ${temp_root:-} ]] && rm -rf "$temp_root"' EXIT
  archive_path="$temp_root/$asset_name"
  extract_dir="$temp_root/extracted"
  mkdir -p "$extract_dir" "$destination"
  curl --fail --location --proto '=https' --retry 3 --show-error --silent --tlsv1.2 \
    --output "$archive_path" \
    "https://github.com/gitleaks/gitleaks/releases/download/v${version}/${asset_name}"
  printf '%s  %s\n' "$expected_sha256" "$archive_path" | shasum -a 256 -c -
  tar -xzf "$archive_path" -C "$extract_dir"
  [[ -f "$extract_dir/gitleaks" ]] || error "Verified archive does not contain gitleaks"
  install -m 0755 "$extract_dir/gitleaks" "$destination/gitleaks"
  installed_version="$("$destination/gitleaks" version | tail -n 1 | awk '{print $NF}' | sed 's/^v//')"
  [[ "$installed_version" == "$version" ]] || error "Installed Gitleaks version mismatch: ${installed_version:-unknown}"
  echo "Installed Gitleaks $version at $destination/gitleaks"
  rm -rf "$temp_root"
  trap - EXIT
}

check_commit_messages() {
  local base=""
  local head="HEAD"
  local range=""
  local revisions=""
  local revision=""
  local message_file=""

  if (( $# > 2 )); then
    echo "usage: $0 commit-messages [BASE [HEAD]]" >&2
    exit 2
  fi
  head="${2:-HEAD}"
  base="${1:-}"
  head="$(git rev-parse --verify "${head}^{commit}")"
  range="$head"
  if [[ -n "$base" && "$base" != "0000000000000000000000000000000000000000" ]]; then
    base="$(git rev-parse --verify "${base}^{commit}")"
    range="$base..$head"
  fi
  revisions="$(git rev-list --reverse "$range")"
  [[ -n "$revisions" ]] || return 0
  message_file="$(mktemp)"
  trap '[[ -n ${message_file:-} ]] && rm -f "$message_file"' EXIT
  while IFS= read -r revision; do
    git show --no-patch --format=%B "$revision" >"$message_file"
    echo "Checking commit $revision"
    uvx --no-build --from zendev==0.4.0 \
      --with zendev-commit==0.4.0 --with zendev-review==0.4.0 \
      zendev message check --profile zendev "$message_file"
  done <<<"$revisions"
  rm -f "$message_file"
  trap - EXIT
}

check_preflight_toolchain() {
  require_command git
  require_command codesign
  require_command uv
  require_command swift
  verify_toolchain_versions

  xcodebuild -version
  xcrun --show-sdk-version
  xcrun --show-sdk-build-version
  sw_vers
}

check_repository() {
  info "Checking shell syntax..."
  check_shell_syntax "$PROJECT_DIR"

  info "Checking repository release artifact hygiene..."
  check_release_artifact_hygiene "$PROJECT_DIR"

  info "Checking Swift module dependencies..."
  uv run --no-build --locked --script "$SCRIPT_DIR/check_module_boundaries.py"

  info "Checking Record domain boundary..."
  check_record_domain_boundary

  info "Running script policy tests..."
  run_script_tests

  info "Checking independent input method data packaging..."
  uv run --no-build --locked --script "$SCRIPT_DIR/tests/input_method_data_test.py"

  info "Checking any locked source-control dependencies against the reviewed offline advisory baseline..."
  uv run --script "$SCRIPT_DIR/check_dependency_security.py"

  info "Scanning Git history and the current source snapshot for secrets..."
  bash "$SCRIPT_DIR/check_secrets.sh"

  if $CLEAN_BUILD; then
    locked_swift clean
    locked_swift clean --configuration release
  fi

  info "Checking generated built-in workflow artifacts..."
  uv run --script "$SCRIPT_DIR/generate_builtin_workflows.py" --check

  info "Checking performance benchmark workloads..."
  bash "$SCRIPT_DIR/build_benchmarks.sh" --preview-only
}

check_release() {
  PACKAGE_SMOKE_ROOT="$(mktemp -d)"
  cleanup() {
    rm -rf "$PACKAGE_SMOKE_ROOT"
  }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  BUILD_RESULT="$PACKAGE_SMOKE_ROOT/build-result.json"
  info "Building the release configuration..."
  locked_swift release --worker-cache "$WORKER_CACHE" --result-file "$BUILD_RESULT"
  BUILD_DIR="$(locked_swift receipt "$BUILD_RESULT" --field productsDirectory)"
  RAW_BUILD_DIR="$(locked_swift receipt "$BUILD_RESULT" --field buildDirectory)"

  info "Checking arm64 release executable architectures..."
  bash "$SCRIPT_DIR/assemble_app_bundle.sh" verify-executable "$BUILD_DIR/RillApp"
  bash "$SCRIPT_DIR/assemble_app_bundle.sh" verify-executable "$BUILD_DIR/RillSpeechWorker"

  info "Checking locked third-party license and notice provenance..."
  RILL_TEST_CHECKOUTS_DIR="$(locked_swift receipt "$BUILD_RESULT" --field checkoutsDirectory)" \
    uv run --script "$SCRIPT_DIR/tests/third_party_notices_test.py"

  info "Checking relocatable SwiftPM resource accessors..."
  verify_xcode_resource_accessor "RillMacOS_RillApp"
  verify_xcode_resource_accessor "RillMacOS_RillUI"

  info "Smoke-testing unsigned app bundle assembly..."
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
  uv run --no-build --locked --script "$SCRIPT_DIR/assemble_input_method.py" \
    --sign-existing "$PACKAGE_SMOKE_ROOT/Rill.app/Contents/Helpers/RillInputMethod.app"
  codesign --force --options runtime --sign - "$PACKAGE_SMOKE_ROOT/Rill.app"
  codesign --verify --deep --strict --verbose=2 "$PACKAGE_SMOKE_ROOT/Rill.app"
  "$PACKAGE_SMOKE_ROOT/Rill.app/Contents/Helpers/RillSpeechWorker" </dev/null

  for document in LICENSE README.md PRIVACY.md LOCAL_MODEL_NOTICES.md; do
    cmp -s "$PROJECT_DIR/$document" "$PACKAGE_SMOKE_ROOT/Rill.app/Contents/Resources/$document" ||
      error "Packaged project document does not match $document"
  done
  uv run --no-build --locked --script "$SCRIPT_DIR/tests/input_method_test.py" \
    "$PACKAGE_SMOKE_ROOT/Rill.app/Contents/Helpers/RillInputMethod.app"
  if [[ -n "${RILL_PREFLIGHT_APP_DIR:-}" ]]; then
    check_working_diff
    preflight_source verify
    info "Saving the verified preflight app for native interaction QA..."
    mkdir -p "$RILL_PREFLIGHT_APP_DIR"
    local archive="Rill-preflight-$SOURCE_REVISION.zip"
    [[ ! -e "$RILL_PREFLIGHT_APP_DIR/$archive" && ! -L "$RILL_PREFLIGHT_APP_DIR/$archive" ]] ||
      error "Preflight app archive already exists: $RILL_PREFLIGHT_APP_DIR/$archive"
    ditto -c -k --sequesterRsrc --keepParent \
      "$PACKAGE_SMOKE_ROOT/Rill.app" "$RILL_PREFLIGHT_APP_DIR/$archive"
    (
      cd "$RILL_PREFLIGHT_APP_DIR"
      shasum -a 256 "$archive" > "$archive.sha256"
      printf 'source_revision=%s\nsource_dirty=%s\nsource_fingerprint=%s\nbuild_kind=preflight\nsigning=ad-hoc\n' \
        "$SOURCE_REVISION" "$SOURCE_DIRTY" "$SOURCE_FINGERPRINT" > "$archive.source.txt"
    )
  fi
  cleanup
  trap - EXIT INT TERM
}

check_working_diff() {
  info "Checking the working diff for whitespace errors..."
  git diff --check
  git diff --cached --check
}

run_preflight() {
  start_preflight_report
  trap 'finish_preflight_report "$?"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  run_preflight_stage toolchain check_preflight_toolchain
  cd "$PROJECT_DIR"
  run_preflight_stage repository check_repository
  run_preflight_stage domain-tests run_domain_swift_tests
  run_preflight_stage native-tests run_native_swift_tests
  run_preflight_stage desktop-tests run_desktop_swift_tests --skip-build
  run_preflight_stage release check_release
  run_preflight_stage working-diff check_working_diff

  report_preflight_evidence
  info "Preflight passed"
}

# Source the real orchestration and helpers in policy tests without running the gate.
if [[ "${BASH_SOURCE[0]-}" != "$0" ]]; then
  return 0
fi

case "${1-}" in
test)
  run_swift_tests
  exit
  ;;
test-desktop)
  run_desktop_swift_tests
  exit
  ;;
test-scripts)
  run_script_tests
  exit
  ;;
swift)
  shift
  exec uv run --no-build --locked --script "$SCRIPT_DIR/build_driver.py" "$@"
  ;;
install-gitleaks)
  shift
  install_gitleaks "$@"
  exit
  ;;
commit-messages)
  shift
  check_commit_messages "$@"
  exit
  ;;
syntax)
  shift
  check_shell_syntax "${1:-$PROJECT_DIR}"
  exit
  ;;
hygiene)
  shift
  check_release_artifact_hygiene "${1:-$PROJECT_DIR}"
  exit
  ;;
esac

while [[ "$#" -gt 0 ]]; do
  case "$1" in
  --clean) CLEAN_BUILD=true; WORKER_CACHE="off" ;;
  --help | -h)
    echo "Usage: $0 [--clean] | test | test-desktop | test-scripts | swift ... | install-gitleaks --destination DIR | commit-messages [BASE [HEAD]] | syntax [ROOT] | hygiene [ROOT]"
    exit 0
    ;;
  *) error "Unknown argument: $1" ;;
  esac
  shift
done

run_preflight
