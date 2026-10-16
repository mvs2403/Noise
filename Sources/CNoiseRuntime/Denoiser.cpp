#include "NoiseRuntime.h"
#include "SherpaAPI.h"
#include "MainSpeakerDenoiser.h"
#include "DynamicLibrary.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <deque>
#include <memory>
#include <string>
using noise::openLibrary;
using noise::symbol;
namespace {
constexpr size_t blockSize = 480;
void report(char *out, int cap, const std::string &message) {
    if (out && cap > 0) snprintf(out, size_t(cap), "%s", message.c_str());
}
}

struct NRDenoiser {
    int kind;
    std::unique_ptr<MainSpeakerDenoiser> mainSpeaker;
    void *library = nullptr;
    void *state = nullptr;
    const SherpaOnnxOnlineSpeechDenoiser *sherpa = nullptr;
    decltype(&SherpaOnnxOnlineSpeechDenoiserRun) sherpaRun = nullptr;
    decltype(&SherpaOnnxDestroyDenoisedAudio) sherpaFreeAudio = nullptr;
    decltype(&SherpaOnnxDestroyOnlineSpeechDenoiser) sherpaDestroy = nullptr;
    float (*rnProcess)(void *, float *, const float *) = nullptr;
    void (*rnDestroy)(void *) = nullptr;
    float (*dfProcess)(void *, float *, float *) = nullptr;
    void (*dfDestroy)(void *) = nullptr;
    std::deque<float> pending;
    int emptyFrames = 0;
    float speechProbability = 0;

