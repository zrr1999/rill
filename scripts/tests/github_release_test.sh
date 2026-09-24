#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/scripts" "$TEST_ROOT/bin"
cp "$PROJECT_DIR/scripts/github_release.sh" "$TEST_ROOT/scripts/"
printf 'Candidate notes\n' > "$TEST_ROOT/notes.md"
export EVENTS="$TEST_ROOT/events"
export PATH="$TEST_ROOT/bin:$PATH"
cat > "$TEST_ROOT/bin/git" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'rev-parse HEAD') echo commit ;;
  'rev-parse refs/tags/v1.2.3^{commit}') echo "${LOCAL_COMMIT:-commit}" ;;
  'rev-parse refs/tags/v1.2.3') echo tag-object ;;
  'status --porcelain --untracked-files=all') printf '%s' "${DIRTY:-}" ;;
  *) exit 90 ;;
esac
MOCK
cat > "$TEST_ROOT/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'api repos/zrr1999/rill/git/ref/tags/v1.2.3 --jq .object.sha')
    if [[ "${DRIFT:-}" == yes && -f "$EVENTS" ]]; then echo moved; else echo "${REMOTE_OBJECT:-tag-object}"; fi ;;
  'api --paginate repos/zrr1999/rill/releases --jq '* )
    [[ "${API_FAILURE:-}" != yes ]] || exit 1
    printf '%s' "${EXISTING:-}" ;;
  'release create '* )
    printf '%s\n' "$@" >> "$EVENTS"
    [[ "${UPLOAD_FAILURE:-}" != yes ]] ;;
  *) exit 91 ;;
esac
MOCK
cat > "$TEST_ROOT/scripts/release.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == --notarize ]] || exit 92
printf 'build\n' >> "$EVENTS"
[[ "${BUILD_FAILURE:-}" != yes ]] || exit 1
printf 'new notarized fixture\n' > "$RELEASE_OUTPUT_DIR/Rill.dmg"
(cd "$RELEASE_OUTPUT_DIR" && shasum -a 256 Rill.dmg > Rill.dmg.sha256)
if [[ "${BAD_HASH:-}" == yes ]]; then printf 'tampered\n' >> "$RELEASE_OUTPUT_DIR/Rill.dmg"; fi
MOCK
chmod +x "$TEST_ROOT/bin/"* "$TEST_ROOT/scripts/"*.sh
run() { bash "$TEST_ROOT/scripts/github_release.sh" "${TAG:-v1.2.3}" "$TEST_ROOT/notes.md" > "$TEST_ROOT/output" 2>&1; }
for scenario in invalid-tag local-mismatch dirty remote-mismatch api-failure existing build-failure bad-hash drift; do
  rm -f "$EVENTS"
  unset TAG LOCAL_COMMIT DIRTY REMOTE_OBJECT API_FAILURE EXISTING BUILD_FAILURE BAD_HASH DRIFT
  case "$scenario" in
    invalid-tag) export TAG='v1.2.3;exit' ;;
    local-mismatch) export LOCAL_COMMIT=other ;;
    dirty) export DIRTY=' M README.md' ;;
    remote-mismatch) export REMOTE_OBJECT=other ;;
    api-failure) export API_FAILURE=yes ;;
    existing) export EXISTING=123 ;;
    build-failure) export BUILD_FAILURE=yes ;;
    bad-hash) export BAD_HASH=yes ;;
    drift) export DRIFT=yes ;;
  esac
  if run; then echo "Unexpected success: $scenario"; exit 1; fi
  if [[ -f "$EVENTS" ]] && grep -q '^create$' "$EVENTS"; then echo "Unexpected upload: $scenario"; exit 1; fi
  echo "PASS: $scenario prevents upload"
done
unset DRIFT
rm -f "$EVENTS"
run
for argument in build create v1.2.3 --verify-tag --draft --notes-file zrr1999/rill; do
  grep -Fx -- "$argument" "$EVENTS" >/dev/null
done
grep -E '/Rill.dmg(\.sha256)?$' "$EVENTS" | test "$(wc -l | tr -d ' ')" = 2
! grep -Fx -- --clobber "$EVENTS"
echo 'PASS: notarized build uploads both assets as a draft'
export UPLOAD_FAILURE=yes
if run; then echo 'Unexpected upload success'; exit 1; fi
candidate="$(sed -n 's/^Candidate directory: //p' "$TEST_ROOT/output")"
test -s "$candidate/Rill.dmg"
test -s "$candidate/release-notes.md"
echo 'PASS: failed upload retains candidate and notes'
