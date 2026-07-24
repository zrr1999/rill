# Retired WhisperKit ASR Dogfood Baseline

> **Release status: retired historical evidence only.** This 2026-06-17 run used
> the former WhisperKit production path and synthetic macOS `say` audio. That
> path and its dogfood harness have been removed in favor of sherpa-onnx. The run
> predates the current schema-version 4 privacy/provenance harness and defines no
> approved release threshold. Preserve the records as migration evidence, but do
> not use them to validate the public Qwen3-ASR path, the internal
> SenseVoiceSmall identity, the current microphone and
> endpointing path, or any release candidate. Current acceptance work is defined
> in [`asr-benchmark-plan.md`](asr-benchmark-plan.md).

Generated: 2026-06-17T16:52:45.477904+00:00

## Run summary

- Input source: macOS `say` TTS generated WAV files from the benchmark prompt set.
- Completed comparison: Rill / WhisperKit local `openai_whisper-tiny` plus Rill / Deepgram prerecorded cloud with configured `zh` language vs auto language.
- Engine blocked: macOS system dictation is interactive and was not automatable from this session.
- Deepgram model: `nova-3`; configured language: `zh`.
- configured-zh: avg final latency 2.918s; avg normalized edit count 4.8; proprietary terms ok 3/10; failures {'proprietary_term': 7}.
- auto-language: avg final latency 1.638s; avg normalized edit count 15.3; proprietary terms ok 4/10; failures {'empty_transcript': 3, 'proprietary_term': 3, 'high_edit_distance': 1}.
- whisperkit-tiny-local: avg final latency 1.404s; avg normalized edit count 23.8; proprietary terms ok 3/10; failures {'proprietary_term': 6, 'empty_transcript': 1, 'high_edit_distance': 1}.

## Records

