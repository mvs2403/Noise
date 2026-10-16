#include "NoiseRuntime.h"
#include <pulse/pulseaudio.h>
#include <sys/prctl.h>
#include <poll.h>
#include <unistd.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cmath>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>

namespace {
class Ring {
    std::array<float, 16384> data{};
    std::atomic<uint64_t> read{0}, write{0};
public:
    size_t count() const { return write.load(std::memory_order_acquire) - read.load(std::memory_order_acquire); }
    bool push(const float *input, size_t n) {
        auto w = write.load(std::memory_order_relaxed);
        if (n > data.size() - (w - read.load(std::memory_order_acquire))) return false;
        for (size_t i = 0; i < n; ++i) data[(w+i)&16383] = input ? input[i] : 0;
        write.store(w+n, std::memory_order_release); return true;
    }
    size_t pop(float *out, size_t n) {
        auto r = read.load(std::memory_order_relaxed);
        n = std::min(n, size_t(write.load(std::memory_order_acquire)-r));
        for (size_t i = 0; i < n; ++i) out[i] = data[(r+i)&16383];
        read.store(r+n, std::memory_order_release); return n;
    }
};
struct Pulse {
    pa_threaded_mainloop *loop = nullptr;
    pa_context *context = nullptr;
    pa_stream *capture = nullptr, *playback = nullptr;
    Ring input, output;
    std::atomic<bool> failed{false};
    static void contextState(pa_context *c, void *opaque) {
        auto p = static_cast<Pulse *>(opaque);
        if (!PA_CONTEXT_IS_GOOD(pa_context_get_state(c))) p->failed.store(true);
        pa_threaded_mainloop_signal(p->loop, 0);
    }
    static void streamState(pa_stream *s, void *opaque) {
        auto p = static_cast<Pulse *>(opaque);
        if (!PA_STREAM_IS_GOOD(pa_stream_get_state(s))) p->failed.store(true);
        pa_threaded_mainloop_signal(p->loop, 0);
    }
    static void record(pa_stream *s, size_t, void *opaque) {
        auto p = static_cast<Pulse *>(opaque);
        const void *data = nullptr; size_t bytes = 0;
        if (pa_stream_peek(s, &data, &bytes) < 0) { p->failed.store(true); return; }
        if (bytes) {
            if (bytes % sizeof(float) || !p->input.push(static_cast<const float *>(data), bytes/sizeof(float))) p->failed.store(true);
            pa_stream_drop(s);
        }
    }
    static void render(pa_stream *s, size_t bytes, void *opaque) {
        auto p = static_cast<Pulse *>(opaque);
        std::array<float, 480> block{};
        while (bytes >= sizeof(float)) {
            size_t n = std::min(block.size(), bytes/sizeof(float));
            auto got = p->output.pop(block.data(), n);
            std::fill(block.begin()+got, block.begin()+n, 0.f);
            if (pa_stream_write(s, block.data(), n*sizeof(float), nullptr, 0, PA_SEEK_RELATIVE) < 0) p->failed.store(true);
            bytes -= n*sizeof(float);
        }
    }
    void start(const std::string &source, const std::string &sink, const std::string &owner) {
        loop = pa_threaded_mainloop_new();
        if (!loop) throw std::runtime_error("Could not create the audio loop.");
        auto props = pa_proplist_new();
        pa_proplist_sets(props, PA_PROP_APPLICATION_NAME, "Noise");
        pa_proplist_sets(props, "noise.owner", owner.c_str());
        context = pa_context_new_with_proplist(pa_threaded_mainloop_get_api(loop), "Noise", props);
        pa_proplist_free(props);
        if (!context || pa_threaded_mainloop_start(loop) < 0) throw std::runtime_error("Could not connect to the audio server.");
        pa_threaded_mainloop_lock(loop);
        pa_context_set_state_callback(context, contextState, this);
        if (pa_context_connect(context, nullptr, PA_CONTEXT_NOAUTOSPAWN, nullptr) < 0) {
            pa_threaded_mainloop_unlock(loop); throw std::runtime_error("Start PipeWire-Pulse or PulseAudio before turning filtering on.");
        }
        while (pa_context_get_state(context) != PA_CONTEXT_READY && !failed.load()) pa_threaded_mainloop_wait(loop);
        if (failed.load()) { pa_threaded_mainloop_unlock(loop); throw std::runtime_error("The audio server is unavailable."); }
        pa_sample_spec spec{PA_SAMPLE_FLOAT32LE, 48000, 1};
        props = pa_proplist_new();
        pa_proplist_sets(props, "noise.owner", owner.c_str());
        pa_proplist_sets(props, PA_PROP_MEDIA_ROLE, "communication");
        capture = pa_stream_new_with_proplist(context, "Noise capture", &spec, nullptr, props);
        playback = pa_stream_new_with_proplist(context, "Noise processed audio", &spec, nullptr, props);
        pa_proplist_free(props);
        if (!capture || !playback) { pa_threaded_mainloop_unlock(loop); throw std::runtime_error("Could not create audio streams."); }
        pa_stream_set_state_callback(capture, streamState, this);
        pa_stream_set_state_callback(playback, streamState, this);
        pa_stream_set_read_callback(capture, record, this);
        pa_stream_set_write_callback(playback, render, this);
        pa_buffer_attr buffer{48000, 7680, 3840, 1920, 1920}; // bytes: 250/40/20/10/10 ms
        auto common = pa_stream_flags_t(PA_STREAM_ADJUST_LATENCY | PA_STREAM_DONT_MOVE);
        if (pa_stream_connect_record(capture, source.c_str(), &buffer, common) < 0 ||
            pa_stream_connect_playback(playback, sink.c_str(), &buffer,
                pa_stream_flags_t(common | PA_STREAM_START_CORKED), nullptr, nullptr) < 0) failed.store(true);
        while (!failed.load() && (pa_stream_get_state(capture) != PA_STREAM_READY || pa_stream_get_state(playback) != PA_STREAM_READY))
            pa_threaded_mainloop_wait(loop);
        pa_threaded_mainloop_unlock(loop);
        if (failed.load()) throw std::runtime_error("The selected audio device is unavailable.");
    }
    void play() {
        pa_threaded_mainloop_lock(loop);
        if (auto op = pa_stream_cork(playback, 0, nullptr, nullptr)) pa_operation_unref(op);
        else failed.store(true);
        pa_threaded_mainloop_unlock(loop);
    }
    ~Pulse() {
        if (loop) {
            pa_threaded_mainloop_lock(loop);
            if (capture) { pa_stream_disconnect(capture); pa_stream_unref(capture); }
            if (playback) { pa_stream_disconnect(playback); pa_stream_unref(playback); }
            if (context) { pa_context_disconnect(context); pa_context_unref(context); }
            pa_threaded_mainloop_unlock(loop);
            pa_threaded_mainloop_stop(loop); pa_threaded_mainloop_free(loop);
        }
    }
};
}

