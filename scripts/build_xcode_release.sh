#!/usr/bin/env bash
#
# Build every arm64 Release product with SwiftPM's Swift Build engine.
# The unfiltered build intentionally produces both RillApp and the bundled
# RillSpeechWorker helper from one reviewed package graph.
#
# The native MLX backend is consumed from the exact Package.resolved graph; no
# dependency checkout is patched during release builds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
RELEASE_SCRATCH_PATH="$PROJECT_DIR/.build/rill-release"

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
  --build-system swiftbuild
  --manifest-cache none
  --configuration release
  --arch arm64
  --scratch-path "$RELEASE_SCRATCH_PATH"
)
$SHOW_BIN_PATH && build_arguments+=(--show-bin-path)

$SHOW_BIN_PATH || verify_metal_toolchain

# ─── Stale cache guard ─────────────────────────────────────────────────────
# Clang dependency-scanning caches break silently when the toolchain or the
# resolved package graph drifts (the failure surfaces as "clang dependency
# scanning failure" / "unable to resolve module dependency"), and an aborted
# dependency fetch leaves corrupt checkouts that never self-heal. Guard the
# scratch path with an environment fingerprint and, as a safety net, wipe and
# retry once when either failure signature slips through. Build failures
# always propagate as a non-zero exit.
FINGERPRINT_PATH="$RELEASE_SCRATCH_PATH/.rill-build-fingerprint"

compute_build_fingerprint() {
  {
    printf 'project=%s\n' "$PROJECT_DIR"
    printf 'swiftc=%s\n' "$(xcrun -f swiftc 2>/dev/null || echo unknown)"
    xcrun swiftc --version 2>/dev/null | head -n 1 || true
    shasum -a 256 "$PROJECT_DIR/Package.resolved" 2>/dev/null | awk '{print "resolved=" $1}'
  } | shasum -a 256 | awk '{print $1}'
}

purge_scratch_if_environment_changed() {
  [[ -d "$RELEASE_SCRATCH_PATH" ]] || return 0
  local current cached=""
  current="$(compute_build_fingerprint)"
  [[ -f "$FINGERPRINT_PATH" ]] && cached="$(<"$FINGERPRINT_PATH")"
  if [[ "$cached" != "$current" ]]; then
    echo "▸ Build environment changed; wiping stale scratch path $RELEASE_SCRATCH_PATH" >&2
    rm -rf "$RELEASE_SCRATCH_PATH"
  fi
}

run_release_build() {
  local log status
  log="$(mktemp -t rill-release-build)"
  set +e
  "$SCRIPT_DIR/swift_locked.sh" "${build_arguments[@]}" 2>&1 | tee "$log"
  status=${PIPESTATUS[0]}
  set -e
  if [[ "$status" -ne 0 ]] \
    && grep -qE "clang dependency scanning failure|unable to resolve module dependency|Failed to clone" "$log"; then
    echo "▸ Detected stale build cache or aborted dependency fetch; wiping $RELEASE_SCRATCH_PATH and retrying once..." >&2
    rm -rf "$RELEASE_SCRATCH_PATH"
    set +e
    "$SCRIPT_DIR/swift_locked.sh" "${build_arguments[@]}"
    status=$?
    set -e
  fi
  rm -f "$log"
  if [[ "$status" -ne 0 ]]; then
    error "Release build failed"
  fi
}

if $SHOW_BIN_PATH; then
  exec "$SCRIPT_DIR/swift_locked.sh" "${build_arguments[@]}"
fi

purge_scratch_if_environment_changed
run_release_build
mkdir -p "$RELEASE_SCRATCH_PATH"
compute_build_fingerprint >"$FINGERPRINT_PATH"
