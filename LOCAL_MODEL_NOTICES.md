# Rill Local Model Notices

Rill does not bundle speech-model weights in the application. Models are downloaded only after the user enables them. Every production model is fetched at the exact revision listed below and every reviewed file is verified against the byte count and SHA-256 recorded in the Swift catalogs before it is published to Rill's local model directory.

## Speech recognition

| Rill model ID | Upstream repository | Pinned revision |
| --- | --- | --- |
| `qwen3-asr-0.6b-mlx-8bit` | `mlx-community/Qwen3-ASR-0.6B-8bit` | `89e96d92ba34aca20b3e29fb10cc284097d1219f` |
| `qwen3-asr-1.7b-mlx-8bit` | `mlx-community/Qwen3-ASR-1.7B-8bit` | `a8379a2e2f9e313c9292cdf1af4055ab56d50d55` |

The exact reviewed file inventory is defined in `Sources/RillSpeechContracts/LocalSpeechModelCatalog.swift`. Qwen model repositories publish their license and model-card terms alongside the pinned weights. Rill uses these models locally through `mlx-audio-swift`; recognition audio is not uploaded by the local provider.

## Voice activity detection

| Purpose | Upstream repository | Pinned revision |
| --- | --- | --- |
| Streaming VAD | `mlx-community/silero-vad-v6` | `2ebf4a5e10726a2e78ddd4d70eedfb6f1c33eb06` |

The reviewed `model.safetensors` and `config.json` hashes are defined in `Sources/RillMLXRuntime/MLXSileroVADRuntime.swift`. Silero VAD is distributed under the MIT license by its upstream authors. Rill downloads this fixed MLX revision on demand; no ONNX VAD is packaged in the application.

## Speech synthesis

| Rill model ID | Upstream repository | Pinned revision |
| --- | --- | --- |
| `qwen3-tts-0.6b-customvoice-mlx-4bit` | `mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit` | `08c72cad5e2fd0f41730c8bd1f28149585e46361` |
| `qwen3-tts-0.6b-customvoice-mlx-8bit` | `mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit` | `049ef77fe8816b536193c0c25f9a214d17921282` |
| `qwen3-tts-0.6b-customvoice-mlx-bf16` | `mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16` | `6415d95f88be018ff9e46813119dc3bc12261328` |

The exact TTS file inventory is defined in `Sources/RillSpeechContracts/SpeechSynthesisModelCatalog.swift`. TTS is optional: its worker is started only for a resident TTS model or an active synthesis request.

## Runtime boundary

`mlx-audio-swift` and its SwiftPM dependency graph are pinned in `Package.resolved` and documented in `THIRD_PARTY_NOTICES.md`. The main application does not perform MLX inference; supervised ASR and TTS helper processes own their respective model caches.
