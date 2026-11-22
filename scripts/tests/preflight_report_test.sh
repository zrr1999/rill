#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rill-preflight-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

# The release stage owns its temporary bundle; its EXIT trap must not replace reporting.
cat >"$TEST_ROOT/release-failure.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$1/scripts/preflight.sh"
check_preflight_toolchain() { :; }
parse_preflight_options --lane release
locked_swift() {
  echo "$PACKAGE_SMOKE_ROOT" >"$FIXTURE_TRACE"
  echo "release fixture failed" >&2
  return 47
}
run_preflight
SH
status=0
env RILL_PREFLIGHT_REPORT_DIR="$TEST_ROOT/release-cleanup" \
  FIXTURE_TRACE="$TEST_ROOT/smoke-path" \
  "$BASH" "$TEST_ROOT/release-failure.sh" "$PROJECT_DIR" >"$TEST_ROOT/release-failure-output" 2>&1 || status=$?
[[ "$status" == 47 ]]
[[ ! -e "$(cat "$TEST_ROOT/smoke-path")" ]]
reports=("$TEST_ROOT/release-cleanup"/run.*)
grep -Fq 'Result: **failed** (exit 47)' "${reports[0]}/summary.md"
grep -Fq 'release fixture failed' "${reports[0]}/release.log"
echo 'PASS: release failure cleans the temporary bundle and preserves its failure report'
