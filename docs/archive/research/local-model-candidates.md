# Local Model Catalog Review

> 历史材料，保留原始研究、计划或验收范围；不代表当前功能或发布结论。
> 归档基线：main `9e786a6`。当前使用说明见 [用户指南](../../usage.md)。

Rill's local speech boundary now routes exact final-model identities to
sherpa-onnx or the optional Apple Silicon native MLX Swift backend. The 16 GB default
remains Qwen3-ASR 0.6B INT8; Qwen3-ASR 1.7B 8bit is selectable with a 16 GB
minimum and 24 GB recommendation. Live hypotheses still use one fixed
Chinese/English Streaming Zipformer INT8 model. Catalog admission proves a
reviewed source identity and bounded runtime path; it does not prove speech
quality, device coverage, license clearance, or general availability.

## Current public release set

| Model ID | Product role | Exact archive | Bytes | Archive SHA-256 | Installed inventory SHA-256 | Current evidence and status |
|---|---|---|---:|---|---|---|
| `qwen3-asr-0.6b-int8` | Default public final model; Simplified Chinese plus some English; recommended for 16 GB | [Qwen3-ASR 0.6B INT8](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2) | `878702423` | `393f8a14e2f5fb96746aaab342997a40641001fbd5bf9592a080a8329178ee96` | `24fd5947756b66b37fb4cb7193450c6212c84eba976027fe42de788447af787d` | Trusted artifact. On 2026-07-18 an arm64 Mac decoded the archive's official `cantonese.wav` and `codeswitch.wav` fixtures through the production runtime. These are technical fixtures, not accepted Chinese/English quality evidence. |
| `qwen3-asr-0.6b-mlx-8bit` | Optional lower-memory final model; Apple Silicon; 16 GB recommended | [MLX community model](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit/tree/89e96d92ba34aca20b3e29fb10cc284097d1219f) | `1010771234` | Git commit `89e96d92ba34aca20b3e29fb10cc284097d1219f` | Exact file byte counts and SHA-256 digests | Native `mlx-audio-swift` 0.1.3 route with exact-revision publication; human microphone quality is not yet benchmarked. |
| `qwen3-asr-1.7b-mlx-8bit` | Optional larger final model; Apple Silicon; 24 GB recommended | [MLX community model](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit/tree/a8379a2e2f9e313c9292cdf1af4055ab56d50d55) | about `2460000000` | Git commit `a8379a2e2f9e313c9292cdf1af4055ab56d50d55` | Hugging Face revision/LFS identity | Native `mlx-audio-swift` 0.1.3 is fixed by `Package.resolved`; direct local-directory loading, automatic language selection, bounded keyterm context, host routing, and worker tests pass locally. Model inference and Chinese/English quality are not yet benchmarked. |
| `streaming-zipformer-small-bilingual-zh-en-preview-int8` | Fixed live-preview model; stable legacy storage ID; not selectable as a final tier | [Streaming Zipformer bilingual INT8](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20.tar.bz2) | `511274346` | `27ffbd9ee24ad186d99acc2f6354d7992b27bcab490812510665fa8f9389c5f8` | `9adc9ead5f64877832a928980b189b12ba36fe192a137ec8c1ae39540b640c62` | Upgraded from the earlier small model; native incremental fixture validation is required before release. |

The complete provenance, attribution, and license-risk record is maintained in
[`LOCAL_MODEL_NOTICES.md`](../../../LOCAL_MODEL_NOTICES.md). Qwen does not yet have
accepted human microphone quality thresholds or complete coverage across the
supported Apple Silicon hardware matrix. Do not describe it as generally
available on the basis of catalog admission.

## Candidate final tiers — not implemented in the public product

| Candidate | Possible role | Why it remains a candidate |
|---|---|---|
| Omnilingual ASR CTC v2 300M INT8 | Future compact/8 GB tier | No accepted Chinese + English mixed-speech comparison against Qwen; public settings, installer, and recognizer reject it. |
| Omnilingual ASR CTC v2 1B INT8 | Future broad-language/large-memory tier | Broad coverage is useful, but there is no same-corpus evidence that it improves the target Chinese-heavy workload; public settings, installer, and recognizer reject it. |
| MiMo-V2.5-ASR | Future large intelligent tier | The official CUDA-oriented release has no reviewed native macOS package; see the detailed admission gate below. |

Candidate descriptors may remain as inert evaluation metadata so hashes and
benchmarks are reproducible. They are not admitted to the public distributable
set and cannot be downloaded or executed through production APIs.

## Apple acceleration paths

sherpa-onnx exposes ONNX Runtime's `coreml` execution provider. Core ML can
schedule supported subgraphs on Apple CPU, GPU, and Neural Engine; this is not a
separate "Metal model" format and unsupported operators fall back to CPU. The
current Rill C adapter deliberately requests `cpu` for every sherpa
recognizer. The optional Qwen3-ASR 1.7B backend instead uses MLX on the Metal
GPU; it does not use the Apple Neural Engine. Before changing the sherpa
boundary, Qwen3-ASR 0.6B must pass model creation,
transcript-equivalence, cold/warm latency, peak-memory, energy, fallback-node,
and cancellation tests on the minimum supported Apple Silicon systems.

