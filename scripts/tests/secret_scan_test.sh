#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

source "$PROJECT_DIR/scripts/check_repository.sh"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rill-secret-scan-test.XXXXXX")"
cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT INT TERM

TEST_REPO="$TEMP_ROOT/repository"
SNAPSHOT="$TEMP_ROOT/snapshot"
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
  true >/dev/null 2>&1; then
  fail "shallow Git history was accepted"
fi

echo "Secret scan policy tests passed"
