#!/usr/bin/env bash

set -euo pipefail

error() {
  echo "error: $*" >&2
  exit 64
}

[[ "$#" -gt 0 ]] || error "usage: $0 <build|test> [arguments...]"

subcommand="$1"
shift
case "$subcommand" in
build)
  exec swift build --force-resolved-versions "$@"
  ;;
test)
  exec swift test \
    --force-resolved-versions \
    -Xswiftc -warnings-as-errors \
    "$@"
  ;;
*)
  error "unsupported SwiftPM subcommand: $subcommand"
  ;;
esac