On 2026-07-19, the installed development App also completed one consented
real-microphone run through the production Qwen path. Content-free evidence
recorded a 179.8 ms hint-resolution-to-capture-start interval, 6.56 seconds of
observed audio, 4.0 seconds classified as speech, one `speechEnded` terminal
signal, and one non-empty completed result. This proves that the current
installed capture, endpoint, and batch-recognition path can work end to end; it
does not establish Simplified-Chinese/English accuracy thresholds, controlled
noise performance, or a support matrix, and no transcript body is included in
this evidence.

## Retired and internal identities

The source tree and runtime retain exact identities for Fun-ASR Nano INT8/FP16,
the retired Cohere Transcribe 2B INT8 model, and `sense-voice-small-int8` only
for migration, internal compatibility, or possible future evaluation. None is
in the public release set or accepted by the public installer. SenseVoice also
requires product and legal review because its archive points to changing FunASR
terms.

## Planned large-model candidate: MiMo-V2.5-ASR

MiMo-V2.5-ASR is a strong Chinese/English, dialect, code-switching, noise, and
multi-speaker candidate, but it is not currently a valid Rill macOS model
entry. The official release is an 8B F32 model of roughly 32.1 GB plus a separate
audio tokenizer; the published reference path requires Linux, CUDA 12, and
FlashAttention. There is no reviewed sherpa-onnx/ONNX Runtime or Core ML package
that Rill can pin and run on macOS today.

TODO: reconsider MiMo when a reproducible macOS package exists with an immutable
source URL, hashes and file inventory, a compatible native runtime, documented
memory/latency on Apple Silicon, and accepted Chinese + English mixed-speech
quality results. Community quantizations alone do not pass the public model gate.

## Trust and installation boundary

The unified routing catalog lives in
`Sources/RillSpeechContracts/LocalSpeechModelCatalog.swift`; sherpa trust anchors
remain in `SherpaOnnxModelCatalog.swift`. A sherpa production install:

1. accepts only exact model IDs in the public distributable set and rejects
   internal preview identities;
2. starts at the catalog's HTTPS URL under the k2-fsa sherpa-onnx release path;
3. uses an ephemeral session with no cookies, credential storage, or cache, and
   permits redirects only to the reviewed GitHub release-asset hosts;
4. checks the exact archive byte count and SHA-256 before extraction;
5. rejects traversal, absolute paths, multiple roots, duplicate entries, links,
   special files, and an excessive entry count;
6. verifies required entries and the canonical inventory of every installed
   regular file, writes a receipt, normalizes private permissions, and publishes
   the directory atomically; and
7. re-hashes the complete installed inventory before reusing a cached model.

The temporary archive is removed after installation. The prepared model is one
verified extracted tree under
`~/Library/Application Support/Rill/Models/sherpa-onnx`; recognition from
that tree is offline. Selecting or preparing the public Qwen model is the
explicit network boundary.

The MLX path has no Python or `uv` host prerequisite. Rill's supervised
Swift helper links `mlx-audio-swift` 0.1.3 at commit
`d302a5c6080d2bb97bae38c7418f82abb76013b6` and asks Hugging Face for only
`mlx-community/Qwen3-ASR-1.7B-8bit` at commit
`a8379a2e2f9e313c9292cdf1af4055ab56d50d55`. A receipt binds repository, model
ID, and revision; required files must be regular, non-symlink, and non-empty
before atomic publication. Version 0.1.3 loads the verified publication
directory directly, so runtime preparation does not re-resolve a repository
name or authorize a request for repository `main`. Automatic language mode is
left unset for the model to detect, while explicit language aliases and
sanitized, bounded keyterms are passed through the Qwen context API. The
approximate size is not treated as an archive byte-count trust anchor. The model
cache stays under Rill's private Application Support directory.

## Promotion gates

Artifact admission and product acceptance are separate decisions.

### Trusted artifact

A model may remain in the public release catalog only while all of these stay true:

1. The source identity is release-owned: sherpa models require an exact URL,
   byte count, SHA-256, root and installed inventory; MLX models require an
   exact repository commit plus the reviewed `Package.resolved` runtime graph.
2. Source and redirect hosts are narrowly allowlisted and normal TLS validation
   remains mandatory.
3. Malformed, substituted, incomplete, or locally modified content fails closed.
4. Provenance, attribution, and model-specific license evidence are recorded in
   `LOCAL_MODEL_NOTICES.md`.

### Product acceptance / general availability

Before a model can enter or advance within the public release catalog, record
and approve:

1. human-consented real-microphone results for Simplified Chinese, English, and
   mixed speech, including the corpus in
   [`asr-benchmark-plan.md`](asr-benchmark-plan.md);
2. final latency, editing cost, proprietary-term, long-pause, self-correction,
   automatic-stop, and realistic noise results against thresholds fixed before
   the run;
3. clean-account preparation, verified offline restart, cancellation, repair,
   shutdown, storage lifecycle, and no-cloud-fallback behavior;
4. candidate-App QA on every declared architecture and minimum macOS version;
   and
5. completed license, NOTICE, attribution, and distribution review. The internal
   SenseVoice identity cannot bypass this gate because its archive is smaller.

## Retired WhisperKit candidates

The prior Breeze, Cantonese, Whisper tiny, and Whisper large-v3 candidate path
is retired and is no longer part of the production catalog, downloader, or
release decision. Historical measurements remain in
[`asr-dogfood-results.md`](https://github.com/zrr1999/rill/blob/760640e25b8ceaf45075e8092c4628ab12ad3afd/docs/asr-dogfood-results.md) as migration evidence only;
they cannot validate sherpa-onnx models or the current recording and endpointing
path.
