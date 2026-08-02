#!/usr/bin/env bash

set -euo pipefail

MIN_MACOS="14.0"
REQUIRED_ARCHITECTURE="arm64"

error() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  echo "usage: $0 /path/to/executable" >&2
}

[[ "$#" -eq 1 ]] || {
  usage
  error "exactly one executable path is required"
}

executable="$1"
command -v lipo >/dev/null 2>&1 || error "Required command not found: lipo"
command -v xcrun >/dev/null 2>&1 || error "Required command not found: xcrun"
[[ -f "$executable" && -x "$executable" && ! -L "$executable" ]] \
  || error "Release executable must be an executable regular non-symlink file: $executable"

architectures=""
if ! architectures="$(lipo "$executable" -archs 2>&1)"; then
  error "Cannot inspect release executable architecture: $executable"
fi
[[ "$architectures" == "$REQUIRED_ARCHITECTURE" ]] \
  || error "Release executable must contain only arm64: $executable"

verify_build_version() {
  local architecture="$1"
  local build_output=""
  local summary=""
  local build_command_count=""
  local platform_count=""
  local macos_platform_count=""
  local minos_count=""
  local expected_minos_count=""

  if ! build_output="$(
    xcrun vtool -arch "$architecture" -show-build "$executable" 2>&1
  )"; then
    error "Cannot inspect LC_BUILD_VERSION for $architecture: $executable"
  fi

  summary="$(
    printf '%s\n' "$build_output" | awk -v expected_minos="$MIN_MACOS" '
      $1 == "cmd" && $2 == "LC_BUILD_VERSION" { build_command_count += 1 }
      $1 == "platform" {
        platform_count += 1
        if ($2 == "MACOS") { macos_platform_count += 1 }
      }
      $1 == "minos" {
        minos_count += 1
        if ($2 == expected_minos) { expected_minos_count += 1 }
      }
      END {
        printf "%d|%d|%d|%d|%d", build_command_count, platform_count,
          macos_platform_count, minos_count, expected_minos_count
      }
    '
  )"
  IFS='|' read -r \
    build_command_count \
    platform_count \
    macos_platform_count \
    minos_count \
    expected_minos_count <<<"$summary"

  [[ "$build_command_count" == "1" ]] \
    || error "Release executable $architecture slice must contain exactly one LC_BUILD_VERSION: $executable"
  [[ "$platform_count" == "1" && "$macos_platform_count" == "1" ]] \
    || error "Release executable $architecture slice must target the macOS platform: $executable"
  [[ "$minos_count" == "1" && "$expected_minos_count" == "1" ]] \
    || error "Release executable $architecture slice must require macOS $MIN_MACOS exactly: $executable"
}

verify_build_version "$REQUIRED_ARCHITECTURE"
