#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rill-preflight-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Exercise selection through the actual runners, including a desktop test outside a native target.
cat >"$TEST_ROOT/selection.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$1/scripts/preflight.sh"
locked_swift() {
  local filter='.' skip='^$' test_id
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --filter) filter="$2"; shift ;;
      --skip) skip="$2"; shift ;;
    esac
    shift
  done
  while IFS= read -r test_id; do
    if [[ "$test_id" =~ $filter && ! "$test_id" =~ $skip ]]; then
      echo "$test_id" >>"$FIXTURE_TRACE"
    fi
  done <"$FIXTURE_TESTS"
}
case "$2" in
  regular) run_swift_tests ;;
  desktop) run_desktop_swift_tests ;;
esac
SH
cat >"$TEST_ROOT/test-ids" <<'TESTS'
RillRuntimeTests.SessionTests/testStarts
RillRuntimeTests.SessionTests/testDesktopCapture
RillAppTests.PanelTests/testLayout
RillAppTests.PanelTests/testDesktopFocus
RillUITests.ShellTests/testLayout
RillUITests.ShellTests/testDesktopFocus
RillPlatformTests.NativeTests/testPlatform
RillQualityEvaluations.Evaluation/testQuality
RillQualityEvaluations.Evaluation/testDesktopQuality
TESTS
for selection in regular desktop; do
  env FIXTURE_TRACE="$TEST_ROOT/$selection-trace" FIXTURE_TESTS="$TEST_ROOT/test-ids" \
    "$BASH" "$TEST_ROOT/selection.sh" "$PROJECT_DIR" "$selection" >"$TEST_ROOT/$selection-output" 2>&1
done
grep -Ev '/testDesktop|RillQualityEvaluations' "$TEST_ROOT/test-ids" >"$TEST_ROOT/regular-expected"
grep '/testDesktop' "$TEST_ROOT/test-ids" | grep -v RillQualityEvaluations >"$TEST_ROOT/desktop-expected"
cmp "$TEST_ROOT/regular-expected" "$TEST_ROOT/regular-trace"
cmp "$TEST_ROOT/desktop-expected" "$TEST_ROOT/desktop-trace"
grep -Fq 'Desktop interaction was not tested' "$TEST_ROOT/regular-output"
echo 'PASS: regular and desktop runners partition tests without losing or duplicating coverage'

cat >"$TEST_ROOT/fixture.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$1/scripts/preflight.sh"
PROJECT_DIR="${FIXTURE_PROJECT_DIR:-$PROJECT_DIR}"

mutate_source() {
  case "$MUTATION" in
    edit) printf 'after\n' >"$PROJECT_DIR/tracked file.txt" ;;
    add) printf 'new\n' >"$PROJECT_DIR/new file.txt" ;;
    delete) rm "$PROJECT_DIR/tracked file.txt" ;;
    head) git -C "$PROJECT_DIR" -c commit.gpgsign=false commit --quiet --allow-empty -m changed ;;
    mode) chmod +x "$PROJECT_DIR/tracked file.txt" ;;
    revert)
      printf 'after\n' >"$PROJECT_DIR/tracked file.txt"
      printf 'before\n' >"$PROJECT_DIR/tracked file.txt"
      ;;
    stage) git -C "$PROJECT_DIR" add 'tracked file.txt' ;;
    untracked) printf 'after\n' >"$PROJECT_DIR/untracked file.txt" ;;
    ignored)
      mkdir -p "$PROJECT_DIR/ignored"
      printf 'output\n' >"$PROJECT_DIR/ignored/build.txt"
      ;;
  esac
}

info() {
  echo "▸ $*"
  if [[ "${MUTATE_TIMING:-after}" == before && "$*" == "Stage ${MUTATE_STAGE:-none} started" ]]; then
    mutate_source
  fi
}

fixture_stage() {
  echo "stdout: $CURRENT_STAGE"
  echo "stderr: $CURRENT_STAGE" >&2
  echo "$CURRENT_STAGE" >>"$FIXTURE_TRACE"
  if [[ "$CURRENT_STAGE" == "$FAIL_STAGE" ]]; then
    bash -c 'exit 47'
    echo 'failure was swallowed'
  fi
  if [[ "${MUTATE_TIMING:-after}" == after && "$CURRENT_STAGE" == "${MUTATE_STAGE:-none}" ]]; then
    mutate_source
  fi
}
check_preflight_toolchain() { fixture_stage; }
check_repository() { fixture_stage; }
run_domain_swift_tests() { fixture_stage; }
run_native_swift_tests() { fixture_stage; }
run_desktop_swift_tests() { fixture_stage; }
check_release() { fixture_stage; }
check_working_diff() { fixture_stage; }
run_preflight
SH

