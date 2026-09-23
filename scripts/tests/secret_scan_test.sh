#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

source "$PROJECT_DIR/scripts/check_secrets.sh"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rill-secret-scan-test.XXXXXX")"
cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT INT TERM

TEST_REPO="$TEMP_ROOT/repository"
SNAPSHOT="$TEMP_ROOT/snapshot"
FAKE_LOG="$TEMP_ROOT/gitleaks.log"
FAKE_GITLEAKS="$TEMP_ROOT/gitleaks"
mkdir -p "$TEST_REPO/tracked" "$TEST_REPO/ignored" "$SNAPSHOT"
git -C "$TEST_REPO" init -q
git -C "$TEST_REPO" config user.email test@example.invalid
git -C "$TEST_REPO" config user.name "Secret Scan Test"
printf 'ignored/\n' >"$TEST_REPO/.gitignore"
printf 'tracked\n' >"$TEST_REPO/tracked/kept.txt"
printf 'deleted\n' >"$TEST_REPO/tracked/deleted.txt"
git -C "$TEST_REPO" add .gitignore tracked/kept.txt tracked/deleted.txt
rm "$TEST_REPO/tracked/deleted.txt"
printf 'untracked\n' >"$TEST_REPO/current.txt"
printf 'ignored\n' >"$TEST_REPO/ignored/local.txt"

copy_current_source_snapshot "$TEST_REPO" "$SNAPSHOT"
[[ -f "$SNAPSHOT/.gitignore" ]] || fail "tracked .gitignore was omitted"
[[ -f "$SNAPSHOT/tracked/kept.txt" ]] || fail "tracked source was omitted"
[[ -f "$SNAPSHOT/current.txt" ]] || fail "untracked nonignored source was omitted"
[[ ! -e "$SNAPSHOT/tracked/deleted.txt" ]] || fail "tracked deletion was resurrected"
[[ ! -e "$SNAPSHOT/ignored/local.txt" ]] || fail "ignored artifact entered the snapshot"

SYMLINK_SNAPSHOT="$TEMP_ROOT/symlink-snapshot"
mkdir -p "$SYMLINK_SNAPSHOT"
ln -s tracked/kept.txt "$TEST_REPO/current-link.txt"
if copy_current_source_snapshot \
  "$TEST_REPO" \
  "$SYMLINK_SNAPSHOT" >/dev/null 2>&1; then
  fail "a current-source symlink was accepted instead of failing closed"
fi
rm "$TEST_REPO/current-link.txt"

STABILITY_SNAPSHOT="$TEMP_ROOT/stability-snapshot"
STABILITY_MANIFEST="$TEMP_ROOT/stability-files.zlist"
mkdir -p "$STABILITY_SNAPSHOT"
copy_current_source_snapshot \
  "$TEST_REPO" \
  "$STABILITY_SNAPSHOT" \
  "$STABILITY_MANIFEST"
verify_current_source_snapshot \
  "$TEST_REPO" \
  "$STABILITY_SNAPSHOT" \
  "$STABILITY_MANIFEST"
printf 'changed during scan\n' >"$TEST_REPO/current.txt"
if verify_current_source_snapshot \
  "$TEST_REPO" \
  "$STABILITY_SNAPSHOT" \
  "$STABILITY_MANIFEST" >/dev/null 2>&1; then
  fail "current-source byte drift during scanning was accepted"
fi
printf 'untracked\n' >"$TEST_REPO/current.txt"

NOT_A_REPOSITORY="$TEMP_ROOT/not-a-repository"
mkdir -p "$NOT_A_REPOSITORY" "$TEMP_ROOT/failed-list-snapshot"
if copy_current_source_snapshot \
  "$NOT_A_REPOSITORY" \
  "$TEMP_ROOT/failed-list-snapshot" >/dev/null 2>&1; then
  fail "git ls-files failure was swallowed"
fi

cat >"$FAKE_GITLEAKS" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "version" ]]; then
  echo "8.30.1"
  exit 0
fi
printf '%s\n' "$*" >>"$FAKE_LOG"
for required in --config --redact --no-banner --no-color --timeout; do
  [[ " $* " == *" $required "* ]] || exit 90
done
FAKE
chmod +x "$FAKE_GITLEAKS"
export FAKE_LOG

verify_gitleaks_binary "$FAKE_GITLEAKS"
run_secret_scan "$TEST_REPO" "$PROJECT_DIR/.gitleaks.toml" "$FAKE_GITLEAKS"
grep -Eq '^git .* --redact .*' "$FAKE_LOG" || fail "Git history scan was not invoked safely"
grep -Eq '^dir .* --redact .*' "$FAKE_LOG" || fail "current source scan was not invoked safely"

