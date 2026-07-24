#!/usr/bin/env bash

set -euo pipefail

SHERPA_VERSION="1.13.4"
SHERPA_COMMIT="142807252687d81b40d6315f23470a1512a00de3"
SHERPA_SOURCE_URL="https://github.com/k2-fsa/sherpa-onnx/archive/$SHERPA_COMMIT.tar.gz"
EXPECTED_SOURCE_ARCHIVE_SHA256="f0dc7c9b41b8691313daee671e826eb23946fa1320559a8d37e84f8774af76b2"
EXPECTED_TAGGED_VERSION_FILE_SHA256="43b7e9732fa187e74a99b0c63300cc1708d32687487d8f3855e385a624aa95e8"
EXPECTED_VERSION_FILE_SHA256="51bb5a65611dac3a3ebba791d0473d26e63bf5f143258ed4dda2d495afac06b5"
EXPECTED_ARCHIVE_SHA256="8950e345310f223d3be649c80de8059957a2a01f8553cca24c99071a6a292db6"
EXPECTED_INFO_PLIST_SHA256="789acaf7864ac8784bfe62902545b2b9cc7751957d50b49c23ebf106a8e67a4d"
EXPECTED_HEADER_SHA256="587e1039cc4ee242169494f3c0ba5baecc22482341168d88d57db965e1e77fa9"
EXPECTED_KALDI_NATIVE_FBANK_CMAKE_SHA256="619f0046f568e85790f4180899e666053f246f5c0fc36c951421441f3e992e38"
EXPECTED_PATCHED_KALDI_NATIVE_FBANK_CMAKE_SHA256="14f8309a7da8c09f3b3af935cea5aa933d0cb0211ca5279861c658ed0b5e90e4"

error() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || error "Required command not found: $1"
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

fetch_reviewed_input() {
  local name="$1"
  local url="$2"
  local expected_sha256="$3"
  local destination="$4"
  local partial="$destination.part"

  echo "▸ Fetching reviewed $name input..."
  curl --proto '=https' --tlsv1.2 --fail --location --retry 3 \
    --silent --show-error "$url" --output "$partial"
  [[ "$(sha256_file "$partial")" == "$expected_sha256" ]] \
    || error "$name source archive differs from the reviewed bytes"
  mv "$partial" "$destination"
}

extract_reviewed_input() {
  local name="$1"
  local archive="$2"
  local destination="$3"
  local root_count=""

  if tar -tf "$archive" | awk '
    /^\// || /(^|\/)\.\.($|\/)/ { unsafe = 1 }
    END { exit unsafe ? 0 : 1 }
  '; then
    error "$name source archive contains an unsafe path"
  fi
  root_count="$(tar -tf "$archive" | awk -F/ '$1 != "" { print $1 }' | sort -u | wc -l | tr -d ' ')"
  [[ "$root_count" == "1" ]] \
    || error "$name source archive must contain exactly one top-level directory"
  mkdir -p "$destination"
  tar -xf "$archive" --strip-components 1 -C "$destination"
  find "$destination" -type f -print -quit | grep -q . \
    || error "$name source archive extracted no regular files"
}

[[ "$#" -eq 1 ]] \
  || error "usage: $0 /path/to/empty-output-directory"

