#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
# Build arenas contain third-party actions; check only Git-visible repository files.
files=()
while IFS= read -r -d '' path; do
  case "$path" in
  .github/workflows/*.yml | .github/workflows/*.yaml | .github/workflows/actions.lock | .github/dependabot.yml | .github/dependabot.yaml | action.yml | action.yaml | */action.yml | */action.yaml)
    files+=("$path")
    ;;
  esac
done < <(git ls-files --cached --others --exclude-standard -z)
if [[ "${#files[@]}" -eq 0 ]]; then
  echo "No repository workflows or actions found" >&2
  exit 1
fi
jactionlint --shellcheck=shellcheck --pyflakes=pyflakes "$@" "${files[@]}"