stages=(toolchain repository domain-tests native-tests desktop-tests release working-diff)
for failed_stage in none "${stages[@]}"; do
  fixture="$TEST_ROOT/$failed_stage"
  mkdir -p "$fixture/reports with spaces"
  status=0
  env RILL_PREFLIGHT_REPORT_DIR="$fixture/reports with spaces" \
    RILL_PR_BASE_SHA=base-fixture RILL_PR_HEAD_SHA=head-fixture \
    GITHUB_ACTIONS=true FAIL_STAGE="$failed_stage" FIXTURE_TRACE="$fixture/trace" \
    "$BASH" "$TEST_ROOT/fixture.sh" "$PROJECT_DIR" >"$fixture/output" 2>&1 || status=$?
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
  "$BASH" "$TEST_ROOT/fixture.sh" "$PROJECT_DIR" >"$TEST_ROOT/repeated-output" 2>&1
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
run_desktop_swift_tests() { :; }
locked_swift() {
  echo "$PACKAGE_SMOKE_ROOT" >"$FIXTURE_TRACE"
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
echo 'PASS: release failure cleans the temporary bundle and preserves its failure report'

source_case() {
  local name="$1" mutation="$2" mutate_stage="$3" initial="$4" timing="$5"
  local fixture="$TEST_ROOT/source-$name" status=0 dirty=false stage summary
  local repository="$fixture/repository" reports
  mkdir -p "$repository"
  git -C "$repository" init --quiet
  git -C "$repository" config user.name 'Preflight fixture'
  git -C "$repository" config user.email 'preflight@example.invalid'
  git -C "$repository" config core.hooksPath /dev/null
  printf 'before\n' >"$repository/tracked file.txt"
  printf 'ignored/\n' >"$repository/.gitignore"
  git -C "$repository" add .
  git -C "$repository" -c commit.gpgsign=false commit --quiet -m fixture
  case "$initial" in
    dirty)
      printf 'dirty\n' >"$repository/tracked file.txt"
      dirty=true
      ;;
    untracked)
      printf 'untracked\n' >"$repository/untracked file.txt"
      dirty=true
      ;;
  esac
  env RILL_PREFLIGHT_REPORT_DIR="$fixture/reports" \
    FIXTURE_PROJECT_DIR="$repository" FIXTURE_TRACE="$fixture/trace" \
    FAIL_STAGE=none MUTATE_STAGE="$mutate_stage" MUTATION="$mutation" MUTATE_TIMING="$timing" \
    "$BASH" "$TEST_ROOT/fixture.sh" "$PROJECT_DIR" >"$fixture/output" 2>&1 || status=$?
  reports=("$fixture/reports"/run.*)
  summary="${reports[0]}/summary.md"
  grep -Fq -- "- Source dirty: \`$dirty\`" "$summary"
  grep -Eq '^- Source fingerprint: `[0-9a-f]{64}`$' "$summary"
  [[ -f "${reports[0]}/source.json" ]]
  : >"$fixture/expected-trace"
  for stage in "${stages[@]}"; do
    if [[ "$stage" == "$mutate_stage" && "$mutation" != ignored ]]; then
      if [[ "$timing" == after ]]; then echo "$stage" >>"$fixture/expected-trace"; fi
      grep -Eq "^\| $stage \| failed \| [0-9]+ \| 1 \|$" "$summary"
      grep -Fq 'Source changed during preflight' "${reports[0]}/$stage.log"
      break
    fi
    echo "$stage" >>"$fixture/expected-trace"
    grep -Eq "^\| $stage \| passed \| [0-9]+ \| 0 \|$" "$summary"
  done
  cmp "$fixture/expected-trace" "$fixture/trace"
  if [[ "$mutation" == none || "$mutation" == ignored ]]; then
    [[ "$status" == 0 ]]
    grep -Fq 'Result: **passed** (exit 0)' "$summary"
  else
    [[ "$status" == 1 ]]
    grep -Fq 'Result: **failed** (exit 1)' "$summary"
    if grep -Fq 'Preflight passed' "$fixture/output"; then
      echo "FAIL: $name accepted changed inputs" >&2
      exit 1
    fi
  fi
  echo "PASS: preflight source consistency: $name"
}

source_case stable-clean none none clean after
source_case stable-dirty none none dirty after
source_case stable-untracked none none untracked after
source_case ignored-build-output ignored domain-tests clean after
for stage in "${stages[@]}"; do
  source_case "edit-$stage" edit "$stage" clean after
done
for mutation in add delete head mode revert; do
  source_case "$mutation" "$mutation" domain-tests clean after
done
source_case edit-already-dirty edit domain-tests dirty after
source_case stage-existing-edit stage domain-tests dirty after
source_case edit-untracked untracked domain-tests untracked after
source_case before-release edit release clean before

# Report writes must not become part of the source inputs they describe.
status=0
repository="$TEST_ROOT/source-stable-clean/repository"
env RILL_PREFLIGHT_REPORT_DIR="$repository/reports" FIXTURE_PROJECT_DIR="$repository" \
  FAIL_STAGE=none FIXTURE_TRACE="$TEST_ROOT/report-path-trace" \
  "$BASH" "$TEST_ROOT/fixture.sh" "$PROJECT_DIR" >"$TEST_ROOT/report-path-output" 2>&1 || status=$?
[[ "$status" == 1 && ! -e "$TEST_ROOT/report-path-trace" ]]
grep -Fq 'Preflight reports must be outside the checkout or Git-ignored' "$TEST_ROOT/report-path-output"
echo 'PASS: nonignored reports inside the source checkout fail before running stages'
