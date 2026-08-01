# Local Speech Model Notices

Rill bundles the fixed Silero VAD v4 endpointing model described below. It
does not bundle automatic speech recognition model weights. A user must
explicitly prepare a selected final ASR model and the fixed streaming-preview
model while online before first use. The wake-word model is also downloaded
only after the user enables and prepares that optional feature. sherpa-onnx
model downloads use reviewed fixed archives, exact byte counts, SHA-256
digests, and expected inventories. The optional native MLX Swift model instead
uses a reviewed Hugging Face repository at an exact commit and a reviewed
SwiftPM dependency lock. Recognition from prepared models is offline;
preparing a missing model is the network boundary.

`Trusted` below means that Rill binds a bundled resource or download to exact
reviewed bytes. It does not mean that human-consented quality thresholds, every
supported Mac, the complete upstream training and export chain, or public
general-availability review has passed. Model weights remain third-party
material and are not covered by any license that may later be chosen for
Rill source code.

## Silero VAD v4 (bundled endpoint detector)

- Role: 16 kHz speech-versus-non-speech detection for recording endpointing
- Bundled resource: `RillSherpaRuntime/Resources/silero_vad.onnx`
- Release asset URL:
  `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx`
- Exact resource size: `643854` bytes
- Resource SHA-256:
  `9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6`
- Export provenance: the reviewed ONNX metadata identifies Silero VAD v4,
  exported to ONNX by k2-fsa with only the 16 kHz branch retained