MUTATING_GITLEAKS="$TEMP_ROOT/gitleaks-mutating-source"
cat >"$MUTATING_GITLEAKS" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "version" ]]; then
  echo "8.30.1"
  exit 0
fi
if [[ "${1:-}" == "git" ]]; then
  exit 0
fi
if [[ "${1:-}" == "dir" ]]; then
  printf 'mutated after snapshot\n' >"$MUTATION_TARGET"
  exit 0
fi
exit 64
FAKE
chmod +x "$MUTATING_GITLEAKS"
export MUTATION_TARGET="$TEST_REPO/current.txt"
if run_secret_scan \
  "$TEST_REPO" \
  "$PROJECT_DIR/.gitleaks.toml" \
  "$MUTATING_GITLEAKS" >/dev/null 2>&1; then
  fail "source mutation after the Gitleaks snapshot was accepted"
fi
printf 'untracked\n' >"$TEST_REPO/current.txt"

SHALLOW_SOURCE="$TEMP_ROOT/shallow-source"
SHALLOW_CLONE="$TEMP_ROOT/shallow-clone"
mkdir -p "$SHALLOW_SOURCE"
git -C "$SHALLOW_SOURCE" init -q
git -C "$SHALLOW_SOURCE" config user.email test@example.invalid
git -C "$SHALLOW_SOURCE" config user.name "Secret Scan Test"
git -C "$SHALLOW_SOURCE" config commit.gpgsign false
printf 'source\n' >"$SHALLOW_SOURCE/source.txt"
git -C "$SHALLOW_SOURCE" add source.txt
git -C "$SHALLOW_SOURCE" commit -qm "test: create shallow source"
git clone -q --depth 1 "file://$SHALLOW_SOURCE" "$SHALLOW_CLONE"
[[ "$(git -C "$SHALLOW_CLONE" rev-parse --is-shallow-repository)" == "true" ]] \
  || fail "test fixture is not a shallow clone"
if run_secret_scan \
  "$SHALLOW_CLONE" \
  "$PROJECT_DIR/.gitleaks.toml" \
  "$FAKE_GITLEAKS" >/dev/null 2>&1; then
  fail "shallow Git history was accepted"
fi

WRONG_GITLEAKS="$TEMP_ROOT/gitleaks-wrong"
cat >"$WRONG_GITLEAKS" <<'FAKE'
#!/usr/bin/env bash
echo "8.29.0"
FAKE
chmod +x "$WRONG_GITLEAKS"
if verify_gitleaks_binary "$WRONG_GITLEAKS" >/dev/null 2>&1; then
  fail "wrong Gitleaks version was accepted"
fi
if wrong_version_message="$(verify_gitleaks_binary "$WRONG_GITLEAKS" 2>&1)"; then
  fail "wrong Gitleaks version was accepted while checking its recovery hint"
fi
[[ "$wrong_version_message" == *"scripts/install_gitleaks.sh --destination DIR"* ]] \
  || fail "wrong-version failure does not provide an installation command"

FAILURE_MARKER="$TEMP_ROOT/failing-snapshot-path"
FAILING_GITLEAKS="$TEMP_ROOT/gitleaks-failing-dir"
cat >"$FAILING_GITLEAKS" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "version" ]]; then
  echo "8.30.1"
  exit 0
fi
if [[ "${1:-}" == "git" ]]; then
  exit 0
fi
if [[ "${1:-}" == "dir" ]]; then
  snapshot_path="${!#}"
  printf '%s\n' "$snapshot_path" >"$FAILURE_MARKER"
  exit 17
fi
exit 18
FAKE
chmod +x "$FAILING_GITLEAKS"
export FAILURE_MARKER
if run_secret_scan \
  "$TEST_REPO" \
  "$PROJECT_DIR/.gitleaks.toml" \
  "$FAILING_GITLEAKS" >/dev/null 2>&1; then
  fail "a failed current-source scan was accepted"
fi
FAILED_SNAPSHOT="$(cat "$FAILURE_MARKER")"
[[ ! -e "$FAILED_SNAPSHOT" ]] \
  || fail "failed current-source scan left its sensitive snapshot behind"

grep -Fq 'b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5' \
  "$PROJECT_DIR/scripts/install_gitleaks.sh" \
  || fail "Darwin arm64 release hash is not pinned"
grep -Fq 'dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709' \
  "$PROJECT_DIR/scripts/install_gitleaks.sh" \
  || fail "Darwin x64 release hash is not pinned"
grep -Fq '551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb' \
  "$PROJECT_DIR/scripts/install_gitleaks.sh" \
  || fail "Linux x64 release hash is not pinned"
grep -Fq 'bash "$SCRIPT_DIR/check_secrets.sh"' "$PROJECT_DIR/scripts/preflight.sh" \
  || fail "preflight does not invoke secret scanning"
echo "Secret scan policy tests passed"
