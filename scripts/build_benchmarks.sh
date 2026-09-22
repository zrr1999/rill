#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/.."
mkdir -p .artifacts/benchmarks

compiler=(xcrun swiftc -swift-version 6 -O -g -parse-as-library
  -target arm64-apple-macosx14.0
  Sources/RillCore/RecordTextFormatting.swift Benchmarks/RecordTextBenchmarks.swift
  Benchmarks/CodSpeedResults.swift)
case "${1:-}" in
  "") ;;
  --codspeed)
    revision=4c76dbb5b99fc4927289281c7b7ca71cc46e6836
    archive="$PWD/.artifacts/benchmarks/cache/instrument-hooks-$revision.tar.gz"
    hooks="$PWD/.artifacts/benchmarks/instrument-hooks-$revision"
    mkdir -p "$(dirname "$archive")" "$hooks"
    if [[ ! -f "$archive" ]]; then
      curl --fail --location --silent --show-error \
        "https://github.com/CodSpeedHQ/instrument-hooks/archive/$revision.tar.gz" \
        -o "$archive"
    fi
    echo "d7c1c8f6496cb7d1a379f35a5f4e2fbb5dbe00f5e030e7ecda26ee088d20d11b  $archive" | shasum -a 256 --check
    tar -xzf "$archive" -C "$hooks" --strip-components=1
    xcrun clang -O2 -target arm64-apple-macosx14.0 -I "$hooks/includes" -c "$hooks/dist/core.c" \
      -o .artifacts/benchmarks/instrument-hooks.o
    compiler+=(-D CODSPEED -import-objc-header "$hooks/includes/core.h" \
      .artifacts/benchmarks/instrument-hooks.o)
    ;;
  *) echo "Usage: $0 [--codspeed]" >&2; exit 1 ;;
esac

# Compile the production implementation directly, without the app's MLX graph.
"${compiler[@]}" -o .artifacts/benchmarks/record-text

.artifacts/benchmarks/record-text