    NRDenoiser(int engine, const std::string &libraries, const std::string &models) : kind(engine) {
        try {
            if (kind == NR_MAIN_SPEAKER) {
                mainSpeaker = std::make_unique<MainSpeakerDenoiser>(libraries.c_str(), models.c_str());
            } else if (kind == NR_DPDFNET) {
                library = openLibrary(libraries + "/" NR_LIBRARY("sherpa-onnx-c-api"));
                auto create = symbol<decltype(&SherpaOnnxCreateOnlineSpeechDenoiser)>(library, "SherpaOnnxCreateOnlineSpeechDenoiser");
                sherpaRun = symbol<decltype(sherpaRun)>(library, "SherpaOnnxOnlineSpeechDenoiserRun");
                sherpaFreeAudio = symbol<decltype(sherpaFreeAudio)>(library, "SherpaOnnxDestroyDenoisedAudio");
                sherpaDestroy = symbol<decltype(sherpaDestroy)>(library, "SherpaOnnxDestroyOnlineSpeechDenoiser");
                SherpaOnnxOnlineSpeechDenoiserConfig config{};
                const auto path = models + "/dpdfnet2_48khz_hr.onnx";
                config.model.dpdfnet.model = path.c_str();
                config.model.num_threads = 1;
                config.model.provider = "cpu";
                if (!std::filesystem::exists(std::filesystem::u8path(path)))
                    throw std::runtime_error("DPDFNet model is missing. Reinstall Noise or rebuild its dependencies.");
                sherpa = create(&config);
                if (!sherpa) throw std::runtime_error("DPDFNet could not load its model.");
            } else if (kind == NR_DEEPFILTERNET) {
                library = openLibrary(libraries + "/" NR_LIBRARY("df"));
                auto create = symbol<void *(*)(const char *, float, const char *)>(library, "df_create");
                dfProcess = symbol<decltype(dfProcess)>(library, "df_process_frame");
                dfDestroy = symbol<decltype(dfDestroy)>(library, "df_free");
                auto frameLength = symbol<size_t (*)(void *)>(library, "df_get_frame_length");
                const auto path = models + "/DeepFilterNet3_onnx.tar.gz";
                if (!std::filesystem::exists(std::filesystem::u8path(path)))
                    throw std::runtime_error("DeepFilterNet3 model is missing. Reinstall Noise or rebuild its dependencies.");
                state = create(path.c_str(), 100.0f, nullptr);
                if (!state || frameLength(state) != blockSize)
                    throw std::runtime_error("DeepFilterNet3 returned an unsupported frame size.");
            } else if (kind == NR_RNNOISE) {
                library = openLibrary(libraries + "/" NR_LIBRARY("rnnoise"));
                auto create = symbol<void *(*)(void *)>(library, "rnnoise_create");
                rnProcess = symbol<decltype(rnProcess)>(library, "rnnoise_process_frame");
                rnDestroy = symbol<decltype(rnDestroy)>(library, "rnnoise_destroy");
                state = create(nullptr);
                if (!state) throw std::runtime_error("RNNoise could not initialize.");
            } else throw std::runtime_error("Unknown noise cancellation engine.");
        } catch (...) { close(); throw; }
    }
    void close() {
        if (sherpa && sherpaDestroy) sherpaDestroy(sherpa);
        if (state && kind == NR_DEEPFILTERNET && dfDestroy) dfDestroy(state);
        if (state && kind == NR_RNNOISE && rnDestroy) rnDestroy(state);
        state = nullptr; sherpa = nullptr;
        // dlopen is reference counted; release our reference after inference state is destroyed.
        if (library) noise::closeLibrary(library);
        library = nullptr;
    }
    ~NRDenoiser() { close(); }
    int delaySamples() const {
        if (kind == NR_MAIN_SPEAKER) return MainSpeakerDenoiser::delaySamples;
        return kind == NR_DPDFNET ? 2400 : kind == NR_DEEPFILTERNET ? 1440 : 960;
    }
    bool process(const float *input, float *output) {
        if (kind == NR_MAIN_SPEAKER) {
            if (!mainSpeaker->process(input, output)) return false;
        } else if (kind == NR_DPDFNET) {
            const auto *audio = sherpaRun(sherpa, input, int32_t(blockSize), 48000);
            // The streaming C API returns nullptr while its initial analysis window fills.
            if (!audio) {
                std::fill_n(output, blockSize, 0.0f);
                return ++emptyFrames <= 20;
            }
            emptyFrames = 0;
            if (audio->sample_rate != 48000 || audio->n < 0 || audio->n > 48000) {
                sherpaFreeAudio(audio); return false;
            }
            for (int32_t i = 0; i < audio->n; ++i) pending.push_back(audio->samples[i]);
            sherpaFreeAudio(audio);
            for (size_t i = 0; i < blockSize; ++i) {
                output[i] = pending.empty() ? 0.0f : pending.front();
                if (!pending.empty()) pending.pop_front();
            }
        } else if (kind == NR_DEEPFILTERNET) {
            std::array<float, blockSize> scratch;
            std::copy_n(input, blockSize, scratch.data());
            dfProcess(state, scratch.data(), output);
        } else {
            std::array<float, blockSize> scratch;
            for (size_t i = 0; i < blockSize; ++i) scratch[i] = input[i] * 32768.0f;
            speechProbability = rnProcess(state, output, scratch.data());
            for (size_t i = 0; i < blockSize; ++i) output[i] /= 32768.0f;
        }
        for (size_t i = 0; i < blockSize; ++i) {
            if (!std::isfinite(output[i])) return false;
            output[i] = std::clamp(output[i], -1.0f, 1.0f);
        }
        return true;
    }
};

