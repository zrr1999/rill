#include "CSherpaOnnx.h"

#include <sherpa-onnx/c-api/c-api.h>

#include <math.h>
#include <stdlib.h>
#include <string.h>

enum {
  RILL_SHERPA_VAD_SAMPLE_RATE = 16000,
  RILL_SHERPA_VAD_FRAME_SIZE = 512,
};

struct RillSherpaOfflineRecognizer {
  const SherpaOnnxOfflineRecognizer *raw;
};

struct RillSherpaOnlineRecognizer {
  const SherpaOnnxOnlineRecognizer *raw;
};

struct RillSherpaOnlineStream {
  const SherpaOnnxOnlineStream *raw;
};

struct RillSherpaSileroVad {
  const SherpaOnnxVoiceActivityDetector *raw;
};

static RillSherpaOfflineRecognizer *
RillSherpaWrapRecognizer(const SherpaOnnxOfflineRecognizer *raw) {
  if (raw == NULL) {
    return NULL;
  }

  RillSherpaOfflineRecognizer *recognizer =
      (RillSherpaOfflineRecognizer *)calloc(1, sizeof(*recognizer));
  if (recognizer == NULL) {
    SherpaOnnxDestroyOfflineRecognizer(raw);
    return NULL;
  }

  recognizer->raw = raw;
  return recognizer;
}

static char *RillSherpaCopyString(const char *source) {
  const char *value = source == NULL ? "" : source;
  size_t byte_count = strlen(value) + 1;
  char *copy = (char *)malloc(byte_count);
  if (copy != NULL) {
    memcpy(copy, value, byte_count);
  }
  return copy;
}

const char *RillSherpaOnnxVersion(void) { return SherpaOnnxGetVersionStr(); }

const char *RillSherpaOnnxGitSHA1(void) { return SherpaOnnxGetGitSha1(); }

RillSherpaOfflineRecognizer *RillSherpaCreateQwen3Recognizer(
    const char *conv_frontend, const char *encoder, const char *decoder,
    const char *tokenizer, int32_t num_threads, int32_t max_total_length,
    int32_t max_new_tokens, float temperature, float top_p, int32_t seed,
    const char *hotwords) {
  SherpaOnnxOfflineRecognizerConfig config = {0};
  config.feat_config.sample_rate = 16000;
  config.feat_config.feature_dim = 80;
  config.model_config.tokens = "";
  config.model_config.num_threads = num_threads;
  config.model_config.provider = "cpu";
  config.model_config.qwen3_asr.conv_frontend = conv_frontend;
  config.model_config.qwen3_asr.encoder = encoder;
  config.model_config.qwen3_asr.decoder = decoder;
  config.model_config.qwen3_asr.tokenizer = tokenizer;
  config.model_config.qwen3_asr.max_total_len = max_total_length;
  config.model_config.qwen3_asr.max_new_tokens = max_new_tokens;
  config.model_config.qwen3_asr.temperature = temperature;
  config.model_config.qwen3_asr.top_p = top_p;
  config.model_config.qwen3_asr.seed = seed;
  config.model_config.qwen3_asr.hotwords = hotwords;
  config.decoding_method = "greedy_search";
  config.max_active_paths = 4;
  config.hotwords_score = 1.5f;

  return RillSherpaWrapRecognizer(
      SherpaOnnxCreateOfflineRecognizer(&config));
}

RillSherpaOfflineRecognizer *RillSherpaCreateSenseVoiceRecognizer(
    const char *model, const char *tokens, const char *language,
    int32_t use_inverse_text_normalization, int32_t num_threads) {
  SherpaOnnxOfflineRecognizerConfig config = {0};
  config.feat_config.sample_rate = 16000;
  config.feat_config.feature_dim = 80;
  config.model_config.tokens = tokens;
  config.model_config.num_threads = num_threads;
  config.model_config.provider = "cpu";
  config.model_config.sense_voice.model = model;
  config.model_config.sense_voice.language = language;
  config.model_config.sense_voice.use_itn = use_inverse_text_normalization;
  config.decoding_method = "greedy_search";
  config.max_active_paths = 4;
  config.hotwords_score = 1.5f;

  return RillSherpaWrapRecognizer(
      SherpaOnnxCreateOfflineRecognizer(&config));
}

