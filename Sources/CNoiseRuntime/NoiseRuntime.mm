#import <Foundation/Foundation.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#include <AudioToolbox/AudioToolbox.h>
#include "NoiseRuntime.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {
constexpr size_t blockSize = 480;
constexpr size_t ringCapacity = 65536;
constexpr size_t outputPrefill = 1440;

void report(char *out, int cap, const std::string &message) {
    if (out && cap > 0) { snprintf(out, size_t(cap), "%s", message.c_str()); }
}
void check(OSStatus status, const char *operation) {
    if (status != noErr) {
        throw std::runtime_error(std::string(operation) + " (Core Audio " + std::to_string(status) + ")");
    }
}
// One producer and one consumer. Neither side ever changes the other's cursor.
// An overloaded producer drops the NEW block; it never overwrites a live read.
class Ring {
    std::array<float, ringCapacity> data{};
    alignas(64) std::atomic<uint64_t> readCursor{0};
    alignas(64) std::atomic<uint64_t> writeCursor{0};
public:
    size_t available() const {
        return size_t(writeCursor.load(std::memory_order_acquire) - readCursor.load(std::memory_order_acquire));
    }
    bool push(const float *input, size_t count) {
        const uint64_t w = writeCursor.load(std::memory_order_relaxed);
        const uint64_t r = readCursor.load(std::memory_order_acquire);
        if (count > ringCapacity - (w - r)) return false;
        for (size_t i = 0; i < count; ++i) data[(w + i) & (ringCapacity - 1)] = input[i];
        writeCursor.store(w + count, std::memory_order_release);
        return true;
    }
    size_t pop(float *output, size_t count) {
        const uint64_t r = readCursor.load(std::memory_order_relaxed);
        const uint64_t w = writeCursor.load(std::memory_order_acquire);
        count = std::min(count, size_t(w - r));
        for (size_t i = 0; i < count; ++i) output[i] = data[(r + i) & (ringCapacity - 1)];
        readCursor.store(r + count, std::memory_order_release);
        return count;
    }
    // Only the consumer calls these two methods; used for gradual clock-drift correction.
    float peek(size_t offset) const {
        return data[(readCursor.load(std::memory_order_relaxed) + offset) & (ringCapacity - 1)];
    }
    void consume(size_t count) {
        readCursor.store(readCursor.load(std::memory_order_relaxed) + count, std::memory_order_release);
    }
};

AudioStreamBasicDescription floatFormat(double rate, UInt32 channels) {
    AudioStreamBasicDescription f{};
    f.mSampleRate = rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = f.mBytesPerFrame = UInt32(sizeof(float)) * channels;
    f.mFramesPerPacket = 1;
    f.mChannelsPerFrame = channels;
    f.mBitsPerChannel = 32;
    return f;
}
AudioUnit newHALUnit() {
    AudioComponentDescription d{};
    d.componentType = kAudioUnitType_Output;
    d.componentSubType = kAudioUnitSubType_HALOutput;
    d.componentManufacturer = kAudioUnitManufacturer_Apple;
    auto component = AudioComponentFindNext(nullptr, &d);
    if (!component) throw std::runtime_error("The macOS audio component is unavailable.");
    AudioUnit unit = nullptr;
    check(AudioComponentInstanceNew(component, &unit), "Create audio unit");
    return unit;
}
}

struct NRPipeline {
    std::unique_ptr<NRProcessor, decltype(&nr_processor_destroy)> processor{nullptr, nr_processor_destroy};
    Ring input, output;
    std::atomic<bool> stopped{false}, bypass{false}, failed{false};
    std::atomic<bool> leveling{true};
    std::atomic<float> strength{1};
    std::atomic<double> inputRate{48000.0};
    std::atomic<float> inputPeak{0}, outputPeak{0}, processingMs{0};
    std::atomic<float> voiceGainDB{0};
    std::atomic<uint64_t> inputFrames{0}, underrunFrames{0}, droppedFrames{0};
    std::thread worker;
    AudioUnit outputUnit = nullptr, inputUnit = nullptr;
    AudioObjectID tap = kAudioObjectUnknown, aggregate = kAudioObjectUnknown;
    AudioDeviceIOProcID tapProc = nullptr;
    AudioStreamBasicDescription tapFormat{};
    std::vector<float> microphoneBuffer;
    AudioBufferList microphoneABL{};
    UInt32 microphoneChannels = 0;
    bool playing = false;
    double outputFraction = 0;