| case | tool/engine | path | first token | final | edits | terms ok | format ok | failure | reference | transcript |
|---|---|---|---:|---:|---:|---|---|---|---|---|
| 01 | Rill / Deepgram nova-3 (configured-zh) | cloud | n/a-prerecorded | 3.679 | 2 | False | True | proprietary_term | 今天下午三点我们同步一下 Rill 的工作流设计。 | 今天下午3点我们同步一下vxtype的工作流设计。 |
| 02 | Rill / Deepgram nova-3 (configured-zh) | cloud | n/a-prerecorded | 5.737 | 10 | False | True | proprietary_term | Please turn this note into a concise GitHub issue comment. | leseturnthisnoteintoaconcystrhubishocomment。 |
| 03 | Rill / Deepgram nova-3 (configured-zh) | cloud | n/a-prerecorded | 1.942 | 2 | False | True | proprietary_term | 我等一下把这个想法整理到 README 里。 | 我等一下把这个想法整理到read里。 |
| 04 | Rill / Deepgram nova-3 (configured-zh) | cloud | n/a-prerecorded | 1.376 | 8 | True | True |  | The benchmark should measure latency, edit distance, and user effort. | benchmarkshootmeasurelatency、editdistance、anduserethort。 |
| 05 | Rill / Deepgram nova-3 (configured-zh) | cloud | n/a-prerecorded | 1.593 | 4 | True | True |  | 把 WhisperKit 和 Deepgram 的 provider seam 保持干净。 | buisferkit和deepgram的providerseam保持干净。 |
| 06 | Rill / Deepgram nova-3 (configured-zh) | cloud | n/a-prerecorded | 1.367 | 1 | False | True | proprietary_term | 这个 Pull Request 先不要引入 Core Data。 | 这个pullrequest先不要引入coredate。 |
| 07 | Rill / Deepgram nova-3 (configured-zh) | cloud | n/a-prerecorded | 6.723 | 0 | True | True |  | 我们需要一个 PromptVariableContext 来渲染 selected 和 clipboard。 | 我们需要一个promptvariablecontext来渲染selected和clipboard。 |
| 08 | Rill / Deepgram nova-3 (configured-zh) | cloud | n/a-prerecorded | 1.667 | 8 | False | True | proprietary_term | Run swift test after updating the VocabularyRule applicator. | swfttestafterupdating的v0cabularyruleapplicator。 |
| 09 | Rill / Deepgram nova-3 (configured-zh) | cloud | n/a-prerecorded | 3.49 | 7 | False | True | proprietary_term | Rill 的语音识别组应该支持 Stack 和 Queue 两种模式。 | v0xtype的语音识别组应该支持stag和ku两种模式。 |
| 10 | Rill / Deepgram nova-3 (configured-zh) | cloud | n/a-prerecorded | 1.604 | 6 | False | True | proprietary_term | Type4Me 的热词和映射词体验值得参考。 | 4末的热词和映射词体验值得参考。 |
| 01 | Rill / Deepgram nova-3 (auto-language) | cloud | n/a-prerecorded | 1.533 | 25 | False | True | empty_transcript | 今天下午三点我们同步一下 Rill 的工作流设计。 |  |
| 02 | Rill / Deepgram nova-3 (auto-language) | cloud | n/a-prerecorded | 2.047 | 2 | True | True |  | Please turn this note into a concise GitHub issue comment. | Please turn this note into a consist GitHub issue comment. |
| 03 | Rill / Deepgram nova-3 (auto-language) | cloud | n/a-prerecorded | 1.232 | 19 | False | True | empty_transcript | 我等一下把这个想法整理到 README 里。 |  |
| 04 | Rill / Deepgram nova-3 (auto-language) | cloud | n/a-prerecorded | 1.227 | 0 | True | True |  | The benchmark should measure latency, edit distance, and user effort. | The benchmark should measure latency, edit distance, and user effort. |
| 05 | Rill / Deepgram nova-3 (auto-language) | cloud | n/a-prerecorded | 1.232 | 37 | False | True | empty_transcript | 把 WhisperKit 和 Deepgram 的 provider seam 保持干净。 |  |
| 06 | Rill / Deepgram nova-3 (auto-language) | cloud | n/a-prerecorded | 1.112 | 19 | False | True | proprietary_term | 这个 Pull Request 先不要引入 Core Data。 | Request. |
| 07 | Rill / Deepgram nova-3 (auto-language) | cloud | n/a-prerecorded | 2.879 | 10 | True | True | high_edit_distance | 我们需要一个 PromptVariableContext 来渲染 selected 和 clipboard。 | Prompt variable context selected clipboard. |
| 08 | Rill / Deepgram nova-3 (auto-language) | cloud | n/a-prerecorded | 1.841 | 0 | True | True |  | Run swift test after updating the VocabularyRule applicator. | Run Swift test after updating the vocabulary rule applicator. |
| 09 | Rill / Deepgram nova-3 (auto-language) | cloud | n/a-prerecorded | 1.342 | 25 | False | True | proprietary_term | Rill 的语音识别组应该支持 Stack 和 Queue 两种模式。 | Vox type |
| 10 | Rill / Deepgram nova-3 (auto-language) | cloud | n/a-prerecorded | 1.935 | 16 | False | True | proprietary_term | Type4Me 的热词和映射词体验值得参考。 | Type |

## WhisperKit local records