RillSherpaOfflineRecognizer *RillSherpaCreateFunASRNanoRecognizer(
    const char *encoder_adaptor, const char *llm, const char *embedding,
    const char *tokenizer, const char *language,
    int32_t use_inverse_text_normalization, int32_t num_threads,
    const char *hotwords) {
  SherpaOnnxOfflineRecognizerConfig config = {0};
  config.feat_config.sample_rate = 16000;
  config.feat_config.feature_dim = 80;
  config.model_config.num_threads = num_threads;
  config.model_config.provider = "cpu";
  config.model_config.funasr_nano.encoder_adaptor = encoder_adaptor;
  config.model_config.funasr_nano.llm = llm;
  config.model_config.funasr_nano.embedding = embedding;
  config.model_config.funasr_nano.tokenizer = tokenizer;
  config.model_config.funasr_nano.language = language;
  config.model_config.funasr_nano.itn = use_inverse_text_normalization;
  config.model_config.funasr_nano.hotwords = hotwords;
  config.decoding_method = "greedy_search";

  return RillSherpaWrapRecognizer(
      SherpaOnnxCreateOfflineRecognizer(&config));
}

RillSherpaOfflineRecognizer *RillSherpaCreateOmnilingualRecognizer(
    const char *model, const char *tokens, int32_t num_threads) {
  SherpaOnnxOfflineRecognizerConfig config = {0};
  config.feat_config.sample_rate = 16000;
  config.feat_config.feature_dim = 80;
  config.model_config.tokens = tokens;
  config.model_config.num_threads = num_threads;
  config.model_config.provider = "cpu";
  config.model_config.omnilingual.model = model;
  config.decoding_method = "greedy_search";

  return RillSherpaWrapRecognizer(
      SherpaOnnxCreateOfflineRecognizer(&config));
}

RillSherpaOfflineRecognizer *RillSherpaCreateCohereTranscribeRecognizer(
    const char *encoder, const char *decoder, const char *tokens,
    const char *language, int32_t use_punctuation,
    int32_t use_inverse_text_normalization, int32_t num_threads) {
  SherpaOnnxOfflineRecognizerConfig config = {0};
  config.feat_config.sample_rate = 16000;
  config.feat_config.feature_dim = 80;
  config.model_config.tokens = tokens;
  config.model_config.num_threads = num_threads;
  config.model_config.provider = "cpu";
  config.model_config.cohere_transcribe.encoder = encoder;
  config.model_config.cohere_transcribe.decoder = decoder;
  config.model_config.cohere_transcribe.language = language;
  config.model_config.cohere_transcribe.use_punct = use_punctuation;
  config.model_config.cohere_transcribe.use_itn =
      use_inverse_text_normalization;
  config.decoding_method = "greedy_search";

  return RillSherpaWrapRecognizer(
      SherpaOnnxCreateOfflineRecognizer(&config));
}

void RillSherpaDestroyOfflineRecognizer(
    RillSherpaOfflineRecognizer *recognizer) {
  if (recognizer == NULL) {
    return;
  }
  SherpaOnnxDestroyOfflineRecognizer(recognizer->raw);
  free(recognizer);
}

void RillSherpaDestroyOfflineResult(RillSherpaOfflineResult *result) {
  if (result == NULL) {
    return;
  }
  free(result->text);
  free(result->language);
  free(result->emotion);
  free(result->event);
  free(result->timestamps);
  free(result->durations);
  free(result);
}

