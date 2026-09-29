#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rill-preflight-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

cat >"$TEST_ROOT/fixture.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$1/scripts/preflight.sh"

fixture_stage() {
  echo "stdout: $CURRENT_STAGE"
  echo "stderr: $CURRENT_STAGE" >&2
  echo "$CURRENT_STAGE" >>"$FIXTURE_TRACE"
  if [[ "$CURRENT_STAGE" == "$FAIL_STAGE" ]]; then
    bash -c 'exit 47'
    echo 'failure was swallowed'
  fi
}
check_preflight_toolchain() { fixture_stage; }
check_repository() { fixture_stage; }
run_domain_swift_tests() { fixture_stage; }
run_native_swift_tests() { fixture_stage; }
check_release() { fixture_stage; }
check_working_diff() { fixture_stage; }
run_preflight
SH

stages=(toolchain repository domain-tests native-tests release working-diff)
for failed_stage in none "${stages[@]}"; do
  fixture="$TEST_ROOT/$failed_stage"
  mkdir -p "$fixture/reports with spaces"
  status=0
  env RILL_PREFLIGHT_REPORT_DIR="$fixture/reports with spaces" \
    RILL_PR_BASE_SHA=base-fixture RILL_PR_HEAD_SHA=head-fixture \
    GITHUB_ACTIONS=true FAIL_STAGE="$failed_stage" FIXTURE_TRACE="$fixture/trace" \
    bash "$TEST_ROOT/fixture.sh" "$PROJECT_DIR" >"$fixture/output" 2>&1 || status=$?
  reports=("$fixture/reports with spaces"/run.*)
  [[ "${#reports[@]}" == 1 && -f "${reports[0]}/summary.md" ]]
  report="${reports[0]}"
  summary="$report/summary.md"
  grep -Fq -- '- PR base: `base-fixture`' "$summary"
  grep -Fq -- '- PR head: `head-fixture`' "$summary"
  grep -Fq -- "$(git -C "$PROJECT_DIR" rev-parse HEAD)" "$summary"

  : >"$fixture/expected-trace"
  for stage in "${stages[@]}"; do
    echo "$stage" >>"$fixture/expected-trace"
    grep -Fq "stdout: $stage" "$report/$stage.log"
    grep -Fq "stderr: $stage" "$report/$stage.log"
    if [[ "$stage" == "$failed_stage" ]]; then
      grep -Eq "^\| $stage \| failed \| [0-9]+ \| 47 \|$" "$summary"
      break
    fi
    grep -Eq "^\| $stage \| passed \| [0-9]+ \| 0 \|$" "$summary"
  done
  cmp "$fixture/expected-trace" "$fixture/trace"
  [[ "$(grep -c '^::group::' "$fixture/output")" == "$(grep -c '^::endgroup::$' "$fixture/output")" ]]
  if [[ "$failed_stage" == none ]]; then
    [[ "$status" == 0 ]]
    grep -Fq 'Result: **passed** (exit 0)' "$summary"
    tail -n 3 "$fixture/output" | grep -Fq 'Preflight evidence: class=working-source'
    grep -Fq 'Preflight passed' "$fixture/output"
  else
    [[ "$status" == 47 ]]
    grep -Fq 'Result: **failed** (exit 47)' "$summary"
    if grep -Eq 'failure was swallowed|Preflight passed' "$fixture/output"; then
      echo "FAIL: $failed_stage did not stop preflight" >&2
      exit 1
    fi
  fi
  echo "PASS: preflight stage failure=$failed_stage preserves logs, status, and execution order"
done

# A reporting destination may be reused without overwriting an earlier run.
env RILL_PREFLIGHT_REPORT_DIR="$TEST_ROOT/none/reports with spaces" \
  FAIL_STAGE=none FIXTURE_TRACE="$TEST_ROOT/repeated-trace" \
  bash "$TEST_ROOT/fixture.sh" "$PROJECT_DIR" >"$TEST_ROOT/repeated-output" 2>&1
reports=("$TEST_ROOT/none/reports with spaces"/run.*)
[[ "${#reports[@]}" == 2 ]]
echo 'PASS: repeated preflight runs keep separate reports'

# The release stage owns its temporary bundle; its EXIT trap must not replace reporting.
cat >"$TEST_ROOT/release-failure.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$1/scripts/preflight.sh"
check_preflight_toolchain() { :; }
check_repository() { :; }
run_domain_swift_tests() { :; }
run_native_swift_tests() { :; }
locked_swift() {
  echo "$PACKAGE_SMOKE_ROOT" >"$FIXTURE_TRACE"
  return 47
}
run_preflight
SH
status=0
env RILL_PREFLIGHT_REPORT_DIR="$TEST_ROOT/release-cleanup" \
  FIXTURE_TRACE="$TEST_ROOT/smoke-path" \
  bash "$TEST_ROOT/release-failure.sh" "$PROJECT_DIR" >"$TEST_ROOT/release-failure-output" 2>&1 || status=$?
[[ "$status" == 47 ]]
[[ ! -e "$(cat "$TEST_ROOT/smoke-path")" ]]
reports=("$TEST_ROOT/release-cleanup"/run.*)
grep -Fq 'Result: **failed** (exit 47)' "${reports[0]}/summary.md"
echo 'PASS: release failure cleans the temporary bundle and preserves its failure report'
