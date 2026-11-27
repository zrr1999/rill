# shellcheck shell=bash
# Shared reporting and toolchain checks for test.sh and package_smoke.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SOURCE_REVISION=""
SOURCE_DIRTY="false"
SOURCE_FINGERPRINT=""
REPORT_DIR=""
CURRENT_STAGE=""
STAGE_STARTED=0
CLEAN_BUILD=false

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

report_source_evidence() {
  info \
    "Source evidence: class=working-source source_revision=$SOURCE_REVISION source_dirty=$SOURCE_DIRTY source_fingerprint=$SOURCE_FINGERPRINT"
}

verify_report_source() {
  uv run --no-build --script "$SCRIPT_DIR/build_driver.py" \
    preflight-source "$1" "$PROJECT_DIR" "$REPORT_DIR/source.json"
}

start_report() {
  local report_root="${RILL_PREFLIGHT_REPORT_DIR:-$PROJECT_DIR/.artifacts/preflight}"
  local source_metadata=""
  mkdir -p "$report_root"
  report_root="$(cd "$report_root" && pwd -P)"
  REPORT_DIR="$(mktemp -d "$report_root/run.XXXXXX")"
  source_metadata="$(verify_report_source snapshot)"
  read -r SOURCE_REVISION SOURCE_DIRTY SOURCE_FINGERPRINT <<<"$source_metadata"
  # Backticks below are Markdown code spans in the report.
  # shellcheck disable=SC2016
  {
    printf '# Rill %s\n\n' "$REPORT_TITLE"
    printf -- '- Started (UTC): `%s`\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf -- '- Source revision: `%s`\n' "$SOURCE_REVISION"
    printf -- '- Source dirty: `%s`\n' "$SOURCE_DIRTY"
    printf -- '- Source fingerprint: `%s`\n' "$SOURCE_FINGERPRINT"
    printf -- '- Source baseline: `source.json` (verified before and after each stage)\n'
    printf -- '- PR base: `%s`\n' "${RILL_PR_BASE_SHA:-not applicable}"
    printf -- '- PR head: `%s`\n' "${RILL_PR_HEAD_SHA:-not applicable}"
    printf -- '- Lane: `%s`\n' "$REPORT_LANE"
    printf -- '- Clean build: `%s`\n' "$CLEAN_BUILD"
    printf -- '- Toolchain and OS versions: `toolchain.log`\n\n'
    printf '| Stage | Result | Seconds | Exit code |\n'
    printf '| --- | --- | ---: | ---: |\n'
  } >"$REPORT_DIR/summary.md"
  info "Report: $REPORT_DIR"
}

record_stage() {
  local status="$1"
  local result="$2"
  local elapsed=$(($(date +%s) - STAGE_STARTED))
  printf '| %s | %s | %s | %s |\n' "$CURRENT_STAGE" "$result" "$elapsed" "$status" \
    >>"$REPORT_DIR/summary.md"
  info "Stage $CURRENT_STAGE: $result (${elapsed}s, exit $status)"
  CURRENT_STAGE=""
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    echo '::endgroup::'
  fi
}

run_stage() {
  CURRENT_STAGE="$1"
  shift
  STAGE_STARTED="$(date +%s)"
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    printf '::group::%s\n' "$CURRENT_STAGE"
  fi
  info "Stage $CURRENT_STAGE started"
  # A conditional around this pipeline would disable errexit inside stage functions.
  {
    verify_report_source verify
    "$@"
    verify_report_source verify
  } 2>&1 | tee "$REPORT_DIR/$CURRENT_STAGE.log"
  record_stage 0 passed
}

finish_report() {
  local status="$1"
  local result=passed
  trap - EXIT
  set +e
  if [[ -n "$CURRENT_STAGE" ]]; then
    record_stage "$status" failed
  fi
  if [[ "$status" -ne 0 ]]; then result=failed; fi
  printf '\nResult: **%s** (exit %s). Stages absent from the table were not run.\n' \
    "$result" "$status" >>"$REPORT_DIR/summary.md"
  info "Report: $REPORT_DIR"
  exit "$status"
}

locked_swift() {
  uv run --no-build --script "$SCRIPT_DIR/build_driver.py" "$@"
}

check_toolchain() {
  require_command git
  require_command uv
  require_command swift
  verify_toolchain_versions

  xcodebuild -version
  xcrun --show-sdk-version
  xcrun --show-sdk-build-version
  sw_vers
}

check_working_diff() {
  info "Checking the working diff for whitespace errors..."
  git diff --check
  git diff --cached --check
}
