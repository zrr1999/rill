#ifndef RILL_C_SHERPA_ONNX_H_
#define RILL_C_SHERPA_ONNX_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RillSherpaOfflineRecognizer RillSherpaOfflineRecognizer;
typedef struct RillSherpaOnlineRecognizer RillSherpaOnlineRecognizer;
typedef struct RillSherpaOnlineStream RillSherpaOnlineStream;
typedef struct RillSherpaSileroVad RillSherpaSileroVad;

typedef enum RillSherpaVadStatus {
  RILL_SHERPA_VAD_STATUS_OK = 0,
  RILL_SHERPA_VAD_STATUS_INVALID_ARGUMENT = 1,
  RILL_SHERPA_VAD_STATUS_NATIVE_FAILURE = 2,
} RillSherpaVadStatus;

typedef struct RillSherpaOfflineResult {
  char *text;
  char *language;
  char *emotion;
  char *event;
  float *timestamps;
  float *durations;
  int32_t count;
} RillSherpaOfflineResult;

const char *RillSherpaOnnxVersion(void);
const char *RillSherpaOnnxGitSHA1(void);

RillSherpaOfflineRecognizer *RillSherpaCreateQwen3Recognizer(
    const char *conv_frontend, const char *encoder, const char *decoder,
    const char *tokenizer, int32_t num_threads, int32_t max_total_length,
    int32_t max_new_tokens, float temperature, float top_p, int32_t seed,
    const char *hotwords);

RillSherpaOfflineRecognizer *RillSherpaCreateSenseVoiceRecognizer(
    const char *model, const char *tokens, const char *language,
    int32_t use_inverse_text_normalization, int32_t num_threads);

RillSherpaOfflineRecognizer *RillSherpaCreateFunASRNanoRecognizer(
    const char *encoder_adaptor, const char *llm, const char *embedding,
    const char *tokenizer, const char *language,
    int32_t use_inverse_text_normalization, int32_t num_threads,
    const char *hotwords);

RillSherpaOfflineRecognizer *RillSherpaCreateOmnilingualRecognizer(
    const char *model, const char *tokens, int32_t num_threads);

RillSherpaOfflineRecognizer *RillSherpaCreateCohereTranscribeRecognizer(
    const char *encoder, const char *decoder, const char *tokens,
    const char *language, int32_t use_punctuation,
    int32_t use_inverse_text_normalization, int32_t num_threads);

void RillSherpaDestroyOfflineRecognizer(
    RillSherpaOfflineRecognizer *recognizer);

RillSherpaOfflineResult *
RillSherpaDecodeOffline(RillSherpaOfflineRecognizer *recognizer,
                           const float *samples, int32_t sample_count,
                           int32_t sample_rate);

RillSherpaOfflineResult *RillSherpaDecodeOfflineWithHotwords(
    RillSherpaOfflineRecognizer *recognizer, const float *samples,
    int32_t sample_count, int32_t sample_rate, const char *hotwords_csv);

void RillSherpaDestroyOfflineResult(RillSherpaOfflineResult *result);

RillSherpaOnlineRecognizer *RillSherpaCreateStreamingZipformerRecognizer(
    const char *encoder, const char *decoder, const char *joiner,
    const char *tokens, int32_t num_threads);

void RillSherpaDestroyOnlineRecognizer(
    RillSherpaOnlineRecognizer *recognizer);

RillSherpaOnlineStream *RillSherpaCreateOnlineStream(
    RillSherpaOnlineRecognizer *recognizer);

void RillSherpaDestroyOnlineStream(RillSherpaOnlineStream *stream);

int32_t RillSherpaOnlineStreamAcceptAndDecode(
    RillSherpaOnlineRecognizer *recognizer,
    RillSherpaOnlineStream *stream, const float *samples,
    int32_t sample_count, int32_t sample_rate, char **text);

int32_t RillSherpaOnlineStreamFinishAndDecode(
    RillSherpaOnlineRecognizer *recognizer,
    RillSherpaOnlineStream *stream, char **text);

void RillSherpaFreeString(char *text);

RillSherpaSileroVad *RillSherpaCreateSileroVad(
    const char *model, float threshold, float min_silence_duration,
    float min_speech_duration, float max_speech_duration, int32_t num_threads,
    float buffer_size_in_seconds);

void RillSherpaDestroySileroVad(RillSherpaSileroVad *vad);

int32_t RillSherpaSileroVadAcceptFrame(RillSherpaSileroVad *vad,
                                          const float *samples,
                                          int32_t sample_count,
                                          int32_t *is_speech);

int32_t RillSherpaSileroVadReset(RillSherpaSileroVad *vad);

#ifdef __cplusplus
}
#endif

#endif // RILL_C_SHERPA_ONNX_H_
