# Vendored sherpa-onnx runtime

This directory contains the reviewed static universal macOS runtime used by
the `RillSherpaRuntime` Swift package target.

- `sherpa-onnx.xcframework` is built from sherpa-onnx `v1.13.4`, immutable
  commit `142807252687d81b40d6315f23470a1512a00de3`, with TTS, speaker
  diarization, PortAudio, and non-library front ends disabled. Eigen is compiled
  with `EIGEN_MPL2_ONLY`, and the final archive is assembled from an exact
  nine-library ASR allowlist. It is not the upstream full XCFramework.
- `onnxruntime.xcframework` is assembled with
  `xcodebuild -create-xcframework` from the universal static ONNX Runtime
  1.27.0 archive pinned by sherpa-onnx.
- Both libraries contain `arm64` and `x86_64` slices. They are linked
  statically; no runtime framework embedding or nested code signing is needed.
- `licenses/`, `LICENSE.sherpa-onnx`, `LICENSE.onnxruntime`, and
  `ThirdPartyNotices.onnxruntime.txt` are the byte-pinned evidence used to
  generate the notices packaged in the App.

See [`BUILD_PROVENANCE.md`](BUILD_PROVENANCE.md) for the exact source graph,
toolchain, configuration, merge allowlist, output hashes, source-code-form
links, and validation results. Rebuild the reviewed runtime into a new output
directory with:

```sh
./scripts/build_sherpa_onnx_runtime.sh /tmp/rill-sherpa-runtime
```

The build gate downloads and verifies every reviewed input before entering a
fully disconnected CMake configuration. `SOURCE_INPUTS.sha256` records those
download bytes; `SHA256SUMS` is directly checkable from this directory for the
vendored artifacts and license evidence. The release gate also rejects linked
executables containing Piper or eSpeak implementation code. ONNX Runtime is a
byte-pinned prebuilt trust boundary, as documented in `BUILD_PROVENANCE.md`.
