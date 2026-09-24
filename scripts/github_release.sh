#!/usr/bin/env bash
# Build a notarized candidate and upload it to a new GitHub Release draft.
set -euo pipefail

error() { echo "error: $*" >&2; exit 1; }
if [[ $# != 2 ]]; then
  error "Usage: bash scripts/github_release.sh vMAJOR.MINOR.PATCH NOTES.md"
fi
TAG="$1"
[[ "$TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || error "Invalid release tag"
[[ -s "$2" ]] || error "Release notes must be a nonempty file"
NOTES="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$PROJECT_DIR"

command -v gh >/dev/null || error "Install GitHub CLI and authenticate first"
# An explicit destination prevents local gh defaults from targeting another fork.
REPOSITORY="zrr1999/rill"
HEAD_COMMIT="$(git rev-parse HEAD)"
[[ "$(git rev-parse "refs/tags/$TAG^{commit}")" == "$HEAD_COMMIT" ]] || error "Tag must point at HEAD"
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || error "Working tree must be clean"

TAG_OBJECT="$(git rev-parse "refs/tags/$TAG")"
verify_remote_tag() {
  local remote_object
  remote_object="$(gh api "repos/$REPOSITORY/git/ref/tags/$TAG" --jq .object.sha)"
  [[ "$remote_object" == "$TAG_OBJECT" ]] || error "Remote tag does not match local tag"
}
verify_remote_tag
# List failures (including authentication/network failures) must stop the build.
EXISTING="$(gh api --paginate "repos/$REPOSITORY/releases" --jq ".[] | select(.tag_name == \"$TAG\") | .id")"
[[ -z "$EXISTING" ]] || error "Release already exists; inspect it before retrying"

# A unique retained directory keeps concurrent candidates and upload retries apart.
mkdir -p .artifacts/release
CANDIDATE_DIR="$(mktemp -d "$PROJECT_DIR/.artifacts/release/github-$TAG.XXXXXX")"
cp "$NOTES" "$CANDIDATE_DIR/release-notes.md"
echo "Candidate directory: $CANDIDATE_DIR"
RELEASE_OUTPUT_DIR="$CANDIDATE_DIR" bash scripts/release.sh --notarize
[[ "$(git rev-parse HEAD)" == "$HEAD_COMMIT" ]] || error "HEAD changed during build"
verify_remote_tag
[[ -s "$CANDIDATE_DIR/Rill.dmg" && -s "$CANDIDATE_DIR/Rill.dmg.sha256" ]] || error "Missing notarized release artifacts"
(
  cd "$CANDIDATE_DIR"
  shasum -a 256 --check Rill.dmg.sha256
)
gh release create "$TAG" \
  "$CANDIDATE_DIR/Rill.dmg" "$CANDIDATE_DIR/Rill.dmg.sha256" \
  --repo "$REPOSITORY" --verify-tag --draft \
  --title "Rill $TAG" --notes-file "$CANDIDATE_DIR/release-notes.md"
echo "Draft uploaded. Complete QA against these exact assets before publishing."