    NRPipeline(int engine, const char *libraries, const char *models) {
        char error[1024]{};
        processor.reset(nr_processor_create(engine, libraries, models, error, sizeof(error)));
        if (!processor) throw std::runtime_error(error);
        worker = std::thread([this] { work(); });
    }
    ~NRPipeline() {
        // A mutedWhenTapped process is restored before any output/worker teardown.
        if (tapProc) { AudioDeviceStop(aggregate, tapProc); AudioDeviceDestroyIOProcID(aggregate, tapProc); }
        if (aggregate) AudioHardwareDestroyAggregateDevice(aggregate);
        if (tap) AudioHardwareDestroyProcessTap(tap);
        if (inputUnit) { AudioOutputUnitStop(inputUnit); AudioUnitUninitialize(inputUnit); AudioComponentInstanceDispose(inputUnit); }
        if (outputUnit) { AudioOutputUnitStop(outputUnit); AudioUnitUninitialize(outputUnit); AudioComponentInstanceDispose(outputUnit); }
        stopped.store(true);
        if (worker.joinable()) worker.join();
    }
    void capture(const AudioBufferList *buffers) {
        // Fixed scratch storage; no allocation, locks or model inference on an IO callback.
        std::array<float, 2048> mono;
        if (!buffers || buffers->mNumberBuffers == 0) return;
        const auto &first = buffers->mBuffers[0];
        if (!first.mData || first.mNumberChannels == 0) return;
        const size_t frames = first.mDataByteSize / (sizeof(float) * first.mNumberChannels);
        float peak = 0;
        for (size_t offset = 0; offset < frames; offset += mono.size()) {
            const size_t n = std::min(mono.size(), frames - offset);
            for (size_t i = 0; i < n; ++i) {
                float total = 0; unsigned channels = 0;
                for (UInt32 b = 0; b < buffers->mNumberBuffers; ++b) {
                    const auto &buffer = buffers->mBuffers[b];
                    if (!buffer.mData || buffer.mNumberChannels == 0) continue;
                    const size_t validFrames = buffer.mDataByteSize / (sizeof(float) * buffer.mNumberChannels);
                    if (offset + i >= validFrames) continue;
                    const auto *data = static_cast<const float *>(buffer.mData);
                    for (UInt32 c = 0; c < buffer.mNumberChannels; ++c) {
                        const float sample = data[(offset + i) * buffer.mNumberChannels + c];
                        total += std::isfinite(sample) ? sample : 0;
                        ++channels;
                    }
                }
                mono[i] = channels ? total / float(channels) : 0;
                peak = std::max(peak, std::abs(mono[i]));
            }
            if (!input.push(mono.data(), n)) { droppedFrames.fetch_add(n); failed.store(true); }
        }
        inputPeak.store(peak, std::memory_order_relaxed);
        inputFrames.fetch_add(frames, std::memory_order_relaxed);
    }
    void work() {
        @autoreleasepool {
            std::array<float, 2048> source;
            std::array<float, blockSize> frame{}, clean{};
            size_t fill = 0;
            double previousIndex = 0, nextOutputIndex = 0;
            float previous = 0;
            bool hasPrevious = false;
            while (!stopped.load()) {
                const auto n = input.pop(source.data(), source.size());
                if (!n) { std::this_thread::sleep_for(std::chrono::microseconds(750)); continue; }
                // A bounded queue must not turn an overloaded model into seconds of call delay.
                if (input.available() > 24000) { failed.store(true); continue; }
                const double step = inputRate.load() / 48000.0;
                for (size_t i = 0; i < n; ++i) {
                    const float current = source[i];
                    if (!hasPrevious) { previous = current; hasPrevious = true; }
                    while (nextOutputIndex <= previousIndex) {
                        const double fraction = std::clamp(nextOutputIndex - (previousIndex - 1), 0.0, 1.0);
                        frame[fill++] = previous + float(fraction) * (current - previous);
                        nextOutputIndex += step;
                        if (fill == blockSize) {
                            const auto begin = std::chrono::steady_clock::now();
                            bool ok = false;
                            nr_processor_set_strength(processor.get(), strength.load());
                            try { ok = nr_processor_process(processor.get(), frame.data(), clean.data(), leveling.load(), bypass.load()); } catch (...) { ok = false; }
                            const float elapsed = std::chrono::duration<float, std::milli>(std::chrono::steady_clock::now() - begin).count();
                            processingMs.store(processingMs.load() * .90f + elapsed * .10f);
                            if (!ok) { failed.store(true); clean.fill(0); }
                            voiceGainDB.store(nr_processor_gain_db(processor.get()));
                            float peak = 0;
                            for (float sample : clean) peak = std::max(peak, std::abs(sample));
                            outputPeak.store(peak);
                            if (!output.push(clean.data(), clean.size())) { droppedFrames.fetch_add(clean.size()); failed.store(true); }
                            fill = 0;
                        }
                    }
                    previous = current;
                    previousIndex += 1;
                }
            }
        }
    }
    void render(UInt32 frames, AudioBufferList *buffers) {
        const size_t ready = output.available();
        if (!playing && ready >= outputPrefill) playing = true;
        // Gentle correction for two physical audio devices with slightly different clocks.
        const double ratio = std::clamp(1.0 + (double(ready) - outputPrefill) * 0.00000025, 0.999, 1.001);
        for (UInt32 i = 0; i < frames; ++i) {
            float sample = 0;
            if (playing && output.available() >= 2) {
                sample = output.peek(0) + float(outputFraction) * (output.peek(1) - output.peek(0));
                outputFraction += ratio;
                const auto advance = size_t(outputFraction);
                if (advance) { output.consume(advance); outputFraction -= double(advance); }
            } else if (playing) {
                underrunFrames.fetch_add(1, std::memory_order_relaxed);
                playing = false; outputFraction = 0;
            }
            for (UInt32 b = 0; b < buffers->mNumberBuffers; ++b) {
                auto &buffer = buffers->mBuffers[b];
                if (!buffer.mData) continue;
                const auto count = buffer.mDataByteSize / sizeof(float);
                auto *destination = static_cast<float *>(buffer.mData);
                for (UInt32 c = 0; c < buffer.mNumberChannels; ++c) {
                    const size_t index = size_t(i) * buffer.mNumberChannels + c;
                    if (index < count) destination[index] = sample;
                }
            }
        }
    }
};

