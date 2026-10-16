#include "NoiseRuntime.h"
#include <algorithm>
#include <cmath>
#include <new>

// Control gain at a speech time scale; don't chase every syllable or boost silence.
// RNNoise supplies a speech probability from the pre-filter microphone/call signal.
struct NRVoiceLeveler {
    static constexpr int frames = 480;
    static constexpr float targetRMS = 0.10f;       // -20 dBFS RMS, not LUFS
    static constexpr float activityFloor = 0.001f; // -60 dBFS
    static constexpr float ceiling = 0.89125094f;  // -1 dBFS peak
    float speechGainDB = 0;
    float appliedGainDB = 0;
    float limiterGain = 1;
    float effectiveGainDB = 0;
    int speechHold = 0;

    static float linear(float db) { return std::pow(10.0f, db / 20.0f); }
    static float smoothing(float seconds) { return 1.0f - std::exp(-0.010f / seconds); }
    void reset() { speechGainDB = appliedGainDB = effectiveGainDB = 0; limiterGain = 1; speechHold = 0; }

    void process(float *samples, float probability, bool enabled) {
        // Off is a true pass-through, including when callers switch it on/off live.
        if (!enabled) { reset(); return; }
        float energy = 0, peak = 0;
        for (int i = 0; i < frames; ++i) {
            if (!std::isfinite(samples[i])) samples[i] = 0;
            energy += samples[i] * samples[i];
            peak = std::max(peak, std::abs(samples[i]));
        }
        const float rms = std::sqrt(energy / frames);
        const bool speech = std::isfinite(probability) && probability >= 0.45f && rms >= activityFloor;
        if (speech) speechHold = 20; // retain natural word endings for 200 ms
        else if (speechHold > 0) --speechHold;

        // Downward control always protects loud audio. Upward control needs speech.
        if (speech || rms > targetRMS) {
            const float desiredDB = std::clamp(20.0f * std::log10(targetRMS / std::max(rms, activityFloor)), -24.0f, 18.0f);
            const float coefficient = smoothing(desiredDB < speechGainDB ? 0.015f : 0.400f);
            speechGainDB += coefficient * (desiredDB - speechGainDB);
        }
        // Hold the learned speech gain during pauses, but stop applying positive boost.
        const float desiredAppliedDB = (speech || speechHold > 0) ? speechGainDB : std::min(speechGainDB, 0.0f);
        const float oldGain = linear(appliedGainDB);
        if (speech || rms > targetRMS) appliedGainDB = desiredAppliedDB;
        else appliedGainDB += smoothing(0.040f) * (desiredAppliedDB - appliedGainDB);
        const float newGain = linear(appliedGainDB);

        // The full 10 ms frame is already buffered. Check its largest possible peak
        // before applying the gain ramp, so even the first loud sample is protected.
        const float requiredLimiter = std::min(1.0f, ceiling / std::max(peak * std::max(oldGain, newGain), 1.0e-9f));
        if (requiredLimiter < limiterGain) limiterGain = requiredLimiter;
        else limiterGain += smoothing(0.080f) * (requiredLimiter - limiterGain);
        for (int i = 0; i < frames; ++i) {
            const float gain = oldGain + (newGain - oldGain) * float(i + 1) / frames;
            samples[i] = std::clamp(samples[i] * gain * limiterGain, -ceiling, ceiling);
        }
        effectiveGainDB = 20.0f * std::log10(std::max(newGain * limiterGain, 1.0e-9f));
    }
};

extern "C" {
NRVoiceLeveler *nr_voice_leveler_create() { return new (std::nothrow) NRVoiceLeveler(); }
void nr_voice_leveler_process(NRVoiceLeveler *leveler, float *samples, float probability, bool enabled) {
    if (leveler && samples) leveler->process(samples, probability, enabled);
}
float nr_voice_leveler_gain_db(NRVoiceLeveler *leveler) { return leveler ? leveler->effectiveGainDB : 0; }
void nr_voice_leveler_destroy(NRVoiceLeveler *leveler) { delete leveler; }
}
