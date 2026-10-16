#pragma once
#include <memory>

// Hush automatically enhances foreground speech without a reference voice.
// Models run at 16 kHz; stateful anti-alias filters bridge the 48 kHz pipeline.
class MainSpeakerDenoiser {
public:
    MainSpeakerDenoiser(const char *libraries, const char *models);
    ~MainSpeakerDenoiser();
    bool process(const float input[480], float output[480]);
    // Native 10 ms STFT delay plus two 193-tap FIRs and decimation phase.
    static constexpr int delaySamples = 670;
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
