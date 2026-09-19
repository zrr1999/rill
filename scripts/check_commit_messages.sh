#!/usr/bin/env bash

set -euo pipefail

if (( $# > 2 )); then
  echo "usage: $0 [BASE [HEAD]]" >&2
  exit 2
fi

base="${1:-}"
head="${2:-HEAD}"
head="$(git rev-parse --verify "${head}^{commit}")"
range="$head"
if [[ -n "$base" && "$base" != "0000000000000000000000000000000000000000" ]]; then
  base="$(git rev-parse --verify "${base}^{commit}")"
  range="$base..$head"
fi

revisions="$(git rev-list --reverse "$range")"
[[ -n "$revisions" ]] || exit 0
message_file="$(mktemp)"
trap 'rm -f "$message_file"' EXIT

while IFS= read -r revision; do
  git show --no-patch --format=%B "$revision" > "$message_file"
  echo "Checking commit $revision"
  uvx --no-build --from zendev==0.4.0 \
    --with zendev-commit==0.4.0 --with zendev-review==0.4.0 \
    zendev message check --profile zendev "$message_file"
done <<< "$revisions"
