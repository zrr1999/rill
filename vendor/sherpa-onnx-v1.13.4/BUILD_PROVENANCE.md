# sherpa-onnx macOS runtime build provenance

The vendored runtime is built from sherpa-onnx `v1.13.4`, immutable commit
`142807252687d81b40d6315f23470a1512a00de3`. It is a universal static C API
runtime for `arm64` and `x86_64`. It is not the upstream full XCFramework:
TTS, speaker diarization, PortAudio, executables, tests, Python, JNI, and
WebSocket support are disabled, and the C++ wrapper archive is not merged.

Run the reviewed build with an output directory that does not yet exist:

```sh
./scripts/build_sherpa_onnx_runtime.sh /tmp/rill-sherpa-runtime
```

The script downloads and verifies all ten immutable inputs before configuration,
rejects unsafe archive paths, and gives CMake only those reviewed source trees
with `FETCHCONTENT_FULLY_DISCONNECTED=ON`. It also pins the two intentional
source transforms, effective CMake cache, reproducible source-path mapping,
exact merge allowlist, both Mach-O architectures, required ASR C symbols,
forbidden TTS/diarization implementation symbols, and final reviewed byte
hashes before publishing its output. The merge uses `libtool -D` so archive
member timestamps are zeroed.

## Build boundary

The reviewed artifact was produced on macOS 26.4.1 (25E253) with Xcode 26.6
(17F113), Apple clang 21.0.0 (`clang-2100.1.1.101`), CMake 4.4.0, and Ninja
1.13.2. Its material configuration is:

```text
BUILD_SHARED_LIBS=OFF
CMAKE_BUILD_TYPE=Release
CMAKE_C_FLAGS=-ffile-prefix-map=<temporary-build-root>=/usr/src/voxtype/sherpa-runtime
CMAKE_CXX_FLAGS=-DEIGEN_MPL2_ONLY -ffile-prefix-map=<temporary-build-root>=/usr/src/voxtype/sherpa-runtime
CMAKE_OSX_ARCHITECTURES=arm64;x86_64
FETCHCONTENT_FULLY_DISCONNECTED=ON
SHERPA_ONNX_ENABLE_C_API=ON
SHERPA_ONNX_ENABLE_TTS=OFF
SHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF
SHERPA_ONNX_ENABLE_PORTAUDIO=OFF
SHERPA_ONNX_ENABLE_BINARY=OFF
SHERPA_ONNX_ENABLE_PYTHON=OFF
SHERPA_ONNX_ENABLE_TESTS=OFF
SHERPA_ONNX_ENABLE_JNI=OFF
SHERPA_ONNX_ENABLE_WEBSOCKET=OFF
```

The `/usr/src/voxtype` prefix is the historical, non-user-specific namespace
embedded in the reviewed archive before the application was renamed to Rill.
It remains fixed so the reproducible build contract continues to match the
audited binary hashes.

Only these nine archives are merged, in this order:

```text
libsherpa-onnx-c-api.a
libsherpa-onnx-core.a
libkaldi-native-fbank-core.a
libkissfft-float.a
libsherpa-onnx-fstfar.a
libsherpa-onnx-fst.a
libsherpa-onnx-kaldifst-core.a
libkaldi-decoder-core.a
libssentencepiece_core.a
```

`libsherpa-onnx-cxx-api.a` is deliberately excluded. ONNX Runtime remains a
separate binary target and is not merged into `libsherpa-onnx.a`.

## Source inputs