RillSherpaOnlineRecognizer *RillSherpaCreateStreamingZipformerRecognizer(
    const char *encoder, const char *decoder, const char *joiner,
    const char *tokens, int32_t num_threads) {
  if (encoder == NULL || encoder[0] == '\0' || decoder == NULL ||
      decoder[0] == '\0' || joiner == NULL || joiner[0] == '\0' ||
      tokens == NULL || tokens[0] == '\0' || num_threads <= 0) {
    return NULL;
  }

  SherpaOnnxOnlineRecognizerConfig config = {0};
  config.feat_config.sample_rate = 16000;
  config.feat_config.feature_dim = 80;
  config.model_config.transducer.encoder = encoder;
  config.model_config.transducer.decoder = decoder;
  config.model_config.transducer.joiner = joiner;
  config.model_config.tokens = tokens;
  config.model_config.num_threads = num_threads;
  config.model_config.provider = "cpu";
  config.decoding_method = "greedy_search";
  config.max_active_paths = 4;

  const SherpaOnnxOnlineRecognizer *raw =
      SherpaOnnxCreateOnlineRecognizer(&config);
  if (raw == NULL) {
    return NULL;
  }
  RillSherpaOnlineRecognizer *recognizer =
      (RillSherpaOnlineRecognizer *)calloc(1, sizeof(*recognizer));
  if (recognizer == NULL) {
    SherpaOnnxDestroyOnlineRecognizer(raw);
    return NULL;
  }
  recognizer->raw = raw;
  return recognizer;
}

void RillSherpaDestroyOnlineRecognizer(
    RillSherpaOnlineRecognizer *recognizer) {
  if (recognizer == NULL) {
    return;
  }
  SherpaOnnxDestroyOnlineRecognizer(recognizer->raw);
  free(recognizer);
}

RillSherpaOnlineStream *RillSherpaCreateOnlineStream(
    RillSherpaOnlineRecognizer *recognizer) {
  if (recognizer == NULL) {
    return NULL;
  }
  const SherpaOnnxOnlineStream *raw =
      SherpaOnnxCreateOnlineStream(recognizer->raw);
  if (raw == NULL) {
    return NULL;
  }
  RillSherpaOnlineStream *stream =
      (RillSherpaOnlineStream *)calloc(1, sizeof(*stream));
  if (stream == NULL) {
    SherpaOnnxDestroyOnlineStream(raw);
    return NULL;
  }
  stream->raw = raw;
  return stream;
}

void RillSherpaDestroyOnlineStream(RillSherpaOnlineStream *stream) {
  if (stream == NULL) {
    return;
  }
  SherpaOnnxDestroyOnlineStream(stream->raw);
  free(stream);
}

static int32_t RillSherpaCopyOnlineResult(
    RillSherpaOnlineRecognizer *recognizer,
    RillSherpaOnlineStream *stream, char **text) {
  const SherpaOnnxOnlineRecognizerResult *result =
      SherpaOnnxGetOnlineStreamResult(recognizer->raw, stream->raw);
  if (result == NULL) {
    return 0;
  }
  *text = RillSherpaCopyString(result->text);
  SherpaOnnxDestroyOnlineRecognizerResult(result);
  return *text == NULL ? 0 : 1;
}

int32_t RillSherpaOnlineStreamAcceptAndDecode(
    RillSherpaOnlineRecognizer *recognizer,
    RillSherpaOnlineStream *stream, const float *samples,
    int32_t sample_count, int32_t sample_rate, char **text) {
  if (recognizer == NULL || stream == NULL || samples == NULL ||
      sample_count <= 0 || sample_rate <= 0 || text == NULL) {
    return 0;
  }
  *text = NULL;
  for (int32_t index = 0; index < sample_count; ++index) {
    if (!isfinite(samples[index]) || samples[index] < -1.0f ||
        samples[index] > 1.0f) {
      return 0;
    }
  }
  SherpaOnnxOnlineStreamAcceptWaveform(stream->raw, sample_rate, samples,
                                       sample_count);
  while (SherpaOnnxIsOnlineStreamReady(recognizer->raw, stream->raw)) {
    SherpaOnnxDecodeOnlineStream(recognizer->raw, stream->raw);
  }
  return RillSherpaCopyOnlineResult(recognizer, stream, text);
}

int32_t RillSherpaOnlineStreamFinishAndDecode(
    RillSherpaOnlineRecognizer *recognizer,
    RillSherpaOnlineStream *stream, char **text) {
  if (recognizer == NULL || stream == NULL || text == NULL) {
    return 0;
  }
  *text = NULL;
  SherpaOnnxOnlineStreamInputFinished(stream->raw);
  while (SherpaOnnxIsOnlineStreamReady(recognizer->raw, stream->raw)) {
    SherpaOnnxDecodeOnlineStream(recognizer->raw, stream->raw);
  }
  return RillSherpaCopyOnlineResult(recognizer, stream, text);
}

