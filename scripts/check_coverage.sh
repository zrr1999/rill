#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p .artifacts/quality
# SwiftBuild prunes pins outside the domain graph even with forced resolved versions.
lock_snapshot="$(mktemp)"
cp Package.resolved "$lock_snapshot"
trap 'cp "$lock_snapshot" Package.resolved; rm -f "$lock_snapshot"' EXIT
scripts/preflight.sh swift test-domain --build-system swiftbuild --enable-code-coverage --skip RillQualityEvaluations
report="$(scripts/preflight.sh swift test-domain --build-system swiftbuild --enable-code-coverage --show-codecov-path)"
products="$(dirname "$(dirname "$report")")"
profile="$(dirname "$report")/default.profdata"

# SwiftPM's JSON exporter can select only the first test bundle; combine all bundles.
shopt -s nullglob
binaries=()
for binary in "$products"/*.xctest/Contents/MacOS/*; do
  if [[ -f "$binary" && -x "$binary" ]]; then
    binaries+=("$binary")
  fi
done
if [[ "${#binaries[@]}" -eq 0 || ! -s "$profile" ]]; then
  echo "Domain test coverage is missing its binaries or merged profile" >&2
  exit 1
fi
arguments=("${binaries[0]}")
for binary in "${binaries[@]:1}"; do
  arguments+=(-object "$binary")
done
arguments+=(-instr-profile="$profile" -ignore-filename-regex='/(Tests|Evals|checkouts|DerivedSources)/')
xcrun llvm-cov export "${arguments[@]}" -format=lcov >.artifacts/quality/swift.lcov
xcrun llvm-cov show "${arguments[@]}" >.artifacts/quality/swift-coverage.txt
xcrun llvm-cov report "${arguments[@]}" >.artifacts/quality/swift-summary.txt
grep -q '^SF:.*/Sources/' .artifacts/quality/swift.lcov
