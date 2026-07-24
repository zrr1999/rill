#!/usr/bin/env bash

set -euo pipefail

MIN_MACOS="14.0"
REQUIRED_ARCHITECTURE="arm64"
REQUIRE_SHERPA=false

error() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  echo "usage: $0 [--require-sherpa] /path/to/executable" >&2
}

while [[ "$#" -gt 1 ]]; do
  case "$1" in
  --require-sherpa)
    $REQUIRE_SHERPA && error "--require-sherpa may be specified only once"
    REQUIRE_SHERPA=true
    shift
    ;;
  *)
    usage
    error "unsupported argument: $1"
    ;;
  esac
done

[[ "$#" -eq 1 ]] || {
  usage
  error "exactly one executable path is required"
}

executable="$1"
command -v lipo >/dev/null 2>&1 || error "Required command not found: lipo"
command -v nm >/dev/null 2>&1 || error "Required command not found: nm"
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

verify_sherpa_static_linkage() {
  local architecture="$1"
  local symbols=""
  local required_symbol=""

  if ! symbols="$(nm -m -arch "$architecture" "$executable" 2>&1)"; then
    error "Cannot inspect sherpa-onnx linkage in the $architecture slice: $executable"
  fi

  for required_symbol in \
    SherpaOnnxCreateOfflineRecognizer \
    SherpaOnnxCreateVoiceActivityDetector \
    SherpaOnnxOfflineStreamSetOption; do
    grep -Eq \
      "\\(__TEXT,__text\\)[[:space:]]+external[[:space:]]+_${required_symbol}$" \
      <<<"$symbols" \
      || error "Release executable must statically define $required_symbol in the $architecture slice: $executable"
    if grep -Eq "\\(undefined\\).*[[:space:]]_${required_symbol}$" <<<"$symbols"; then
      error "Release executable must not dynamically resolve $required_symbol in the $architecture slice: $executable"
    fi
  done
  # The no-TTS build keeps inert C-ABI stubs for compatibility, so gate the
  # implementation symbols that prove Piper/eSpeak code was actually linked.
  if grep -Eq \
    '(_espeak_|__ZN5piper|CallPhonemizeEspeak|phonemize_eSpeak)' \
    <<<"$symbols"; then
    error "Release executable must exclude Piper and eSpeak implementation code in the $architecture slice: $executable"
  fi
}

if $REQUIRE_SHERPA; then
  verify_sherpa_static_linkage "$REQUIRED_ARCHITECTURE"
fi