// RNNoise's returned VAD probability is used only as a speech detector here.
// DPDFNet/DeepFilterNet output is never passed through a second denoiser.
struct SpeechDetector {
    void *library = nullptr;
    void *state = nullptr;
    float (*processFrame)(void *, float *, const float *) = nullptr;
    void (*destroyState)(void *) = nullptr;
    explicit SpeechDetector(const char *libraries) {
        try {
            library = openLibrary(std::string(libraries) + "/" NR_LIBRARY("rnnoise"));
            auto create = symbol<void *(*)(void *)>(library, "rnnoise_create");
            processFrame = symbol<decltype(processFrame)>(library, "rnnoise_process_frame");
            destroyState = symbol<decltype(destroyState)>(library, "rnnoise_destroy");
            state = create(nullptr);
            if (!state) throw std::runtime_error("The voice activity detector could not initialize.");
        } catch (...) { close(); throw; }
    }
    void close() {
        if (state && destroyState) destroyState(state);
        if (library) noise::closeLibrary(library);
        state = nullptr; library = nullptr;
    }
    ~SpeechDetector() { close(); }
    float probability(const float *input) {
        std::array<float, blockSize> scaled, ignored;
        for (size_t i = 0; i < blockSize; ++i) scaled[i] = input[i] * 32768.0f;
        return processFrame(state, ignored.data(), scaled.data());
    }
};

struct NRProcessor {
    std::unique_ptr<NRDenoiser> denoiser;
    std::unique_ptr<SpeechDetector> detector;
    std::unique_ptr<NRVoiceLeveler, decltype(&nr_voice_leveler_destroy)> leveler{nr_voice_leveler_create(), nr_voice_leveler_destroy};
    float gainDB = 0;
    std::deque<float> dry;
    float strength = 1, previousStrength = 1;
    NRProcessor(int engine, const char *libraries, const char *models) {
        if (!leveler) throw std::runtime_error("The voice leveler could not initialize.");
        denoiser = std::make_unique<NRDenoiser>(engine, libraries, models);
        if (engine != NR_RNNOISE) detector = std::make_unique<SpeechDetector>(libraries);
        dry.resize(denoiser->delaySamples(), 0.f);
    }
    bool process(const float *input, float *output, bool levelingEnabled, bool bypass) {
        if (!denoiser->process(input, output)) return false;
        float probability = detector ? detector->probability(input) : denoiser->speechProbability;
        for (size_t i = 0; i < blockSize; ++i) {
            dry.push_back(input[i]);
            const float aligned = dry.front(); dry.pop_front();
            const float mix = previousStrength + (strength - previousStrength) * float(i + 1) / float(blockSize);
            output[i] = aligned * (1 - mix) + output[i] * mix;
        }
        previousStrength = strength;
        nr_voice_leveler_process(leveler.get(), output, probability, levelingEnabled);
        gainDB = levelingEnabled && !bypass ? nr_voice_leveler_gain_db(leveler.get()) : 0;
        // Original bypasses every processing stage; keep model state warm.
        if (bypass) std::copy_n(input, blockSize, output);
        return true;
    }
};

extern "C" {
NRDenoiser *nr_denoiser_create(int engine, const char *libraries, const char *models, char *error, int capacity) {
    try { return new NRDenoiser(engine, libraries, models); }
    catch (const std::exception &e) { report(error, capacity, e.what()); return nullptr; }
}
bool nr_denoiser_process(NRDenoiser *p, const float *input, float *output) {
    if (!p || !input || !output) return false;
    try { return p->process(input, output); } catch (...) { return false; }
}
void nr_denoiser_destroy(NRDenoiser *p) { delete p; }
int nr_denoiser_delay_samples(NRDenoiser *p) { return p ? p->delaySamples() : 0; }
NRProcessor *nr_processor_create(int engine, const char *libraries, const char *models, char *error, int capacity) {
    try { return new NRProcessor(engine, libraries, models); }
    catch (const std::exception &e) { report(error, capacity, e.what()); return nullptr; }
}
bool nr_processor_process(NRProcessor *p, const float *input, float *output, bool levelingEnabled, bool bypass) {
    if (!p || !input || !output) return false;
    try { return p->process(input, output, levelingEnabled, bypass); } catch (...) { return false; }
}
float nr_processor_gain_db(NRProcessor *p) { return p ? p->gainDB : 0; }
void nr_processor_destroy(NRProcessor *p) { delete p; }
void nr_processor_set_strength(NRProcessor *p, float value) {
    if (p) p->strength = std::isfinite(value) ? std::clamp(value, 0.f, 1.f) : 1.f;
}
}