int main(int argc, char **argv) {
    auto parent = getppid(); prctl(PR_SET_PDEATHSIG, SIGKILL);
    if (parent == 1 || getppid() != parent) return 1;
    try {
        std::unordered_map<std::string, std::string> args;
        for (int i = 1; i+1 < argc; i += 2) args[argv[i]] = argv[i+1];
        char error[2048]{};
        std::unique_ptr<NRProcessor, decltype(&nr_processor_destroy)> processor(
            nr_processor_create(std::stoi(args.at("--engine")), args.at("--libraries").c_str(),
                args.at("--models").c_str(), error, sizeof(error)), nr_processor_destroy);
        if (!processor) throw std::runtime_error(error);
        bool enabled = args.at("--enabled") == "1", leveling = args.at("--leveling") == "1";
        float strength = std::stof(args.at("--strength"));
        Pulse audio; audio.start(args.at("--input"), args.at("--output"), args.at("--owner"));
        std::array<float, 481> source{}; std::array<float, 480> frame{}, clean{};
        std::string commands; uint64_t frames = 0; double inPower = 0, outPower = 0;
        bool playing = false, stopping = false;
        while (!stopping) {
            pollfd control{STDIN_FILENO, POLLIN, 0};
            if (poll(&control, 1, 0) > 0) {
                char text[1024]; auto n = read(STDIN_FILENO, text, sizeof(text));
                if (n <= 0) break;
                commands.append(text, size_t(n));
                size_t end;
                while ((end = commands.find('\n')) != std::string::npos) {
                    auto line = commands.substr(0, end); commands.erase(0, end+1);
                    if (line == "quit") stopping = true;
                    else if (line.rfind("enabled ", 0) == 0) enabled = line.substr(8) == "1";
                    else if (line.rfind("leveling ", 0) == 0) leveling = line.substr(9) == "1";
                    else if (line.rfind("strength ", 0) == 0) strength = std::clamp(std::stof(line.substr(9)), 0.f, 1.f);
                }
            }
            if (audio.failed.load()) throw std::runtime_error("The audio server or selected device stopped. Restart this route.");
            if (audio.input.count() > 12000) throw std::runtime_error("Audio processing fell behind. Choose a faster engine, such as RNNoise.");
            if (audio.output.count() >= 1440 || audio.input.count() == 0) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1)); continue;
            }
            auto n = audio.input.pop(source.data(), audio.input.count() > 2880 ? 481 : 480);
            for (int i = 0; i < 480; ++i) {
                float at = float(i) * float(n-1) / 479; size_t left = size_t(at);
                frame[i] = std::clamp(source[left] + (source[std::min(left+1, n-1)] - source[left]) * (at-left), -1.f, 1.f);
            }
            nr_processor_set_strength(processor.get(), strength);
            if (!nr_processor_process(processor.get(), frame.data(), clean.data(), enabled && leveling, !enabled))
                throw std::runtime_error("The audio filter stopped. Restart this route.");
            if (!audio.output.push(clean.data(), clean.size())) throw std::runtime_error("Playback fell behind.");
            for (int i = 0; i < 480; ++i) { inPower += frame[i]*frame[i]; outPower += clean[i]*clean[i]; }
            if (!playing && audio.output.count() >= 1440) { audio.play(); playing = true; std::cout << "READY" << std::endl; }
            if (++frames % 100 == 0) {
                std::cout << "STAT " << frames << " " << std::sqrt(inPower/48000) << " " << std::sqrt(outPower/48000) << std::endl;
                inPower = outPower = 0;
            }
        }
        return 0;
    } catch (const std::exception &e) { std::cout << "ERROR " << e.what() << std::endl; return 1; }
}