- Upstream project: [`snakers4/silero-vad`](https://github.com/snakers4/silero-vad)
- Upstream v4.0 commit:
  `915dd3d639b8333a52e001af095f87c5b7f1e0ac`
- License evidence:
  [`LICENSE` at the pinned v4.0 commit](https://github.com/snakers4/silero-vad/blob/915dd3d639b8333a52e001af095f87c5b7f1e0ac/LICENSE)
- Publisher-declared license: MIT License, copyright 2020-present Silero Team
- Upstream v4.0 `LICENSE` SHA-256 (the original 1075 bytes, without a terminal
  line feed):
  `2e63e9a38b6e8fc0c7bc37ce174caca1862870856c6daf5697cfb785e925520b`

The bundled `LICENSE.silero-vad` resource preserves the upstream license text
and adds one terminal line feed; its reviewed SHA-256 is
`51c19c8be941a3fb00ccf58f0bf9053de9f7237a0b37327896eabad32dffe873`.
The complete reviewed text is also generated into `THIRD_PARTY_NOTICES.md`.

Silero VAD is a voice-activity detector. It helps decide when speech begins and
ends; it does not suppress noise, clean the recorded signal, or by itself
improve transcription quality. The fixed hash prevents an unnoticed resource
replacement after review, but it is not a signature or an independent audit of
the upstream training and export chain.

## Bilingual Zipformer 3M KWS INT8 (fixed wake-word preview)

- Rill model ID: `kws-zipformer-zh-en-3m-preview-int8`
- Role: optional on-device Chinese/English keyword spotting before Rill starts
  command capture; it is not an ASR or speaker-verification model
- Release asset URL:
  `https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20.tar.bz2`
- Exact archive size: `32885699` bytes
- Archive SHA-256:
  `68447f4fbc67e70eee3a93961f36e81e98f47aef73ce7e7ca00885c6cd3616a6`
- Expected root directory:
  `sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20`
- Retained chunk-8 layout: `left-64` INT8 encoder, FP32 decoder, INT8 joiner,
  `tokens.txt`, and `en.phone`
- Publisher model repository:
  [`pkufool/icefall-kws-zipformer-zh-en-3M-2025-12-20`](https://modelscope.cn/models/pkufool/icefall-kws-zipformer-zh-en-3M-2025-12-20)
- Exact reviewed revision: `541d04e28be57efc6fdf46a341da09e043a37b52`
- License evidence:
  [`README.md` at the pinned revision](https://modelscope.cn/models/pkufool/icefall-kws-zipformer-zh-en-3M-2025-12-20/resolve/541d04e28be57efc6fdf46a341da09e043a37b52/README.md)
- License-evidence SHA-256:
  `34d92bb4dc9fb259efb67f329d2cd68f6e0a6226121a694a3b6b4c748378559c`
- Publisher-declared license: Apache License 2.0
- Upstream NOTICE disposition: no `NOTICE` file was provided in the release
  archive or the pinned publisher repository

The GitHub release asset and the ModelScope model are both published by
`pkufool`; the three retained `left-64` ONNX files have identical SHA-256
digests in both sources. The release archive does not carry a `LICENSE` file,
so Rill binds distribution approval to the publisher's exact-revision model
card instead of inferring a license from the archive host. The full Apache
License 2.0 text is included in the App's `THIRD_PARTY_NOTICES.md` resource.
The pinned evidence clears the software distribution license/NOTICE gate; it
does not replace wake-rate, false-activation, microphone, architecture, or
minimum-macOS acceptance testing, so this model remains a product preview.

## Streaming Zipformer bilingual INT8 (fixed live preview)

- Rill model ID:
  `streaming-zipformer-small-bilingual-zh-en-preview-int8`
- Storage compatibility: the internal ID retains its original `small` spelling
  so this reviewed upgrade replaces the earlier preview cache in place
- Role: fixed low-latency Chinese/English live subtitle hypotheses; never used
  as the selected final-transcription tier
- Archive URL:
  `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20.tar.bz2`
- Exact archive size: `511274346` bytes
- Archive SHA-256:
  `27ffbd9ee24ad186d99acc2f6354d7992b27bcab490812510665fa8f9389c5f8`
- Expected root directory:
  `sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20`
- Canonical installed-file inventory SHA-256:
  `9adc9ead5f64877832a928980b189b12ba36fe192a137ec8c1ae39540b640c62`
- Upstream model card:
  [`csukuangfj/k2fsa-zipformer-chinese-english-mixed`](https://huggingface.co/csukuangfj/k2fsa-zipformer-chinese-english-mixed)
- Publisher-declared license: Apache License 2.0

The release archive contains INT8 and FP32 files but does not contain a license
file. Rill uses only the root INT8 encoder,
decoder, joiner, and token table at runtime while preserving and hashing the
complete extracted archive. Attribution therefore follows the upstream model
card and k2-fsa release provenance; the App's third-party notices already carry
the full Apache License 2.0 text. If preview preparation or incremental decode
fails, Rill falls back to level/status display and still runs the selected
offline final model.

## Qwen3-ASR 0.6B INT8 (default)

- Rill model ID: `qwen3-asr-0.6b-int8`
- Role: default local model for Simplified Chinese and English mixed speech
- Archive URL:
  `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2`
- Exact archive size: `878702423` bytes
- Archive SHA-256:
  `393f8a14e2f5fb96746aaab342997a40641001fbd5bf9592a080a8329178ee96`
- Expected root directory:
  `sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25`
- Publisher-declared license: Apache License 2.0

The archive's own README says that its ONNX files were downloaded from
[`zengshuishui/Qwen3-ASR-onnx`](https://modelscope.cn/models/zengshuishui/Qwen3-ASR-onnx/files),
whose export implementation is
[`Wasser1462/Qwen3-ASR-onnx`](https://github.com/Wasser1462/Qwen3-ASR-onnx),
and points to the upstream
[`QwenLM/Qwen3-ASR`](https://github.com/QwenLM/Qwen3-ASR) project. The
ModelScope export and upstream
[`Qwen/Qwen3-ASR-0.6B`](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) model both
declare Apache-2.0. The k2-fsa archive does not contain a license file, so the
release attribution must preserve this provenance instead of inferring a
license from the archive host alone. The full Apache License 2.0 text is
included in the App's `THIRD_PARTY_NOTICES.md` resource.

On 2026-07-18, the production `SherpaOfflineRecognizer` decoded the official
archive's 16 kHz mono `test_wavs/cantonese.wav` fixture on the current arm64 Mac
in 6.761 seconds and preserved both Cantonese Chinese text and `My Princess`.
This is an offline technical fixture result, not a Simplified-Chinese fixture,
a human-microphone dogfood result, a quality threshold, or GA evidence. The
same production provider decoded the archive's `codeswitch.wav` fixture in
2.830 seconds and preserved `alone, all by myself`; the archive transcript
identifies that sample as English, French, Italian, and Spanish rather than
Chinese/English. It is multilingual runtime evidence only. Simplified Chinese
plus English remains a product target that requires real-microphone acceptance.

Credit: the Qwen team for Qwen3-ASR; `zengshuishui` and `Wasser1462` for the
ONNX export; and k2-fsa for the sherpa-onnx release archive and runtime
integration.

## Qwen3-ASR 0.6B 8bit for mlx-audio-swift (optional Apple Silicon final model)

- Rill model ID: `qwen3-asr-0.6b-mlx-8bit`
- Role: lower-memory optional Qwen final-transcription model; Rill marks 8 GB
  as the minimum and 16 GB as the recommended memory tier for this option
- Model repository:
  [`mlx-community/Qwen3-ASR-0.6B-8bit`](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit)
- Exact reviewed revision: `89e96d92ba34aca20b3e29fb10cc284097d1219f`
- Exact reviewed file total: `1010771234` bytes
- Model publisher-declared license: Apache License 2.0
- Runtime: the same pinned `mlx-audio-swift` 0.1.3 worker boundary described
  below for the 1.7B option
- Compute boundary: Apple Silicon Metal GPU through MLX; this integration does
  not target the Apple Neural Engine

The helper downloads only the nine reviewed model files at the exact revision,
validates their byte counts and SHA-256 digests, and publishes an exact receipt.
This is artifact and runtime evidence, not a human-microphone quality claim.

## Qwen3-ASR 1.7B 8bit for mlx-audio-swift (optional Apple Silicon final model)

- Rill model ID: `qwen3-asr-1.7b-mlx-8bit`
- Role: larger optional Chinese/English final-transcription model; the 0.6B
  sherpa-onnx variant remains the 16 GB default; Rill marks 16 GB as the
  minimum and 24 GB as the recommended memory tier for this option
- Model repository:
  [`mlx-community/Qwen3-ASR-1.7B-8bit`](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit)
- Exact reviewed revision: `a8379a2e2f9e313c9292cdf1af4055ab56d50d55`
- Approximate repository size at that revision: 2.46 GB
- Model publisher-declared license: Apache License 2.0
- Runtime:
  [`mlx-audio-swift` 0.1.3](https://github.com/Blaizzy/mlx-audio-swift/tree/v0.1.3),
  exact commit `d302a5c6080d2bb97bae38c7418f82abb76013b6`, fixed by
  `Package.resolved`; mlx-audio-swift declares the MIT License
- Compute boundary: Apple Silicon Metal GPU through MLX; this integration does
  not target the Apple Neural Engine

Rill links this optional native runtime only into its supervised, persistent
Swift JSONL helper; the main App process does not link MLX. Third-party stdout
is redirected away from the protocol channel. The helper downloads only the
reviewed model repository at the exact revision above, validates an
exact-revision receipt and required regular files, and atomically publishes the
snapshot into Rill's private model cache. Switching final-model backends
retires the helper so the 0.6B and 1.7B models do not silently accumulate in
memory. Users do not need Python or `uv`.

This entry records source, runtime, and license provenance. The approximate
download size is not an exact archive byte-count trust anchor, and no local
Chinese/English quality or latency benchmark is claimed here.

## Fun-ASR Nano 0.8B (INT8 and FP16)

- Rill model IDs: `funasr-nano-0.8b-int8`, `funasr-nano-0.8b-fp16`
- Role: Chinese-first intelligent transcription variants with dialect, English,
  and Japanese coverage
- INT8 archive URL:
  `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-funasr-nano-int8-2025-12-30.tar.bz2`
- INT8 exact size / SHA-256: `841730611` bytes /
  `eb43d7ccc2e86b243f6a03b7df361033dda66db9523d1a92bf6aca2b50c9476b`
- FP16 archive URL:
  `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-funasr-nano-fp16-2025-12-30.tar.bz2`
- FP16 exact size / SHA-256: `1030076153` bytes /
  `a07a996361aa2f8b2c4f47861fe01953b5509664efa3392b734580b1eeb362e3`
- Expected roots: `sherpa-onnx-funasr-nano-int8-2025-12-30` and
  `sherpa-onnx-funasr-nano-fp16-2025-12-30`
- Upstream model: [`FunAudioLLM/Fun-ASR-Nano-2512`](https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-2512)
- Publisher-declared license: Apache License 2.0

The release archives identify the converted source as
`zengshuishui/FunASR-nano-onnx` and the exporter as
[`Wasser1462/FunASR-nano-onnx`](https://github.com/Wasser1462/FunASR-nano-onnx).
The archives do not include a license file, so Rill preserves both the model
and export provenance and includes the Apache License 2.0 text in
`THIRD_PARTY_NOTICES.md`.

## Omnilingual ASR CTC v2 (300M and 1B INT8)

- Rill model IDs: `omnilingual-asr-ctc-v2-300m-int8`,
  `omnilingual-asr-ctc-v2-1b-int8`
- Role: compact and larger multilingual CTC variants from the 1,600+ language
  Omnilingual ASR family
- 300M archive URL:
  `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-omnilingual-asr-1600-languages-300M-ctc-v2-int8-2026-02-05.tar.bz2`
- 300M exact size / SHA-256: `292313120` bytes /
  `951b32409aade32bd525310bb39e9666773ba3fc611a39e817f620936d76c631`
- 1B archive URL:
  `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-omnilingual-asr-1600-languages-1B-ctc-v2-int8-2026-02-05.tar.bz2`
- 1B exact size / SHA-256: `787296506` bytes /
  `f4deae6e6cbf4ca785b89eaa3836156581208bf977ea2e6d7ae84d7efcfc3a40`
- Expected roots:
  `sherpa-onnx-omnilingual-asr-1600-languages-300M-ctc-v2-int8-2026-02-05`
  and
  `sherpa-onnx-omnilingual-asr-1600-languages-1B-ctc-v2-int8-2026-02-05`
- Upstream model family:
  [`facebook/omnilingual-asr`](https://github.com/facebookresearch/omnilingual-asr)
- Publisher-declared and archive-carried license: Apache License 2.0,
  copyright Meta Platforms, Inc. and affiliates

Each archive carries the Apache License 2.0 text. The 300M and 1B entries are
separate immutable model identities; selecting a capacity never substitutes
the other archive.

## Cohere Transcribe 2B INT8 (retired compatibility identity; not distributed)

- Rill model ID: `cohere-transcribe-2b-int8`
- Role: retired model identity retained only to recognize and migrate older
  installations; not exposed, selectable, recommended, or accepted by the
  public installer
- Archive URL:
  `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-cohere-transcribe-14-lang-int8-2026-04-01.tar.bz2`
- Exact archive size: `1699791751` bytes
- Archive SHA-256:
  `bd582588d50685a795dcd2807ab77e11361b8312d96c53884682def45ab4206d`
- Expected root directory:
  `sherpa-onnx-cohere-transcribe-14-lang-int8-2026-04-01`
- Upstream model:
  [`CohereLabs/cohere-transcribe-03-2026`](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026)
- Publisher-declared license: Apache License 2.0

The k2-fsa archive README records conversion from the upstream CohereLabs model
but does not include a license file. Rill therefore preserves the upstream
model attribution and includes the Apache License 2.0 text in
`THIRD_PARTY_NOTICES.md`. Product review removed this identity from the public
catalog; retaining its pinned descriptor does not authorize a new download.

## SenseVoiceSmall INT8 (internal preview identity; not distributed)

- Rill model ID: `sense-voice-small-int8`
- Role: pinned source identity for internal compatibility and future evaluation;
  not exposed, selectable, recommended, or downloadable in the public build
- Archive URL:
  `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2`
- Exact archive size: `163002883` bytes
- Archive SHA-256:
  `7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e`
- Expected root directory:
  `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17`
- Model source named by k2-fsa:
  [`iic/SenseVoiceSmall`](https://modelscope.cn/models/iic/SenseVoiceSmall)
- Governing model terms: FunASR Model Open Source License Agreement; **not MIT**

The 2024-07-17 archive contains a 71-byte `LICENSE` file that only points to
the moving FunASR repository license section. At that date, FunASR commit
`75ddde7acd49cb6940de339cf7de24297f0826c2` carried version 1.0 of the model
agreement, with SHA-256
`80f5bff3bc3f1b4ba7128e07a7bf94ac10ca260b64059dfdc66e83202bcae50e`.
FunASR later changed the agreement: commit
`58830eca4012644aac0c3218c3ccc7d98f003fda` carries version 1.1, whose current
bytes have SHA-256
`7dba975a2069691db4992b0592d70828b330d2f8a30a71450f4e152a554e84f8`.

Version 1.1 requires source/author attribution and retention of the model name.
It also contains community-conduct termination and automatically effective
revision language. Because the archive points to dynamically revised terms,
SenseVoiceSmall is retained only as a pinned internal preview identity. It is
not part of the public product catalog or any public settings, download, or
recommendation path. A product owner and legal reviewer must review the pinned
historical terms, the then-current terms, attribution, and the
behavioral/automatic-revision clauses before any public distribution. Its
presence in source compatibility material is not distribution approval.

For reproducibility and attribution, the complete current version 1.1 text and
signature are reproduced below exactly as published at the pinned commit.

```text
FunASR Model Open Source License Agreement

Version: 1.1

Copyright (C) [2023-2028] [Alibaba Group]. All rights reserved.

Thank you for choosing the FunASR open-source model. The FunASR open-source model includes a range of free and open industrial models for you to use, modify, share, and learn from.

To ensure better community collaboration, we have established the following agreement, and we hope you will read and comply with its terms.
Definitions

In this agreement, [FunASR Software] refers to FunASR open-source model weights and their derivatives, including finetuned models; [You] refers to individuals or organizations using, modifying, sharing, and learning from [FunASR Software].

2 License and Restrictions

2.1 License

You are free to use, copy, modify, and share [FunASR Software] under the terms of this agreement.

2.2 Restrictions

When using, copying, modifying, and sharing [FunASR Software], you must attribute the source and author information and retain relevant model names in [FunASR Software].

3 Responsibility and Risk

[FunASR Software] is provided for reference and learning purposes only, and Alibaba Group assumes no responsibility for any direct or indirect losses resulting from your use or modification of [FunASR Software]. You should assume all risks associated with using and modifying [FunASR Software].

4 Community Conduct Guidelines

4.1 Encouraged Behavior

The community welcomes developers and users to engage in discussions about [FunASR Software]. Participants are encouraged to interact in a friendly, polite, and respectful manner to foster constructive discussion and collaboration.

4.2 Prohibited Behavior

Individual or organizational users shall not engage in unjustified denigration, malicious smearing, or baseless insults against [FunASR Software]. Such behavior is considered a violation of the spirit of community cooperation. If a user is found to be engaging in the prohibited behavior mentioned above, it will be considered an automatic forfeiture of all licenses under this agreement.

5 Termination

If you violate any terms of this agreement, your license will automatically terminate, and you must cease using, copying, modifying, and sharing [FunASR Software].

6 Revisions

This agreement may be updated and revised occasionally. The revised agreement will be published in the official repository of [FunASR Software] and will take effect automatically. Continuing to use, copy, modify, and share [FunASR Software] indicates your acceptance of the revised agreement.

7 Miscellaneous

This agreement is governed by the laws of [Country/Region]. If any provision is deemed illegal, invalid, or unenforceable, that provision shall be considered severed from this agreement, and the remaining provisions shall continue to be valid and binding.

If you have any questions or comments regarding this agreement, please contact us.

Copyright © [2023-2028] [Alibaba Group]. All rights reserved.


FunASR 模型开源协议

版本号：1.1

版权所有 (C) [2023-2028] [阿里巴巴集团]。保留所有权利。

感谢您选择 FunASR 开源模型。FunASR 开源模型包含一系列免费且开源的工业模型，让大家可以使用、修改、分享和学习该模型。

为了保证更好的社区合作，我们制定了以下协议，希望您仔细阅读并遵守本协议。

1 定义

本协议中，[FunASR 软件]指 FunASR 开源模型权重及其衍生品，包括 Finetune 后的模型；[您]指使用、修改、分享和学习[FunASR 软件]的个人或组织。

2 许可和限制

2.1 许可

您可以在遵守本协议的前提下，自由地使用、复制、修改和分享[FunASR 软件]。

2.2 限制

您在使用、复制、修改和分享[FunASR 软件]时，必须注明出处以及作者信息，并保留[FunASR 软件]中相关模型名称。

3 责任和风险承担

[FunASR 软件]仅作为参考和学习使用，不对您使用或修改[FunASR 软件]造成的任何直接或间接损失承担任何责任。您对[FunASR 软件]的使用和修改应该自行承担风险。

4 社区行为准则

4.1 欢迎交流

社区欢迎开发者与用户对[FunASR 软件]进行交流讨论。交流中请注意保持友好、礼貌和文明，以促进建设性的讨论和合作。

4.2 禁止行为

个人或组织用户不得对[FunASR 软件]进行无端诋毁、恶意抹黑或凭空谩骂。此类行为被视为违反社区合作精神。如被认定从事上述禁止行为，将视为自动放弃本协议下的所有许可。

5 终止

如果您违反本协议的任何条款，您的许可将自动终止，您必须停止使用、复制、修改和分享[FunASR 软件]。

6 修订

本协议可能会不时更新和修订。修订后的协议将在[FunASR 软件]官方仓库发布，并自动生效。如果您继续使用、复制、修改和分享[FunASR 软件]，即表示您同意修订后的协议。

7 其他规定

本协议受到[国家/地区] 的法律管辖。如果任何条款被裁定为不合法、无效或无法执行，则该条款应被视为从本协议中删除，而其余条款应继续有效并具有约束力。

如果您对本协议有任何问题或意见，请联系我们。

版权所有© [2023-2028] [阿里巴巴集团]。保留所有权利。
```

Credit: the SenseVoice and FunASR authors and Alibaba Group; the ModelScope
publisher; and k2-fsa for the sherpa-onnx conversion and release archive.
