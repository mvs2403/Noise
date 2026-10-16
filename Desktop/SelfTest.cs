namespace Noise;

internal static class SelfTest
{
    public static int Run()
    {
        try
        {
            if (OperatingSystem.IsWindows())
            {
                Check(WindowsAudio.ProcessIdentity(Environment.ProcessId) != null, "Windows process/package identity query");
                Task.Run(() =>
                {
                    var windows = new WindowsAudio();
                    _ = windows.Outputs(); _ = windows.Inputs(); _ = windows.Applications();
                }).GetAwaiter().GetResult();
                Console.WriteLine("PASS Windows process identity and background WASAPI endpoint/session enumeration");
            }
            var parents = new Dictionary<int, int> { [30] = 20, [20] = 10, [10] = 1, [40] = 1 };
            var paths = new Dictionary<int, string> { [1] = "shell", [10] = "Teams", [20] = "WebView", [30] = "audio-helper", [40] = "other-app" };
            var selected = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "Teams", "WebView" };
            Check(ApplicationTree.SelectedRoot(30, parents, pid => paths.GetValueOrDefault(pid), selected) == 10, "differently named helper belongs to selected parent exactly once");
            Check(ApplicationTree.SelectedRoot(40, parents, pid => paths.GetValueOrDefault(pid), selected) == 0, "unselected app excluded");
            var ring = new SampleRing();
            float[] a = Enumerable.Range(0, 480).Select(i => (float)i).ToArray(), b = new float[480];
            for (int n = 0; n < 200; ++n)
            { Check(ring.Push(a), "ring push"); Check(ring.Pop(b) == 480 && a.SequenceEqual(b), "ring wrap"); }
            Check(!ring.Push(new float[12001]) && ring.Count == 0, "bounded overflow");
            var s = new Settings { IncomingDevice = "in", CleanMicrophoneDevice = "mic" };
            WindowsAudio.ValidateEndpoints(s, "headphones");
            foreach (var conflict in new[] { "in", "mic" })
            {
                bool rejected = false;
                try { WindowsAudio.ValidateEndpoints(s, conflict); } catch (InvalidOperationException) { rejected = true; }
                Check(rejected, "virtual output feedback guard");
            }
            s.CleanMicrophoneDevice = "in";
            bool duplicate = false;
            try { WindowsAudio.ValidateEndpoints(s, "headphones"); } catch (InvalidOperationException) { duplicate = true; }
            Check(duplicate, "separate incoming/microphone cables");
            for (int engine = 0; engine < 4; ++engine)
            {
                using var processor = new NativeProcessor(engine);
                var settings = new ChannelSettings { Engine = engine, Leveling = true };
                for (int n = 0; n < 100; ++n)
                {
                    for (int i = 0; i < 480; ++i) a[i] = .04f * MathF.Sin((n * 480 + i) * 2 * MathF.PI * 220 / 48000);
                    processor.Process(a, b, settings, true);
                    Check(b.All(x => float.IsFinite(x) && Math.Abs(x) <= 1), $"engine {engine} finite");
                    processor.Process(a, b, settings, false);
                    Check(a.SequenceEqual(b), $"engine {engine} exact bypass");
                }
                Console.WriteLine($"PASS engine {engine}: streaming, leveling, exact bypass");
            }
            Console.WriteLine("PASS bounded audio queue; all four native engines"); return 0;
        }
        catch (Exception e) { Console.Error.WriteLine(e); return 1; }
    }
    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
}