void RillSherpaFreeString(char *text) { free(text); }

RillSherpaSileroVad *RillSherpaCreateSileroVad(
    const char *model, float threshold, float min_silence_duration,
    float min_speech_duration, float max_speech_duration, int32_t num_threads,
    float buffer_size_in_seconds) {
  if (model == NULL || model[0] == '\0' || !isfinite(threshold) ||
      threshold <= 0.0f || threshold >= 1.0f ||
      !isfinite(min_silence_duration) || min_silence_duration <= 0.0f ||
      !isfinite(min_speech_duration) || min_speech_duration <= 0.0f ||
      !isfinite(max_speech_duration) ||
      max_speech_duration <= min_speech_duration ||
      max_speech_duration <= min_silence_duration || num_threads <= 0 ||
      !isfinite(buffer_size_in_seconds) ||
      buffer_size_in_seconds < max_speech_duration) {
    return NULL;
  }

  SherpaOnnxVadModelConfig config = {0};
  config.silero_vad.model = model;
  config.silero_vad.threshold = threshold;
  config.silero_vad.min_silence_duration = min_silence_duration;
  config.silero_vad.min_speech_duration = min_speech_duration;
  config.silero_vad.max_speech_duration = max_speech_duration;
  config.silero_vad.window_size = RILL_SHERPA_VAD_FRAME_SIZE;
  config.sample_rate = RILL_SHERPA_VAD_SAMPLE_RATE;
  config.num_threads = num_threads;
  config.provider = "cpu";
  config.debug = 0;

  const SherpaOnnxVoiceActivityDetector *raw =
      SherpaOnnxCreateVoiceActivityDetector(&config, buffer_size_in_seconds);
  if (raw == NULL) {
    return NULL;
  }

  RillSherpaSileroVad *vad =
      (RillSherpaSileroVad *)calloc(1, sizeof(*vad));
  if (vad == NULL) {
    SherpaOnnxDestroyVoiceActivityDetector(raw);
    return NULL;
  }
  vad->raw = raw;
  return vad;
}

void RillSherpaDestroySileroVad(RillSherpaSileroVad *vad) {
  if (vad == NULL) {
    return;
  }
  SherpaOnnxDestroyVoiceActivityDetector(vad->raw);
  free(vad);
}

int32_t RillSherpaSileroVadAcceptFrame(RillSherpaSileroVad *vad,
                                          const float *samples,
                                          int32_t sample_count,
                                          int32_t *is_speech) {
  if (vad == NULL || samples == NULL ||
      sample_count != RILL_SHERPA_VAD_FRAME_SIZE || is_speech == NULL) {
    return RILL_SHERPA_VAD_STATUS_INVALID_ARGUMENT;
  }
  for (int32_t index = 0; index < sample_count; ++index) {
    if (!isfinite(samples[index]) || samples[index] < -1.0f ||
        samples[index] > 1.0f) {
      return RILL_SHERPA_VAD_STATUS_INVALID_ARGUMENT;
    }
  }

  SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad->raw, samples,
                                                sample_count);
  int32_t detected = SherpaOnnxVoiceActivityDetectorDetected(vad->raw);
  if (detected != 0 && detected != 1) {
    *is_speech = 0;
    return RILL_SHERPA_VAD_STATUS_NATIVE_FAILURE;
  }
  *is_speech = detected;

  int32_t empty = SherpaOnnxVoiceActivityDetectorEmpty(vad->raw);
  if (empty == 0) {
    SherpaOnnxVoiceActivityDetectorClear(vad->raw);
    empty = SherpaOnnxVoiceActivityDetectorEmpty(vad->raw);
  }
  if (empty != 1) {
    *is_speech = 0;
    return RILL_SHERPA_VAD_STATUS_NATIVE_FAILURE;
  }
  return RILL_SHERPA_VAD_STATUS_OK;
}