| Component | Version or revision | Immutable source | Source archive SHA-256 | License |
|---|---|---|---|---|
| sherpa-onnx | `142807252687d81b40d6315f23470a1512a00de3` (`v1.13.4`) | <https://github.com/k2-fsa/sherpa-onnx/archive/142807252687d81b40d6315f23470a1512a00de3.tar.gz> | `f0dc7c9b41b8691313daee671e826eb23946fa1320559a8d37e84f8774af76b2` | Apache-2.0 |
| kaldi-native-fbank | `v1.22.3` | <https://github.com/csukuangfj/kaldi-native-fbank/archive/refs/tags/v1.22.3.tar.gz> | `9176cc66fc7ce1edf85cf355b06e320c57db6297df74277f575183468893cf61` | Apache-2.0 |
| KissFFT | `8a8e66e33d692bad1376fe7904d87d767730537f` | <https://github.com/mborgerding/kissfft/archive/8a8e66e33d692bad1376fe7904d87d767730537f.zip> | `0aea1e377ad95d267c7e78403c000285b56812e7f7c1b3c3d8b1fe27d9b8f9bc` | BSD-3-Clause |
| kaldi-decoder | `v0.3.0` | <https://github.com/k2-fsa/kaldi-decoder/archive/refs/tags/v0.3.0.tar.gz> | `b9f34cfb4fd3b1344100eead79ef4d37aa15962274b9e3056de345021f76a1b0` | Apache-2.0 |
| kaldifst | `v1.8.0` | <https://github.com/k2-fsa/kaldifst/archive/refs/tags/v1.8.0.tar.gz> | `3f247b7e5a2409071202f5e2bc6200060f66728c0a3443c03923ad2723e040b3` | Apache-2.0 |
| OpenFST fork | `v1.8.5-2026-04-11` | <https://github.com/csukuangfj/openfst/archive/refs/tags/v1.8.5-2026-04-11.tar.gz> | `57fbc4b950ae81b1a0e1e298af15652da968a6723a592b7874e9b4027a80a5b4` | Apache-2.0 |
| Eigen | `5.0.1` | <https://gitlab.com/libeigen/eigen/-/archive/5.0.1/eigen-5.0.1.tar.gz> | `e9c326dc8c05cd1e044c71f30f1b2e34a6161a3b6ecf445d56b53ff1669e3dec` | MPL-2.0, BSD-3-Clause, Apache-2.0, and Minpack notices; compiled with `EIGEN_MPL2_ONLY` |
| simple-sentencepiece | `v0.7` | <https://github.com/pkufool/simple-sentencepiece/archive/refs/tags/v0.7.tar.gz> | `1748a822060a35baa9f6609f84efc8eb54dc0e74b9ece3d82367b7119fdc75af` | Apache-2.0 |
| nlohmann/json | `v3.12.0` | <https://github.com/nlohmann/json/archive/refs/tags/v3.12.0.tar.gz> | `4b92eb0c06d10683f7447ce9406cb97cd4b453be18d7279320f7b2f025c10187` | MIT |
| ONNX Runtime static prebuild | `1.27.0` | <https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.27.0/onnxruntime-osx-universal2-static_lib-1.27.0.zip> | `6794da8dd86d0b83b453e7968771cddfb3004e3db4cda5cea6d4111a616f49cb` | MIT plus upstream third-party notices |

The source links above are also emitted in `THIRD_PARTY_NOTICES.md`. In
particular, the immutable Eigen archive is the corresponding Source Code Form
offer for the MPL-covered files in this binary. The complete reviewed license
texts are stored under this directory and are packaged into the App notices.
`SOURCE_INPUTS.sha256` records the exact fetched filenames and bytes. ONNX
Runtime is the one explicit prebuilt trust boundary: Rill verifies and
vendors the reviewed universal static archive and notices, but does not claim to
reproduce ONNX Runtime itself from source.

The tagged sherpa source receives two pinned deterministic transforms before
compilation: upstream's final `new-release.sh` metadata result, and a
KissFFT-target-only `-Wno-sign-compare` option required by the reviewed security
fix. The build rejects either the original or transformed file if its hash
drifts; warning policy for the rest of the runtime is unchanged.

## Reviewed outputs

| Artifact | SHA-256 |
|---|---|
| `sherpa-onnx.xcframework/macos-arm64_x86_64/libsherpa-onnx.a` | `8950e345310f223d3be649c80de8059957a2a01f8553cca24c99071a6a292db6` |
| arm64 archive slice | `891f068daffd50ff15d881467233ba8405a8934cfc88cac9ee997c00458b3e2f` |
| x86_64 archive slice | `8ad832f5fc9bab40cc7ae9738536d9bf3ba152ce2daa2e913720ecbe8f1d2fde` |
| `sherpa-onnx.xcframework/Info.plist` | `789acaf7864ac8784bfe62902545b2b9cc7751957d50b49c23ebf106a8e67a4d` |
| `c-api.h` | `587e1039cc4ee242169494f3c0ba5baecc22482341168d88d57db965e1e77fa9` |
| `onnxruntime.xcframework/macos-arm64_x86_64/libonnxruntime.a` | `4e39796b2b31829622407137352178e0eaef240a1e40fb322a05db4483bd37b9` |

Both slices link against the separate ONNX Runtime archive and define all eleven
C symbols used by Rill. On 2026-07-18 the reviewed Qwen3-ASR 0.6B INT8
`cantonese.wav` fixture ran through the production `SherpaOfflineRecognizer` on
the arm64 build in 6.761 seconds, preserving Chinese text and `My Princess`.
Archive member, symbol, and linked-executable scans found no eSpeak, Piper,
phonemizer, hclust, fastcluster, TTS implementation, or speaker-diarization
implementation code.
