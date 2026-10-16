using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Noise;

internal static class LinuxRoutingTest
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static async Task Until(Func<bool> predicate, LinuxAudio audio, string message)
    {
        for (int i = 0; i < 150; ++i)
        {
            audio.Update(); if (audio.PollError() is {} error) {
                foreach (var kind in new[] { "sinks", "sources", "sink-inputs", "source-outputs" })
                    Console.Error.WriteLine(kind + ": " + PulseCommand.Pactl("--format=json", "list", kind));
                throw new Exception(error);
            }
            if (predicate()) return; await Task.Delay(100);
        }
        foreach (var kind in new[] { "sinks", "sink-inputs" }) Console.Error.WriteLine(kind + ": " + PulseCommand.Pactl("--format=json", "list", kind));
        throw new Exception("Timed out: " + message);
    }
    private static string SinkOf(string app)
    {
        var stream = PulseCommand.List("sink-inputs").Single(e => PulseCommand.Prop(e, "application.id") == app);
        var index = PulseCommand.Text(stream, "sink");
        return PulseCommand.Text(PulseCommand.List("sinks").Single(e => PulseCommand.Text(e, "index") == index), "name");
    }
    public static int Run()
    {
        try { RunAsync().GetAwaiter().GetResult(); return 0; }
        catch (Exception e) { Console.Error.WriteLine(e); return 1; }
    }
    private static async Task RunAsync()
    {
        if (!OperatingSystem.IsLinux() || Environment.GetEnvironmentVariable("NOISE_TEST_AUDIO") != "1" || string.IsNullOrEmpty(Environment.GetEnvironmentVariable("NOISE_DATA_DIR")))
            throw new InvalidOperationException("Run routing tests only on a disposable audio server with NOISE_TEST_AUDIO=1.");
        string token = Guid.NewGuid().ToString("N")[..10], originalDefault = PulseCommand.Pactl("get-default-sink");
        var modules = new List<string>(); var fixtures = new List<Fixture>(); var audio = new LinuxAudio();
        string a = "test_a_" + token, b = "test_b_" + token, mic = "test_mic_" + token, source = "test_source_" + token;
        string appA = "noise.test.a." + token, appB = "noise.test.b." + token, appC = "noise.test.c." + token;
        try
        {
            bool pipewire = PulseCommand.Pactl("info").Contains("PipeWire", StringComparison.OrdinalIgnoreCase);
            foreach (var name in new[] { a, b, mic })
            {
                // Model real-time devices, rather than PulseAudio's two-second
                // idle null sink (which deliberately exceeds the route's limit).
                var args = new List<string> { "load-module", "module-null-sink", "sink_name=" + name, "rate=48000", "channels=1" };
                if (!pipewire) args.Add("norewinds=1");
                modules.Add(PulseCommand.Pactl(args.ToArray()));
            }
            modules.Add(PulseCommand.Pactl("load-module", "module-remap-source", "master=" + mic + ".monitor", "source_name=" + source, "channels=1"));
            PulseCommand.Pactl("set-default-sink", a);
            await Until(() => PulseCommand.Pactl("get-default-sink") == a, audio, "initial default output policy");
            fixtures.Add(new(appA, a, .03f)); fixtures.Add(new(appB, a, .02f)); fixtures.Add(new(appC, a, .01f));
            fixtures.Add(new("noise.test.mic." + token, mic, .04f));
            var s = new Settings { Applications = ["app:" + appA, "app:" + appB], MicrophoneDevice = source,
                Speaker = new() { Engine = 2, Enabled = false, Leveling = true }, Microphone = new() { Engine = 2, Enabled = false } };
            await Until(() => audio.Applications().Count(x => x.Id == "app:" + appA || x.Id == "app:" + appB) == 2, audio, "fixture registration");
            await audio.StartSpeaker(s);
            await Until(() => audio.SpeakerMetrics is { Frames: >= 200, InputRms: > .005 }, audio, "incoming PCM flow");
            Check(SinkOf(appA) == audio.IncomingSink && SinkOf(appB) == audio.IncomingSink, "both selected apps must be isolated");
            Check(SinkOf(appC) == a, "unselected app must retain its output");
            var raw = audio.SpeakerMetrics!;
            Check(Math.Abs(raw.OutputRms/raw.InputRms - 1) < .05, "cancellation off must also bypass leveling");
            Console.WriteLine("PASS two selected applications share one route; unselected app unchanged; original audio passes through");
            PulseCommand.Pactl("set-default-sink", b);
            await Until(() => PulseCommand.Pactl("get-default-sink") == b && PulseCommand.List("sink-inputs").Any(e => PulseCommand.Prop(e, "noise.owner").EndsWith("_speaker") &&
                PulseCommand.List("sinks").Any(d => PulseCommand.Text(d, "index") == PulseCommand.Text(e, "sink") && PulseCommand.Text(d, "name") == b)), audio, "default output follow");
            Console.WriteLine("PASS incoming output follows system default changes");
            s.Speaker.Enabled = true; audio.SettingsChanged();
            await Until(() => audio.SpeakerMetrics is { Frames: >= 300 } m && m.OutputRms < m.InputRms * .8, audio, "live noise suppression");
            Console.WriteLine("PASS live cancellation control reduces generated stationary noise");
            // The desktop may move unselected apps when its default changes.
            // Noise must preserve that normal policy when restoring its own apps.
            string unselectedOutput = SinkOf(appC);
            await audio.StartMicrophone(s);
            await Until(() => audio.MicrophoneMetrics is { Frames: >= 100, InputRms: > .01 }, audio, "microphone processing");
            var read = new ProcessStartInfo("parec") { RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (string arg in new[] { "--raw", "--format=float32le", "--rate=48000", "--channels=1", "--device=" + audio.MicrophoneSource }) read.ArgumentList.Add(arg);
            using (var recorder = Process.Start(read)!)
            {
                try
                {
                    byte[] samples = new byte[48000 * 4];
                    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                    await recorder.StandardOutput.BaseStream.ReadExactlyAsync(samples, timeout.Token);
                    float[] floats = new float[48000]; Buffer.BlockCopy(samples, 0, floats, 0, samples.Length);
                    Check(Math.Sqrt(floats.Average(x => x*x)) > .005, "virtual microphone must deliver processed PCM to another client");
                }
                finally { recorder.Kill(true); recorder.WaitForExit(); }
            }
            Console.WriteLine("PASS cleaned virtual microphone is readable by another audio client");
            await audio.StopSpeaker();
            Console.WriteLine($"After stopping: A={SinkOf(appA)} B={SinkOf(appB)} default={PulseCommand.Pactl("get-default-sink")} expected={b}");
            await Until(() => SinkOf(appA) == b && SinkOf(appB) == b, audio, "apps returning to the current default after stopping");
            Check(SinkOf(appC) == unselectedOutput, "stopping must not change the unselected app's current output");
            Console.WriteLine("PASS stopping restores selected app routing");
            await audio.StartSpeaker(s); audio.SimulateCrashForTest();
            var recovery = new LinuxAudio(); recovery.Update();
            Check(recovery.PollError() == null, "recovery must succeed");
            await Until(() => SinkOf(appA) == b && SinkOf(appB) == b, recovery, "crash recovery restoring apps");
            await recovery.DisposeAsync();
            Console.WriteLine("PASS recovery journal restores routing and removes stale virtual devices");
        }
        finally
        {
            try { await audio.DisposeAsync(); } catch { }
            foreach (var fixture in fixtures) fixture.Dispose();
            foreach (string id in modules.AsEnumerable().Reverse()) try { PulseCommand.Pactl("unload-module", id); } catch { }
            if (PulseCommand.List("sinks").Any(e => PulseCommand.Text(e, "name") == originalDefault))
                PulseCommand.Pactl("set-default-sink", originalDefault);
        }
    }
    private sealed class Fixture : IDisposable
    {
        private readonly Process process;
        private readonly CancellationTokenSource cancel = new();
        private readonly Task writer;
        public Fixture(string name, string sink, float amplitude)
        {
            var info = new ProcessStartInfo("pacat") { RedirectStandardInput = true, RedirectStandardError = true };
            foreach (string arg in new[] { "--playback", "--raw", "--format=float32le", "--rate=48000", "--channels=1", "--device=" + sink, "--client-name=" + name, "--property=application.id=" + name, "--latency-msec=40" }) info.ArgumentList.Add(arg);
            process = Process.Start(info)!;
            writer = Task.Run(async () =>
            {
                var random = new Random(name.GetHashCode()); float[] floats = new float[480]; byte[] bytes = new byte[1920];
                try { while (!cancel.IsCancellationRequested) { for (int i = 0; i < 480; ++i) floats[i] = (float)(random.NextDouble()*2-1)*amplitude; Buffer.BlockCopy(floats, 0, bytes, 0, bytes.Length); await process.StandardInput.BaseStream.WriteAsync(bytes, cancel.Token); } }
                catch (Exception e) when (e is IOException or OperationCanceledException or ObjectDisposedException) { }
            });
        }
        public void Dispose() { cancel.Cancel(); if (!process.HasExited) process.Kill(true); process.WaitForExit(); writer.GetAwaiter().GetResult(); process.Dispose(); cancel.Dispose(); }
    }
}
