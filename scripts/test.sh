#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/stage_report.sh
source "$(dirname "${BASH_SOURCE[0]}")/stage_report.sh"

NATIVE_TESTS='RillPlatformTests|RillUITests|RillAppTests'
DESKTOP_TESTS='/testDesktop'
BENCHMARK_TESTS='/testBenchmark'
STORAGE_STRESS_TESTS='RillRuntimeTests.RecordCatalogStressTests'
PANEL_STRESS_TESTS='RillAppTests.RecordPanelControllerTests/testWarmPanelReadyToSearchWithTenThousandRecords'
REPORT_LANE=tests
REPORT_TITLE='macOS tests'

run_domain_swift_tests() {
  echo 'Running domain tests in parallel...'
  locked_swift test --parallel --num-workers 4 --skip "$NATIVE_TESTS|$DESKTOP_TESTS|$BENCHMARK_TESTS|RillQualityEvaluations|$STORAGE_STRESS_TESTS"
}

run_native_swift_tests() {
  echo 'Running native platform, UI, and app tests without desktop interaction...'
  locked_swift test --skip-build --filter "$NATIVE_TESTS" --skip "$DESKTOP_TESTS|$BENCHMARK_TESTS|$PANEL_STRESS_TESTS"
}

run_performance_swift_tests() {
  local discovered_tests stress_filter
  discovered_tests="$(locked_swift test list --skip-build)"
  for stress_filter in "$STORAGE_STRESS_TESTS" "$PANEL_STRESS_TESTS"; do
    if ! grep -E "$stress_filter" <<<"$discovered_tests" >/dev/null; then
      error "Required performance tests were not discovered: $stress_filter"
    fi
  done
  echo 'Running 10,000-record storage performance tests in a fresh serial process...'
  locked_swift test --skip-build --filter "$STORAGE_STRESS_TESTS"
  echo 'Validating 10,000-record native panel presentation in a fresh serial process...'
  locked_swift test --skip-build --filter "$PANEL_STRESS_TESTS"
}

# --skip-build arrives through run_stage; the direct call passes none.
# shellcheck disable=SC2120
run_desktop_swift_tests() {
  echo 'Running desktop tests; an unlocked interactive macOS session is required...'
  locked_swift test "$@" --filter "$DESKTOP_TESTS" --skip "$BENCHMARK_TESTS|RillQualityEvaluations"
}

run_script_tests() {
  local test_dir="$SCRIPT_DIR/tests"
  echo 'Testing diagnostic export...'
  uv run --script "$test_dir/diagnostic_export_test.py"
  echo 'Testing secret scanning...'
  bash "$test_dir/secret_scan_test.sh"
  echo 'Testing build ownership and receipts...'
  uv run --no-build --script "$test_dir/build_driver_test.py"
  echo 'Testing worker artifact caching...'
  uv run --no-build --script "$test_dir/worker_cache_test.py"
  echo 'Testing release configuration...'
  bash "$test_dir/release_config_test.sh"
  echo 'Testing packaging failure reporting...'
  bash "$test_dir/package_smoke_report_test.sh"
  echo 'Testing GitHub Release drafts...'
  bash "$test_dir/github_release_test.sh"
  echo 'Testing input method cache integrity...'
  uv run --no-build --script "$test_dir/input_method_test.py"
}

usage() {
  echo "Usage: $0 [--clean] [--desktop] [--evidence] | --desktop-only | --scripts"
}

case "${1-}" in
--scripts | --desktop-only)
  [[ "$#" -eq 1 ]] || {
    usage >&2
    exit 2
  }
  if [[ "$1" == --scripts ]]; then
    run_script_tests
  else
    # shellcheck disable=SC2119
    run_desktop_swift_tests
  fi
  exit
  ;;
esac

desktop=false
while (($#)); do
  case "$1" in
  --clean) CLEAN_BUILD=true ;;
  --desktop) desktop=true ;;
  --evidence)
    export RILL_RECORD_STRESS=1
    export RILL_UI_SNAPSHOT_DIR="$PROJECT_DIR/.artifacts/ui-renders"
    ;;
  --help | -h)
    usage
    exit
    ;;
  *)
    usage >&2
    exit 2
    ;;
  esac
  shift
done

cd "$PROJECT_DIR"
start_report
trap 'finish_report "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
run_stage toolchain check_toolchain
if $CLEAN_BUILD; then
  run_stage clean locked_swift clean
fi
run_stage domain-tests run_domain_swift_tests
run_stage native-tests run_native_swift_tests
if [[ "${RILL_RECORD_STRESS:-}" == 1 ]]; then
  run_stage performance-tests run_performance_swift_tests
fi
if $desktop; then
  run_stage desktop-tests run_desktop_swift_tests --skip-build
else
  info 'Desktop interaction was not tested. Use mise run test --desktop in an unlocked session.'
fi
run_stage working-diff check_working_diff
report_source_evidence
