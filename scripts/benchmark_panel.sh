#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 0 ]]; then
  echo 'Usage: just bench-performance panel' >&2
  exit 2
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$PROJECT_DIR"
mkdir -p .artifacts/benchmarks/panel
REPORT_DIR="$(mktemp -d "$PROJECT_DIR/.artifacts/benchmarks/panel/run.XXXXXX")"
echo "Panel benchmark report: $REPORT_DIR"

uv run --no-build --locked --script scripts/build_driver.py \
  preflight-source snapshot "$PROJECT_DIR" "$REPORT_DIR/source.json"
{
  swift --version
  xcodebuild -version
  sw_vers
  sysctl hw.model hw.ncpu hw.memsize
} >"$REPORT_DIR/toolchain.log"

RILL_PANEL_BENCHMARK_OUTPUT="$REPORT_DIR/samples.json" \
  scripts/preflight.sh swift test --configuration release --test-product RillAppTests \
  --filter '^RillAppTests.RecordPanelControllerTests/testBenchmarkWarmPanelPresentation$' \
  2>&1 | tee "$REPORT_DIR/test.log"

[[ -s "$REPORT_DIR/samples.json" ]]
uv run --no-build --locked --script scripts/build_driver.py \
  preflight-source verify "$PROJECT_DIR" "$REPORT_DIR/source.json"
echo "Panel benchmark completed: $REPORT_DIR"
