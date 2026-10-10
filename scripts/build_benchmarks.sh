#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/.."
mkdir -p .artifacts/benchmarks

use_codspeed=false
preview_only=false
for argument in "$@"; do
  case "$argument" in
    --codspeed) use_codspeed=true ;;
    --preview-only) preview_only=true ;;
    *) echo "Usage: $0 [--codspeed] [--preview-only]" >&2; exit 1 ;;
  esac
done

case "$(uname -s)" in
  Darwin)
    compiler=(xcrun swiftc -target arm64-apple-macosx26.0)
    c_compiler=(xcrun clang -target arm64-apple-macosx26.0)
    ;;
  Linux)
    if ! $preview_only; then
      echo "Linux supports --preview-only; encrypted buffer benchmarks require macOS." >&2
      exit 1
    fi
    compiler=(swiftc)
    c_compiler=(clang)
    ;;
  *) echo "Unsupported benchmark platform: $(uname -s)" >&2; exit 1 ;;
esac
compiler+=(-swift-version 6 -package-name RillMacOS -O -g -parse-as-library)
benchmark_compiler=("${compiler[@]}")

if $use_codspeed; then
    revision=4c76dbb5b99fc4927289281c7b7ca71cc46e6836
    archive="$PWD/.artifacts/benchmarks/cache/instrument-hooks-$revision.tar.gz"
    hooks="$PWD/.artifacts/benchmarks/instrument-hooks-$revision"
    mkdir -p "$(dirname "$archive")" "$hooks"
    if [[ ! -f "$archive" ]]; then
      curl --fail --location --proto '=https' --proto-redir '=https' --silent --show-error \
        "https://github.com/CodSpeedHQ/instrument-hooks/archive/$revision.tar.gz" \
        -o "$archive"
    fi
    echo "d7c1c8f6496cb7d1a379f35a5f4e2fbb5dbe00f5e030e7ecda26ee088d20d11b  $archive" | shasum -a 256 --check
    tar -xzf "$archive" -C "$hooks" --strip-components=1
    "${c_compiler[@]}" -O2 -I "$hooks/includes" -c "$hooks/dist/core.c" \
      -o .artifacts/benchmarks/instrument-hooks.o
    benchmark_compiler+=(-D CODSPEED -import-objc-header "$hooks/includes/core.h" \
      .artifacts/benchmarks/instrument-hooks.o)
fi

# Compile production modules directly, without the app's MLX graph.
"${benchmark_compiler[@]}" \
  Sources/RillCore/RecordTextFormatting.swift Benchmarks/RecordTextBenchmarks.swift \
  Benchmarks/CodSpeedResults.swift Benchmarks/CodSpeedRecorder.swift \
  -o .artifacts/benchmarks/record-text

.artifacts/benchmarks/record-text
if $preview_only; then
  exit 0
fi

modules="$PWD/.artifacts/benchmarks/modules"
mkdir -p "$modules"
# Build the persistence dependency with its upstream SwiftPM settings and the
# application's exact lock, then link those objects into the standalone workload.
# The native engine keeps the per-target object and module layout read below;
# the build driver otherwise selects SwiftBuild for string catalog resources.
grdb_build=(scripts/preflight.sh swift build --build-system native --configuration release)
"${grdb_build[@]}" --target GRDB
grdb_products="$("${grdb_build[@]}" --show-bin-path)"
grdb_module_map="$PWD/.artifacts/build/release/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap"
grdb_objects=("$grdb_products"/GRDB.build/*.o)
test -f "${grdb_objects[0]}"
dependency_flags=(-I "$grdb_products/Modules" -Xcc "-fmodule-map-file=$grdb_module_map")
for module in RillCore RillRecords RillPersistence; do
  "${compiler[@]}" -emit-library -static -emit-module -module-name "$module" \
    -emit-module-path "$modules/$module.swiftmodule" -I "$modules" "${dependency_flags[@]}" \
    Sources/"$module"/*.swift -o "$modules/lib$module.a"
done
"${benchmark_compiler[@]}" -I "$modules" -L "$modules" "${dependency_flags[@]}" \
  "${grdb_objects[@]}" \
  -lRillRecords -lRillPersistence -lRillCore -lsqlite3 \
  Benchmarks/RecordBufferBenchmarks.swift Benchmarks/CodSpeedResults.swift Benchmarks/CodSpeedRecorder.swift \
  -o .artifacts/benchmarks/record-buffer

.artifacts/benchmarks/record-buffer