int32_t RillSherpaSileroVadReset(RillSherpaSileroVad *vad) {
  if (vad == NULL) {
    return RILL_SHERPA_VAD_STATUS_INVALID_ARGUMENT;
  }
  SherpaOnnxVoiceActivityDetectorReset(vad->raw);
  SherpaOnnxVoiceActivityDetectorClear(vad->raw);
  return RILL_SHERPA_VAD_STATUS_OK;
}

RillSherpaOfflineResult *
RillSherpaDecodeOffline(RillSherpaOfflineRecognizer *recognizer,
                           const float *samples, int32_t sample_count,
                           int32_t sample_rate) {
  return RillSherpaDecodeOfflineWithHotwords(
      recognizer, samples, sample_count, sample_rate, NULL);
}

RillSherpaOfflineResult *RillSherpaDecodeOfflineWithHotwords(
    RillSherpaOfflineRecognizer *recognizer, const float *samples,
    int32_t sample_count, int32_t sample_rate, const char *hotwords_csv) {
  if (recognizer == NULL || samples == NULL || sample_count <= 0 ||
      sample_rate <= 0) {
    return NULL;
  }

  const SherpaOnnxOfflineStream *stream =
      SherpaOnnxCreateOfflineStream(recognizer->raw);
  if (stream == NULL) {
    return NULL;
  }

  if (hotwords_csv != NULL) {
    SherpaOnnxOfflineStreamSetOption(stream, "hotwords", hotwords_csv);
  }
  SherpaOnnxAcceptWaveformOffline(stream, sample_rate, samples, sample_count);
  SherpaOnnxDecodeOfflineStream(recognizer->raw, stream);

  const SherpaOnnxOfflineRecognizerResult *raw_result =
      SherpaOnnxGetOfflineStreamResult(stream);
  if (raw_result == NULL) {
    SherpaOnnxDestroyOfflineStream(stream);
    return NULL;
  }

  RillSherpaOfflineResult *result =
      (RillSherpaOfflineResult *)calloc(1, sizeof(*result));
  if (result == NULL) {
    SherpaOnnxDestroyOfflineRecognizerResult(raw_result);
    SherpaOnnxDestroyOfflineStream(stream);
    return NULL;
  }

  result->text = RillSherpaCopyString(raw_result->text);
  result->language = RillSherpaCopyString(raw_result->lang);
  result->emotion = RillSherpaCopyString(raw_result->emotion);
  result->event = RillSherpaCopyString(raw_result->event);
  result->count = raw_result->count;

  if (result->text == NULL || result->language == NULL ||
      result->emotion == NULL || result->event == NULL) {
    RillSherpaDestroyOfflineResult(result);
    SherpaOnnxDestroyOfflineRecognizerResult(raw_result);
    SherpaOnnxDestroyOfflineStream(stream);
    return NULL;
  }

  if (raw_result->count > 0 && raw_result->timestamps != NULL) {
    size_t byte_count = sizeof(float) * (size_t)raw_result->count;
    result->timestamps = (float *)malloc(byte_count);
    if (result->timestamps == NULL) {
      RillSherpaDestroyOfflineResult(result);
      SherpaOnnxDestroyOfflineRecognizerResult(raw_result);
      SherpaOnnxDestroyOfflineStream(stream);
      return NULL;
    }
    memcpy(result->timestamps, raw_result->timestamps, byte_count);
  }

  if (raw_result->count > 0 && raw_result->durations != NULL) {
    size_t byte_count = sizeof(float) * (size_t)raw_result->count;
    result->durations = (float *)malloc(byte_count);
    if (result->durations == NULL) {
      RillSherpaDestroyOfflineResult(result);
      SherpaOnnxDestroyOfflineRecognizerResult(raw_result);
      SherpaOnnxDestroyOfflineStream(stream);
      return NULL;
    }
    memcpy(result->durations, raw_result->durations, byte_count);
  }

  SherpaOnnxDestroyOfflineRecognizerResult(raw_result);
  SherpaOnnxDestroyOfflineStream(stream);
  return result;
}
