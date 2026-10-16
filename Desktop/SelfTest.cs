namespace Noise;

internal static class SelfTest
{
    public static int Run()
    {
        try
        {
            var ring = new SampleRing();
            float[] a = Enumerable.Range(0, 480).Select(i => (float)i).ToArray(), b = new float[480];
            for (int n = 0; n < 200; ++n)
            { Check(ring.Push(a), "ring push"); Check(ring.Pop(b) == 480 && a.SequenceEqual(b), "ring wrap"); }
            Check(!ring.Push(new float[12001]) && ring.Count == 0, "bounded overflow");
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
