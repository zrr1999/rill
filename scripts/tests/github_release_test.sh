#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/scripts" "$TEST_ROOT/bin"
cp "$PROJECT_DIR/scripts/release.sh" "$TEST_ROOT/scripts/release.sh"
printf 'Candidate notes\n' >"$TEST_ROOT/notes.md"
export EVENTS="$TEST_ROOT/events"
export PATH="$TEST_ROOT/bin:$PATH"
cat >"$TEST_ROOT/bin/git" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'rev-parse HEAD') echo commit ;;
  'rev-parse refs/tags/v1.2.3^{commit}') echo "commit" ;;
  'rev-parse refs/tags/v1.2.3') echo tag-object ;;
  'status --porcelain --untracked-files=all') : ;;
  *) exit 90 ;;
esac
MOCK
cat >"$TEST_ROOT/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'api repos/zrr1999/rill/git/ref/tags/v1.2.3 --jq .object.sha')
    if [[ "${DRIFT:-}" == yes && -f "$EVENTS" ]]; then echo moved; else echo "tag-object"; fi ;;
  'api --paginate repos/zrr1999/rill/releases --jq '* )
    : ;;
  'release create '* )
    printf '%s\n' "$@" >> "$EVENTS"
    [[ "${UPLOAD_FAILURE:-}" != yes ]] ;;
  *) exit 91 ;;
esac
MOCK
cat >"$TEST_ROOT/scripts/notarize.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == --notarize ]] || exit 92
printf 'build\n' >> "$EVENTS"
printf 'new notarized fixture\n' > "$RELEASE_OUTPUT_DIR/Rill.dmg"
(cd "$RELEASE_OUTPUT_DIR" && shasum -a 256 Rill.dmg > Rill.dmg.sha256)
if [[ "${BAD_HASH:-}" == yes ]]; then printf 'tampered\n' >> "$RELEASE_OUTPUT_DIR/Rill.dmg"; fi
MOCK
chmod +x "$TEST_ROOT/bin/"* "$TEST_ROOT/scripts/"*.sh
export RILL_NOTARIZE_SCRIPT="$TEST_ROOT/scripts/notarize.sh"
run() {
  env "$@" bash "$TEST_ROOT/scripts/release.sh" github v1.2.3 "$TEST_ROOT/notes.md" >"$TEST_ROOT/output" 2>&1
}

expect_no_upload() {
  local expected="$1"
  shift
  rm -f "$EVENTS"
  if run "$@"; then
    echo "Unexpected success: $*" >&2
    exit 1
  fi
  grep -F -- "$expected" "$TEST_ROOT/output" >/dev/null
  if grep -qx create "$EVENTS"; then
    echo "Unexpected upload: $*" >&2
    exit 1
  fi
  echo "PASS: $* prevents upload"
}

expect_no_upload 'Rill.dmg: FAILED' BAD_HASH=yes
expect_no_upload 'Remote tag does not match local tag' DRIFT=yes
rm -f "$EVENTS"
run
grep -Fx -- --draft "$EVENTS" >/dev/null
test "$(grep -cE '/Rill.dmg(\.sha256)?$' "$EVENTS")" = 2
echo 'PASS: notarized build uploads both assets as a draft'

rm -f "$EVENTS"
export UPLOAD_FAILURE=yes
if run; then
  echo 'Unexpected upload success'
  exit 1
fi
grep -qx create "$EVENTS"
candidate="$(sed -n 's/^Candidate directory: //p' "$TEST_ROOT/output")"
test -s "$candidate/Rill.dmg"
test -s "$candidate/release-notes.md"
(cd "$candidate" && shasum -a 256 --check Rill.dmg.sha256)
echo 'PASS: failed upload retains candidate and notes'
