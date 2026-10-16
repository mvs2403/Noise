#include "MainSpeakerDenoiser.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include "DynamicLibrary.h"
using noise::symbol;
#include <stdexcept>
#include <string>

namespace {
// A streaming Blackman-windowed low-pass, with a duplicated history to avoid
// modulo arithmetic in the dot product. No per-frame allocation or sample drift.
class LowPass {
    static constexpr int taps = 193;
    std::array<float, taps> weights{};
    std::array<float, taps * 2> history{};
    int cursor = 0, last = 0;
public:
    LowPass() {
        constexpr double pi = 3.14159265358979323846, cutoff = 7000.0 / 48000;
        double total = 0;
        for (int i = 0; i < taps; ++i) {
            const int n = i - (taps - 1) / 2;
            const double sinc = n == 0 ? 2 * cutoff : std::sin(2 * pi * cutoff * n) / (pi * n);
            const double window = .42 - .5 * std::cos(2 * pi * i / (taps - 1)) + .08 * std::cos(4 * pi * i / (taps - 1));
            weights[i] = float(sinc * window); total += weights[i];
        }
        for (auto &w : weights) w /= float(total);
    }
    void feed(float value) {
        history[cursor] = history[cursor + taps] = value;
        last = cursor;
        if (++cursor == taps) cursor = 0;
    }
    float value() const {
        const float *p = history.data() + last + taps;
        float result = 0;
        for (int i = 0; i < taps; ++i) result += weights[i] * p[-i];
        return result;
    }
};
}

struct MainSpeakerDenoiser::Impl {
    void *library = nullptr, *model = nullptr, *session = nullptr;
    void (*freeModel)(void *) = nullptr;
    void (*freeSession)(void *) = nullptr;
    float (*run)(void *, const float *, float *) = nullptr;
    LowPass down, up;

    Impl(const char *libraries, const char *models) {
        try {
            const auto libraryPath = std::string(libraries) + "/" NR_LIBRARY("weya_nc");
            try { library = noise::openLibrary(libraryPath); }
            catch (...) { throw std::runtime_error("The automatic main-speaker runtime is missing or cannot load. Rebuild Noise to install it."); }
            if (!library) throw std::runtime_error("The automatic main-speaker runtime is missing. Rebuild Noise to install it.");
            auto load = symbol<void *(*)(const char *)>(library, "weya_nc_model_load_from_path");
            auto create = symbol<void *(*)(const void *, size_t, float)>(library, "weya_nc_session_create");
            auto frameLength = symbol<size_t (*)(const void *)>(library, "weya_nc_get_frame_length");
            freeModel = symbol<decltype(freeModel)>(library, "weya_nc_model_free");
            freeSession = symbol<decltype(freeSession)>(library, "weya_nc_session_free");
            run = symbol<decltype(run)>(library, "weya_nc_process_frame");
            const auto path = std::string(models) + "/hush-main-speaker.tar.gz";
            if (!std::filesystem::exists(std::filesystem::u8path(path))) throw std::runtime_error("The automatic main-speaker model is missing. Rebuild Noise to install it.");
            model = load(path.c_str());
            if (!model) throw std::runtime_error("The automatic main-speaker model could not load.");
            session = create(model, 16000, 100.f);
            if (!session || frameLength(session) != 160) throw std::runtime_error("The main-speaker model returned an unsupported frame size.");
        } catch (...) { close(); throw; }
    }
    void close() {
        if (session && freeSession) freeSession(session);
        if (model && freeModel) freeModel(model);
        if (library) noise::closeLibrary(library);
        session = model = library = nullptr;
    }
    ~Impl() { close(); }
    bool process(const float *input, float *output) {
        std::array<float, 160> narrow{}, cleaned{};
        for (int i = 0; i < 480; ++i) {
            down.feed(input[i]);
            if (i % 3 == 2) narrow[i / 3] = down.value();
        }
        const float snr = run(session, narrow.data(), cleaned.data());
        // The C API reports inference errors with -100 and otherwise returns
        // the model's local SNR. Do not silently emit its error passthrough.
        if (!std::isfinite(snr) || snr < -90) return false;
        for (int i = 0; i < 480; ++i) {
            up.feed(i % 3 == 0 ? cleaned[i / 3] * 3.f : 0.f);
            output[i] = up.value();
        }
        return true;
    }
};

MainSpeakerDenoiser::MainSpeakerDenoiser(const char *libraries, const char *models)
    : impl(std::make_unique<Impl>(libraries, models)) {}
MainSpeakerDenoiser::~MainSpeakerDenoiser() = default;
bool MainSpeakerDenoiser::process(const float *input, float *output) { return impl->process(input, output); }
