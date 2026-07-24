#!/usr/bin/env bash
#
# Build every arm64 Release product with SwiftPM's default build system.
# The unfiltered build intentionally produces both RillApp and the bundled
# RillSpeechWorker helper from one reviewed package graph.
#
# sherpa-onnx and ONNX Runtime remain reviewed XCFrameworks in vendor/. The
# optional native MLX backend is consumed from the exact Package.resolved graph;
# no dependency checkout is patched during release builds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"

SHOW_BIN_PATH=false

error() {
  echo "✗ $*" >&2
  exit 1
}

verify_metal_toolchain() {
  local output=""

  # Recent Xcode releases install Metal as a separately mounted toolchain.
  # Let xcrun discover that toolchain instead of forcing XcodeDefault, which
  # excludes the downloaded component even when it is installed correctly.
  if ! output="$(xcrun metal -v 2>&1)"; then
    error \
      "The selected Xcode cannot execute its Metal compiler. Install the matching component with" \
      "'xcodebuild -downloadComponent MetalToolchain' or select a stable Xcode build whose Metal" \
      "component is available. Details: $output"
  fi
}

usage() {
  echo "Usage: $0 [--show-bin-path]" >&2
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
  --show-bin-path)
    $SHOW_BIN_PATH && error "--show-bin-path may be specified only once"
    SHOW_BIN_PATH=true
    shift
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    usage
    error "unsupported argument: $1"
    ;;
  esac
done

build_arguments=(
  build
  --manifest-cache none
  --configuration release
  --arch arm64
)
$SHOW_BIN_PATH && build_arguments+=(--show-bin-path)

$SHOW_BIN_PATH || verify_metal_toolchain

exec "$SCRIPT_DIR/swift_locked.sh" "${build_arguments[@]}"