namespace {
OSStatus renderCallback(void *context, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32,
                        UInt32 frames, AudioBufferList *buffers) {
    static_cast<NRPipeline *>(context)->render(frames, buffers);
    return noErr;
}
OSStatus microphoneCallback(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                            UInt32, UInt32 frames, AudioBufferList *) {
    auto *p = static_cast<NRPipeline *>(context);
    if (size_t(frames) * p->microphoneChannels > p->microphoneBuffer.size()) {
        p->failed.store(true); return noErr;
    }
    p->microphoneABL.mBuffers[0].mDataByteSize = frames * p->microphoneChannels * sizeof(float);
    const auto status = AudioUnitRender(p->inputUnit, flags, time, 1, frames, &p->microphoneABL);
    if (status == noErr) p->capture(&p->microphoneABL); else p->failed.store(true);
    return noErr;
}
OSStatus tapCallback(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *input,
                     const AudioTimeStamp *, AudioBufferList *, const AudioTimeStamp *, void *context) {
    static_cast<NRPipeline *>(context)->capture(input);
    return noErr;
}
}

extern "C" {
NRPipeline *nr_pipeline_create(int engine, const char *libraries, const char *models, char *error, int capacity) {
    try { return new NRPipeline(engine, libraries, models); }
    catch (const std::exception &e) { report(error, capacity, e.what()); return nullptr; }
}
bool nr_pipeline_start_output(NRPipeline *p, AudioDeviceID device, char *error, int capacity) {
    if (!p) return false;
    try {
        p->outputUnit = newHALUnit();
        check(AudioUnitSetProperty(p->outputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, sizeof(device)), "Select listening device");
        auto format = floatFormat(48000, 2);
        check(AudioUnitSetProperty(p->outputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format)), "Set playback format");
        AURenderCallbackStruct callback{renderCallback, p};
        check(AudioUnitSetProperty(p->outputUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)), "Set playback callback");
        check(AudioUnitInitialize(p->outputUnit), "Initialize playback");
        check(AudioOutputUnitStart(p->outputUnit), "Start playback");
        return true;
    } catch (const std::exception &e) { report(error, capacity, e.what()); return false; }
}
bool nr_pipeline_start_apps(NRPipeline *p, const AudioObjectID *processes, int count,
                            char *error, int capacity) {
    if (!p) return false;
    if (count < 0 || (count > 0 && !processes)) {
        report(error, capacity, "The selected application list is invalid."); return false;
    }
    @autoreleasepool {
        try {
            if (count == 0) {
                report(error, capacity, "Start audio in at least one selected application first."); return false;
            }
            NSMutableArray<NSNumber *> *ids = [NSMutableArray array];
            for (int i = 0; i < count; ++i) [ids addObject:@(processes[i])];
            CATapDescription *description = [[CATapDescription alloc] initMonoMixdownOfProcesses:ids];
            description.name = @"Noise · selected apps";
            description.exclusive = NO;
            description.privateTap = YES;
            description.muteBehavior = CATapMutedWhenTapped;
            if (@available(macOS 26.0, *)) {
                description.processRestoreEnabled = YES;
            }
            check(AudioHardwareCreateProcessTap(description, &p->tap), "Allow system audio recording in Privacy & Security");
            AudioObjectPropertyAddress address{kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            UInt32 size = sizeof(p->tapFormat);
            check(AudioObjectGetPropertyData(p->tap, &address, 0, nullptr, &size, &p->tapFormat), "Read call audio format");
            if (p->tapFormat.mFormatID != kAudioFormatLinearPCM || !(p->tapFormat.mFormatFlags & kAudioFormatFlagIsFloat) || p->tapFormat.mBitsPerChannel != 32)
                throw std::runtime_error("This call app returned an unsupported audio format.");
            p->inputRate.store(p->tapFormat.mSampleRate);
            NSDictionary *config = @{
                @kAudioAggregateDeviceNameKey: @"Noise private call route",
                @kAudioAggregateDeviceUIDKey: NSUUID.UUID.UUIDString,
                @kAudioAggregateDeviceIsPrivateKey: @YES,
                @kAudioAggregateDeviceTapAutoStartKey: @NO,
                @kAudioAggregateDeviceTapListKey: @[@{
                    @kAudioSubTapUIDKey: description.UUID.UUIDString,
                    @kAudioSubTapDriftCompensationKey: @YES
                }]
            };
            check(AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)config, &p->aggregate), "Create private call route");
            check(AudioDeviceCreateIOProcID(p->aggregate, tapCallback, p, &p->tapProc), "Connect call audio");
            check(AudioDeviceStart(p->aggregate, p->tapProc), "Start incoming filtering");
            return true;
        } catch (const std::exception &e) { report(error, capacity, e.what()); return false; }
    }
}
bool nr_pipeline_start_microphone(NRPipeline *p, AudioDeviceID device, char *error, int capacity) {
    if (!p) return false;
    try {
        p->inputUnit = newHALUnit();
        UInt32 on = 1, off = 0;
        check(AudioUnitSetProperty(p->inputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, sizeof(on)), "Enable microphone");
        check(AudioUnitSetProperty(p->inputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, sizeof(off)), "Disable microphone playback");
        check(AudioUnitSetProperty(p->inputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, sizeof(device)), "Select microphone");
        AudioStreamBasicDescription hardware{};
        UInt32 size = sizeof(hardware);
        check(AudioUnitGetProperty(p->inputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &hardware, &size), "Read microphone format");
        if (!hardware.mChannelsPerFrame || hardware.mChannelsPerFrame > 32 || hardware.mSampleRate < 8000)
            throw std::runtime_error("The microphone format is unsupported.");
        p->inputRate.store(hardware.mSampleRate);
        p->microphoneChannels = hardware.mChannelsPerFrame;
        const auto format = floatFormat(hardware.mSampleRate, hardware.mChannelsPerFrame);
        check(AudioUnitSetProperty(p->inputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, sizeof(format)), "Set microphone format");
        UInt32 maxFrames = 16384;
        check(AudioUnitSetProperty(p->inputUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, sizeof(maxFrames)), "Set capture buffer");
        p->microphoneBuffer.resize(size_t(maxFrames) * hardware.mChannelsPerFrame);
        p->microphoneABL.mNumberBuffers = 1;
        p->microphoneABL.mBuffers[0] = {hardware.mChannelsPerFrame, UInt32(p->microphoneBuffer.size() * sizeof(float)), p->microphoneBuffer.data()};
        AURenderCallbackStruct callback{microphoneCallback, p};
        check(AudioUnitSetProperty(p->inputUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, sizeof(callback)), "Set microphone callback");
        check(AudioUnitInitialize(p->inputUnit), "Initialize microphone");
        check(AudioOutputUnitStart(p->inputUnit), "Start outgoing filtering");
        return true;
    } catch (const std::exception &e) { report(error, capacity, e.what()); return false; }
}
void nr_pipeline_set_bypass(NRPipeline *p, bool bypass) { if (p) p->bypass.store(bypass); }
void nr_pipeline_set_leveling(NRPipeline *p, bool enabled) { if (p) p->leveling.store(enabled); }
void nr_pipeline_set_strength(NRPipeline *p, float value) {
    if (p) p->strength.store(std::isfinite(value) ? std::clamp(value, 0.f, 1.f) : 1.f);
}
NRStats nr_pipeline_stats(NRPipeline *p) {
    if (!p) return {};
    return {p->inputPeak.load(), p->outputPeak.load(), p->processingMs.load(), p->inputFrames.load(),
            p->underrunFrames.load(), p->droppedFrames.load(), p->failed.load() ? 1 : 0, p->voiceGainDB.load()};
}
void nr_pipeline_destroy(NRPipeline *p) { delete p; }
bool nr_ring_self_test() {
    Ring ring;
    std::vector<float> in(ringCapacity), out(ringCapacity);
    for (size_t i = 0; i < in.size(); ++i) in[i] = float(i);
    for (int pass = 0; pass < 3; ++pass) {
        if (!ring.push(in.data(), in.size()) || ring.push(in.data(), 1)) return false;
        if (ring.pop(out.data(), 333) != 333 || ring.pop(out.data() + 333, in.size() - 333) != in.size() - 333) return false;
        if (in != out || ring.available() != 0) return false;
    }
    auto concurrent = std::make_unique<Ring>();
    std::atomic<bool> bad{false};
    constexpr size_t total = 200003;
    std::thread producer([&] {
        std::array<float, 127> chunk;
        for (size_t offset = 0; offset < total;) {
            const size_t n = std::min(chunk.size(), total - offset);
            for (size_t i = 0; i < n; ++i) chunk[i] = float(offset + i);
            while (!concurrent->push(chunk.data(), n)) {
                if (bad.load()) return;
                std::this_thread::yield();
            }
            offset += n;
        }
    });
    std::array<float, 311> chunk;
    for (size_t offset = 0; offset < total;) {
        const size_t n = concurrent->pop(chunk.data(), chunk.size());
        if (!n) { std::this_thread::yield(); continue; }
        for (size_t i = 0; i < n; ++i) if (chunk[i] != float(offset + i)) bad.store(true);
        if (bad.load()) break;
        offset += n;
    }
    producer.join();
    if (bad.load()) return false;
    return true;
}
}