| case | tool/engine | path | first token | final | edits | terms ok | format ok | failure | reference | transcript |
|---|---|---|---:|---:|---:|---|---|---|---|---|
| 01 | Rill / WhisperKit openai_whisper-tiny | local | n/a-prerecorded | 12.297 | 54 | False | True | proprietary_term | 今天下午三点我们同步一下 Rill 的工作流设计。 | In today's afternoon, we will start the work of the company's research |
| 02 | Rill / WhisperKit openai_whisper-tiny | local | n/a-prerecorded | 0.056 | 9 | False | True | proprietary_term | Please turn this note into a concise GitHub issue comment. | Please turn this note into a consistency sheet hub issue comment. |
| 03 | Rill / WhisperKit openai_whisper-tiny | local | n/a-prerecorded | 0.168 | 19 | False | True | empty_transcript | 我等一下把这个想法整理到 README 里。 |  |
| 04 | Rill / WhisperKit openai_whisper-tiny | local | n/a-prerecorded | 0.061 | 0 | True | True |  | The benchmark should measure latency, edit distance, and user effort. | The benchmark should measure latency, edit distance, and user effort. |
| 05 | Rill / WhisperKit openai_whisper-tiny | local | n/a-prerecorded | 0.191 | 21 | False | True | proprietary_term | 把 WhisperKit 和 Deepgram 的 provider seam 保持干净。 | Pack with Verkidhe Deep Gremd the Provator Sim保持干净 |
| 06 | Rill / WhisperKit openai_whisper-tiny | local | n/a-prerecorded | 0.049 | 22 | False | True | proprietary_term | 这个 Pull Request 先不要引入 Core Data。 | This pool request is not a root code agent. |
| 07 | Rill / WhisperKit openai_whisper-tiny | local | n/a-prerecorded | 0.088 | 36 | False | True | proprietary_term | 我们需要一个 PromptVariableContext 来渲染 selected 和 clipboard。 | We're in Xu Yao Yi Geprom, to variable context, like Xu Yan Lan, Seluk to the clipboard. |
| 08 | Rill / WhisperKit openai_whisper-tiny | local | n/a-prerecorded | 0.054 | 0 | True | True |  | Run swift test after updating the VocabularyRule applicator. | Run Swift test after updating the vocabulary rule applicator. |
| 09 | Rill / WhisperKit openai_whisper-tiny | local | n/a-prerecorded | 0.266 | 40 | False | True | proprietary_term | Rill 的语音识别组应该支持 Stack 和 Queue 两种模式。 | Vox Sharp's U.N.S.B. Zoyen-Gizz-Stack Heku Liang-Zhong-Mosh |
| 10 | Rill / WhisperKit openai_whisper-tiny | local | n/a-prerecorded | 0.811 | 37 | True | True | high_edit_distance | Type4Me 的热词和映射词体验值得参考。 | The Rp4M of Rp4M is the one that supports Rp4M's TNG. |

## Top failure types

- proprietary_term: 16
- empty_transcript: 4
- high_edit_distance: 2
- benchmark_blocker: macOS system dictation remains interactive/non-automated; provider ranking is based on Rill local/cloud paths only

## Vocabulary rule candidates

- `Vox type` / `vox type` / `v0xtype` -> `Rill`.
- `whisper kit` / `buisferkit` -> `WhisperKit`.
- `deep gram` -> `Deepgram`.
- `prompt variable context` -> `PromptVariableContext`.
- `type for me` / `4 me` -> `Type4Me`.

## Provider/config decision

The following was the conclusion for the retired WhisperKit-era configuration;
it is not a current sherpa-onnx routing recommendation.

Do not use one global Deepgram language setting for all Rill workflows. On this corpus, configured `zh` preserved Chinese/mixed utterances better but degraded English commands and technical terms; auto language improved English commands but produced empty or partial transcripts for several Chinese-led samples. WhisperKit `openai_whisper-tiny` was fast after first load but unusable for Chinese-led mixed dictation and only reliable on simple English command cases. Prefer per-workflow or per-locale routing (`zh` for Chinese-first cloud workflows, auto/en for English command workflows), keep local-first privacy messaging, and benchmark a larger local model before making WhisperKit tiny the default for mixed-language use.

## UI/workflow recommendation

Add a first-class ASR benchmark/debug command that reuses Rill recognizer abstractions and writes provider, model, language, duration, transcript, and privacy path metadata. The settings UI should also surface the current Deepgram language override because it materially changes mixed-language quality.

## Disposition log

- already_covered: Keep `VocabularyRule`/prompt variable investment as high priority; this benchmark supplies concrete candidate terms and variants, and the vocabulary core model is already implemented.
- retired: The former `ASRDogfoodWhisperKitHarnessTests` path has been removed and cannot produce evidence for the current sherpa-onnx runtime. New local evidence must follow `asr-benchmark-plan.md` with Qwen3-ASR as the required default path.
- already_covered: Add provider/model/language metadata to benchmark/debug output; this aligns with the workflow observability work already implemented.
- historical_decision: This run alone did not justify a new provider. The product has since migrated to sherpa-onnx with Qwen3-ASR as the default local model; current provider decisions require new scope-matched evidence.
