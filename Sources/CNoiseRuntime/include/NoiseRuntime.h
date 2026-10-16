#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct NRDenoiser NRDenoiser;
typedef struct NRProcessor NRProcessor;
typedef struct NRVoiceLeveler NRVoiceLeveler;
typedef struct NRPipeline NRPipeline;
// All engines consume mono float PCM at 48 kHz in 480-sample (10 ms) blocks.
enum { NR_DPDFNET = 0, NR_DEEPFILTERNET = 1, NR_RNNOISE = 2, NR_MAIN_SPEAKER = 3 };
typedef struct {
    float input_peak;
    float output_peak;
    float processing_ms;
    uint64_t input_frames;
    uint64_t underrun_frames;
    uint64_t dropped_frames;
    int32_t failed;
    float voice_gain_db;
} NRStats;

NRDenoiser *nr_denoiser_create(int engine, const char *libraries, const char *models,
                             char *error, int error_capacity);
bool nr_denoiser_process(NRDenoiser *, const float input[480], float output[480]);
void nr_denoiser_destroy(NRDenoiser *);
int nr_denoiser_delay_samples(NRDenoiser *);

// Shared processing chain used by live routes and recording comparisons.
NRProcessor *nr_processor_create(int engine, const char *libraries, const char *models,
                                char *error, int error_capacity);
bool nr_processor_process(NRProcessor *, const float input[480], float output[480],
                          bool leveling_enabled, bool bypass);
float nr_processor_gain_db(NRProcessor *);
void nr_processor_destroy(NRProcessor *);
// 0 = original signal, 1 = full suppression. The dry signal is delayed to match
// each pinned model before mixing. Lower strength also retains more background voices.
void nr_processor_set_strength(NRProcessor *, float strength);

// Speech-aware gain control, followed by a frame-peak limiter. Mono 48 kHz.
NRVoiceLeveler *nr_voice_leveler_create(void);
void nr_voice_leveler_process(NRVoiceLeveler *, float samples[480], float speech_probability, bool enabled);
float nr_voice_leveler_gain_db(NRVoiceLeveler *);
void nr_voice_leveler_destroy(NRVoiceLeveler *);

NRPipeline *nr_pipeline_create(int engine, const char *libraries, const char *models,
                               char *error, int error_capacity);
// Start output before capture, so a failed setup never leaves a selected app muted.
bool nr_pipeline_start_output(NRPipeline *, AudioDeviceID, char *error, int error_capacity);
bool nr_pipeline_start_apps(NRPipeline *, const AudioObjectID *processes, int count,
                            char *error, int error_capacity);
bool nr_pipeline_start_microphone(NRPipeline *, AudioDeviceID, char *error, int error_capacity);
void nr_pipeline_set_bypass(NRPipeline *, bool);
void nr_pipeline_set_leveling(NRPipeline *, bool);
void nr_pipeline_set_strength(NRPipeline *, float);
NRStats nr_pipeline_stats(NRPipeline *);
// Stops capture/tap first (restoring the original app), output second, worker last.
void nr_pipeline_destroy(NRPipeline *);

// Test-only entry point for the same bounded SPSC queue used by audio callbacks.
bool nr_ring_self_test(void);
#ifdef __cplusplus
}
#endif