case "$1" in
  /*) OUTPUT_ROOT="$1" ;;
  *) OUTPUT_ROOT="$(pwd -P)/$1" ;;
esac

[[ ! -e "$OUTPUT_ROOT" ]] \
  || error "Output path already exists: $OUTPUT_ROOT"

for command in curl tar sed cmake ninja libtool lipo nm strings xcodebuild shasum awk grep sort wc tr find mv; do
  require_command "$command"
done

WORK_ROOT_CANDIDATE="$(mktemp -d "${TMPDIR:-/tmp}/rill-sherpa-build.XXXXXX")"
WORK_ROOT="$(cd "$WORK_ROOT_CANDIDATE" && pwd -P)"
SOURCE_ROOT="$WORK_ROOT/sherpa-onnx"
SOURCE_ARCHIVE="$WORK_ROOT/sherpa-onnx-$SHERPA_COMMIT.tar.gz"
BUILD_ROOT="$WORK_ROOT/build"
INSTALL_ROOT="$WORK_ROOT/install"
STAGING_ROOT="$WORK_ROOT/staging"
MERGED_ARCHIVE="$STAGING_ROOT/libsherpa-onnx.a"
# This path is part of the reviewed archive's byte-level provenance. Keep the
# historical namespace so rebuilding after the product rename remains
# reproducible and does not invalidate the audited artifact hashes.
REPRODUCIBLE_BUILD_ROOT="/usr/src/voxtype/sherpa-runtime"
C_FLAGS="-ffile-prefix-map=$WORK_ROOT=$REPRODUCIBLE_BUILD_ROOT"
CXX_FLAGS="-DEIGEN_MPL2_ONLY $C_FLAGS"

cleanup() {
  rm -rf -- "$WORK_ROOT"
}
trap cleanup EXIT INT TERM

fetch_reviewed_input \
  "sherpa-onnx v$SHERPA_VERSION" \
  "$SHERPA_SOURCE_URL" \
  "$EXPECTED_SOURCE_ARCHIVE_SHA256" \
  "$SOURCE_ARCHIVE"
extract_reviewed_input "sherpa-onnx v$SHERPA_VERSION" "$SOURCE_ARCHIVE" "$SOURCE_ROOT"

# Fetch every transitive native input before configuration, verify its exact
# reviewed bytes, and extract it into the same deterministic _deps path CMake
# normally uses. Source-directory overrides plus FULLY_DISCONNECTED prevent a
# nested FetchContent rule from silently falling back to the network.
INPUT_NAMES=(
  kaldi-native-fbank
  KissFFT
  kaldi-decoder
  kaldifst
  OpenFST
  Eigen
  simple-sentencepiece
  nlohmann-json
  ONNX-Runtime
)
INPUT_FILENAMES=(
  kaldi-native-fbank-1.22.3.tar.gz
  kissfft-8a8e66e33d692bad1376fe7904d87d767730537f.zip
  kaldi-decoder-0.3.0.tar.gz
  kaldifst-1.8.0.tar.gz
  openfst-1.8.5-2026-04-11.tar.gz
  eigen-5.0.1.tar.gz
  simple-sentencepiece-0.7.tar.gz
  json-3.12.0.tar.gz
  onnxruntime-osx-universal2-static_lib-1.27.0.zip
)
INPUT_URLS=(
  https://github.com/csukuangfj/kaldi-native-fbank/archive/refs/tags/v1.22.3.tar.gz
  https://github.com/mborgerding/kissfft/archive/8a8e66e33d692bad1376fe7904d87d767730537f.zip
  https://github.com/k2-fsa/kaldi-decoder/archive/refs/tags/v0.3.0.tar.gz
  https://github.com/k2-fsa/kaldifst/archive/refs/tags/v1.8.0.tar.gz
  https://github.com/csukuangfj/openfst/archive/refs/tags/v1.8.5-2026-04-11.tar.gz
  https://gitlab.com/libeigen/eigen/-/archive/5.0.1/eigen-5.0.1.tar.gz
  https://github.com/pkufool/simple-sentencepiece/archive/refs/tags/v0.7.tar.gz
  https://github.com/nlohmann/json/archive/refs/tags/v3.12.0.tar.gz
  https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.27.0/onnxruntime-osx-universal2-static_lib-1.27.0.zip
)
INPUT_SHA256S=(
  9176cc66fc7ce1edf85cf355b06e320c57db6297df74277f575183468893cf61
  0aea1e377ad95d267c7e78403c000285b56812e7f7c1b3c3d8b1fe27d9b8f9bc
  b9f34cfb4fd3b1344100eead79ef4d37aa15962274b9e3056de345021f76a1b0
  3f247b7e5a2409071202f5e2bc6200060f66728c0a3443c03923ad2723e040b3
  57fbc4b950ae81b1a0e1e298af15652da968a6723a592b7874e9b4027a80a5b4
  e9c326dc8c05cd1e044c71f30f1b2e34a6161a3b6ecf445d56b53ff1669e3dec
  1748a822060a35baa9f6609f84efc8eb54dc0e74b9ece3d82367b7119fdc75af
  4b92eb0c06d10683f7447ce9406cb97cd4b453be18d7279320f7b2f025c10187
  6794da8dd86d0b83b453e7968771cddfb3004e3db4cda5cea6d4111a616f49cb
)
INPUT_CACHE_KEYS=(
  KALDI_NATIVE_FBANK
  KISSFFT
  KALDI_DECODER
  KALDIFST
  OPENFST
  EIGEN
  SIMPLE-SENTENCEPIECE
  JSON
  ONNXRUNTIME
)
INPUT_SOURCE_DIRECTORIES=(
  kaldi_native_fbank-src
  kissfft-src
  kaldi_decoder-src
  kaldifst-src
  openfst-src
  eigen-src
  simple-sentencepiece-src
  json-src
  onnxruntime-src
)
mkdir -p "$BUILD_ROOT/_deps"
FETCHCONTENT_ARGUMENTS=(-DFETCHCONTENT_FULLY_DISCONNECTED=ON)
for index in "${!INPUT_NAMES[@]}"; do
  archive="$WORK_ROOT/${INPUT_FILENAMES[$index]}"
  source_directory="$BUILD_ROOT/_deps/${INPUT_SOURCE_DIRECTORIES[$index]}"
  fetch_reviewed_input \
    "${INPUT_NAMES[$index]}" \
    "${INPUT_URLS[$index]}" \
    "${INPUT_SHA256S[$index]}" \
    "$archive"
  extract_reviewed_input "${INPUT_NAMES[$index]}" "$archive" "$source_directory"
  FETCHCONTENT_ARGUMENTS+=(
    "-DFETCHCONTENT_SOURCE_DIR_${INPUT_CACHE_KEYS[$index]}=$source_directory"
  )
done

# The tag contains the final version but stale pre-release commit metadata.
# Apply the exact upstream new-release.sh result without depending on mutable
# Git metadata, then pin the changed file before compiling.
VERSION_FILE="$SOURCE_ROOT/sherpa-onnx/csrc/version.cc"
[[ "$(sha256_file "$VERSION_FILE")" == "$EXPECTED_TAGGED_VERSION_FILE_SHA256" ]] \
  || error "Tagged sherpa-onnx version metadata differs from reviewed input"
LC_ALL=C sed -i.bak \
  -e 's/Tue Jul 7 19:00:41 2026/Tue Jul 7 19:21:34 2026/' \
  -e 's/753609d0/14280725/' \
  "$VERSION_FILE"
rm "$VERSION_FILE.bak"
[[ "$(sha256_file "$SOURCE_ROOT/sherpa-onnx/csrc/version.cc")" == \
  "$EXPECTED_VERSION_FILE_SHA256" ]] \
  || error "Generated sherpa-onnx version metadata drifted"

# The reviewed KissFFT security fix enables upstream sign-comparison warnings.
# Keep this suppression target-local instead of weakening warning policy for the
# rest of sherpa-onnx, and pin both sides of the deterministic source transform.
KALDI_NATIVE_FBANK_CMAKE="$SOURCE_ROOT/cmake/kaldi-native-fbank.cmake"
[[ "$(sha256_file "$KALDI_NATIVE_FBANK_CMAKE")" == \
  "$EXPECTED_KALDI_NATIVE_FBANK_CMAKE_SHA256" ]] \
  || error "Tagged kaldi-native-fbank CMake integration differs from reviewed input"
LC_ALL=C sed -i.bak \
  's/target_compile_options(kissfft PRIVATE -Wno-cast-align)/target_compile_options(kissfft PRIVATE -Wno-cast-align -Wno-sign-compare)/' \
  "$KALDI_NATIVE_FBANK_CMAKE"
rm "$KALDI_NATIVE_FBANK_CMAKE.bak"
[[ "$(sha256_file "$KALDI_NATIVE_FBANK_CMAKE")" == \
  "$EXPECTED_PATCHED_KALDI_NATIVE_FBANK_CMAKE_SHA256" ]] \
  || error "Target-local KissFFT warning policy transform drifted"

echo "▸ Building the static universal C API without TTS or diarization..."
cmake -Wno-author -Wno-deprecated -S "$SOURCE_ROOT" -B "$BUILD_ROOT" -G Ninja \
  "${FETCHCONTENT_ARGUMENTS[@]}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$C_FLAGS" \
  -DCMAKE_CXX_FLAGS="$CXX_FLAGS" \
  -DCMAKE_OSX_ARCHITECTURES='arm64;x86_64' \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
  -DBUILD_SHARED_LIBS=OFF \
  -DSHERPA_ONNX_ENABLE_BINARY=OFF \
  -DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF \
  -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
  -DSHERPA_ONNX_ENABLE_TESTS=OFF \
  -DSHERPA_ONNX_ENABLE_CHECK=OFF \
  -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
  -DSHERPA_ONNX_ENABLE_JNI=OFF \
  -DSHERPA_ONNX_ENABLE_C_API=ON \
  -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF \
  -DSHERPA_ONNX_ENABLE_GPU=OFF \
  -DSHERPA_ONNX_ENABLE_WASM=OFF \
  -DSHERPA_ONNX_ENABLE_TTS=OFF \
  -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF \
  -DSHERPA_ONNX_USE_PRE_INSTALLED_ONNXRUNTIME_IF_AVAILABLE=OFF
cmake --build "$BUILD_ROOT" --target install --config Release --parallel 2

grep -Fxq "FETCHCONTENT_FULLY_DISCONNECTED:BOOL=ON" "$BUILD_ROOT/CMakeCache.txt" \
  || error "Transitive source fetching is not fully disconnected"
for index in "${!INPUT_NAMES[@]}"; do
  cache_key="FETCHCONTENT_SOURCE_DIR_${INPUT_CACHE_KEYS[$index]}"
  source_directory="$BUILD_ROOT/_deps/${INPUT_SOURCE_DIRECTORIES[$index]}"
  grep -Eq "^${cache_key}:[^=]+=${source_directory}$" "$BUILD_ROOT/CMakeCache.txt" \
    || error "CMake did not retain the reviewed ${INPUT_NAMES[$index]} source override"
done

grep -Fxq "CMAKE_C_FLAGS:STRING=$C_FLAGS" \
  "$BUILD_ROOT/CMakeCache.txt" \
  || error "Reproducible C compiler path mapping is missing"
grep -Fxq "CMAKE_CXX_FLAGS:STRING=$CXX_FLAGS" \
  "$BUILD_ROOT/CMakeCache.txt" \
  || error "Eigen MPL-only and reproducible C++ compiler gates are missing"
for setting in \
  SHERPA_ONNX_ENABLE_TTS \
  SHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION \
  SHERPA_ONNX_ENABLE_PORTAUDIO; do
  grep -Fxq "$setting:BOOL=OFF" "$BUILD_ROOT/CMakeCache.txt" \
    || error "$setting must remain disabled"
done

LIB_ROOT="$INSTALL_ROOT/lib"
MERGE_INPUTS=(
  "$LIB_ROOT/libsherpa-onnx-c-api.a"
  "$LIB_ROOT/libsherpa-onnx-core.a"
  "$LIB_ROOT/libkaldi-native-fbank-core.a"
  "$LIB_ROOT/libkissfft-float.a"
  "$LIB_ROOT/libsherpa-onnx-fstfar.a"
  "$LIB_ROOT/libsherpa-onnx-fst.a"
  "$LIB_ROOT/libsherpa-onnx-kaldifst-core.a"
  "$LIB_ROOT/libkaldi-decoder-core.a"
  "$LIB_ROOT/libssentencepiece_core.a"
)
mkdir -p "$STAGING_ROOT"
for archive in "${MERGE_INPUTS[@]}"; do
  [[ -f "$archive" ]] || error "Expected merge input is missing: $archive"
done
libtool -static -D -no_warning_for_no_symbols \
  -o "$MERGED_ARCHIVE" "${MERGE_INPUTS[@]}"

for architecture in arm64 x86_64; do
  lipo "$MERGED_ARCHIVE" -verify_arch "$architecture" >/dev/null 2>&1 \
    || error "Merged sherpa-onnx archive is missing its $architecture slice"
done
ACTUAL_ARCHIVE_SHA256="$(sha256_file "$MERGED_ARCHIVE")"
if [[ -n "$EXPECTED_ARCHIVE_SHA256" \
  && "$ACTUAL_ARCHIVE_SHA256" != "$EXPECTED_ARCHIVE_SHA256" ]]; then
  error \
    "Merged sherpa-onnx archive differs from the reviewed artifact: $ACTUAL_ARCHIVE_SHA256"
fi
ARCHIVE_STRINGS="$WORK_ROOT/sherpa-onnx.strings"
strings "$MERGED_ARCHIVE" >"$ARCHIVE_STRINGS"
if grep -Eq \
  '(/Users/|/private/var/folders/|/var/folders/|/private/tmp/rill-sherpa|/tmp/rill-sherpa)' \
  "$ARCHIVE_STRINGS"; then
  error "Merged sherpa-onnx archive exposes a temporary or user build path"
fi
grep -Fq "$REPRODUCIBLE_BUILD_ROOT/" "$ARCHIVE_STRINGS" \
  || error "Merged sherpa-onnx archive is missing reproducible source paths"

REQUIRED_SYMBOLS=(
  SherpaOnnxAcceptWaveformOffline
  SherpaOnnxCreateOfflineRecognizer
  SherpaOnnxCreateOfflineStream
  SherpaOnnxDecodeOfflineStream
  SherpaOnnxDestroyOfflineRecognizer
  SherpaOnnxDestroyOfflineRecognizerResult
  SherpaOnnxDestroyOfflineStream
  SherpaOnnxGetGitSha1
  SherpaOnnxGetOfflineStreamResult
  SherpaOnnxGetVersionStr
  SherpaOnnxOfflineStreamSetOption
)
for architecture in arm64 x86_64; do
  symbols="$(nm -a -arch "$architecture" "$MERGED_ARCHIVE")" \
    || error "Cannot inspect the $architecture sherpa-onnx archive"
  for symbol in "${REQUIRED_SYMBOLS[@]}"; do
    grep -Eq "[[:space:]]T[[:space:]]+_$symbol$" <<<"$symbols" \
      || error "Missing $symbol in the $architecture archive"
  done
  if grep -Eiq \
    '(_espeak_|piper|phonemiz|hclust|fastcluster|offline-tts-impl|offline-speaker-diarization-impl)' \
    <<<"$symbols"; then
    error "Forbidden TTS or diarization implementation in the $architecture archive"
  fi
done

HEADER_ROOT="$STAGING_ROOT/Headers"
mkdir -p "$HEADER_ROOT/sherpa-onnx/c-api"
cp "$INSTALL_ROOT/include/sherpa-onnx/c-api/c-api.h" \
  "$HEADER_ROOT/sherpa-onnx/c-api/c-api.h"
xcodebuild -create-xcframework \
  -library "$MERGED_ARCHIVE" \
  -headers "$HEADER_ROOT" \
  -output "$STAGING_ROOT/sherpa-onnx.xcframework" >/dev/null

[[ "$(sha256_file "$STAGING_ROOT/sherpa-onnx.xcframework/Info.plist")" == \
  "$EXPECTED_INFO_PLIST_SHA256" ]] \
  || error "Generated XCFramework metadata drifted"
[[ "$(sha256_file "$STAGING_ROOT/sherpa-onnx.xcframework/macos-arm64_x86_64/Headers/sherpa-onnx/c-api/c-api.h")" == \
  "$EXPECTED_HEADER_SHA256" ]] \
  || error "Generated sherpa-onnx C API header drifted"

mkdir -p "$OUTPUT_ROOT/licenses/eigen"
cp -R "$STAGING_ROOT/sherpa-onnx.xcframework" \
  "$OUTPUT_ROOT/sherpa-onnx.xcframework"
cp "$SOURCE_ROOT/LICENSE" "$OUTPUT_ROOT/LICENSE.sherpa-onnx"
cp "$BUILD_ROOT/_deps/kaldi_native_fbank-src/LICENSE" \
  "$OUTPUT_ROOT/licenses/LICENSE.kaldi-native-fbank"
cp "$BUILD_ROOT/_deps/kissfft-src/COPYING" \
  "$OUTPUT_ROOT/licenses/COPYING.kissfft"
cp "$BUILD_ROOT/_deps/kaldi_decoder-src/LICENSE" \
  "$OUTPUT_ROOT/licenses/LICENSE.kaldi-decoder"
cp "$BUILD_ROOT/_deps/kaldifst-src/LICENSE" \
  "$OUTPUT_ROOT/licenses/LICENSE.kaldifst"
cp "$BUILD_ROOT/_deps/openfst-src/COPYING" \
  "$OUTPUT_ROOT/licenses/COPYING.openfst"
cp "$BUILD_ROOT/_deps/simple-sentencepiece-src/LICENSE" \
  "$OUTPUT_ROOT/licenses/LICENSE.simple-sentencepiece"
cp "$BUILD_ROOT/_deps/json-src/LICENSE.MIT" \
  "$OUTPUT_ROOT/licenses/LICENSE.nlohmann-json"
for evidence in \
  COPYING.README COPYING.MPL2 COPYING.BSD COPYING.MINPACK COPYING.APACHE LICENSE; do
  cp "$BUILD_ROOT/_deps/eigen-src/$evidence" \
    "$OUTPUT_ROOT/licenses/eigen/$evidence"
done

echo "✓ Reviewed sherpa-onnx runtime written to: $OUTPUT_ROOT"
echo "  archive SHA-256: $ACTUAL_ARCHIVE_SHA256"
