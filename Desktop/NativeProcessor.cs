using System.Runtime.InteropServices;
using System.Reflection;

namespace Noise;

internal sealed unsafe class NativeProcessor : IDisposable
{
    private nint handle;
    public static readonly string Runtime = Path.Combine(AppContext.BaseDirectory, "Runtime");
    public static readonly string Models = Path.Combine(AppContext.BaseDirectory, "Models");
    static NativeProcessor()
    {
        NativeLibrary.SetDllImportResolver(typeof(NativeProcessor).Assembly, (name, assembly, search) =>
            name == "noise_dsp" ? NativeLibrary.Load(Path.Combine(Runtime,
                OperatingSystem.IsWindows() ? "noise_dsp.dll" : OperatingSystem.IsMacOS() ? "libnoise_dsp.dylib" : "libnoise_dsp.so")) : 0);
    }
    public NativeProcessor(int engine)
    {
        byte[] error = new byte[2048];
        handle = Create(engine, Runtime, Models, error, error.Length);
        if (handle == 0) throw new InvalidOperationException(System.Text.Encoding.UTF8.GetString(error).TrimEnd('\0'));
    }
    public void Process(float[] input, float[] output, ChannelSettings settings, bool enabled)
    {
        Strength(handle, (float)settings.Strength);
        fixed (float* a = input, b = output)
            if (!ProcessNative(handle, a, b, (byte)(enabled && settings.Leveling ? 1 : 0), (byte)(enabled ? 0 : 1)))
                throw new InvalidOperationException("Audio processing failed. The route has stopped.");
    }
    public void Dispose() { if (handle != 0) { Destroy(handle); handle = 0; } }
    [DllImport("noise_dsp", EntryPoint = "nr_processor_create", CallingConvention = CallingConvention.Cdecl)]
    private static extern nint Create(int engine, [MarshalAs(UnmanagedType.LPUTF8Str)] string libraries,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string models, byte[] error, int length);
    [DllImport("noise_dsp", EntryPoint = "nr_processor_process", CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    private static extern bool ProcessNative(nint processor, float* input, float* output, byte leveling, byte bypass);
    [DllImport("noise_dsp", EntryPoint = "nr_processor_set_strength", CallingConvention = CallingConvention.Cdecl)]
    private static extern void Strength(nint processor, float strength);
    [DllImport("noise_dsp", EntryPoint = "nr_processor_destroy", CallingConvention = CallingConvention.Cdecl)]
    private static extern void Destroy(nint processor);
}

// Single producer/consumer, bounded to 250 ms. Dropping newest samples bounds latency;
// the audio callback never waits for model inference or an operating-system call.
internal sealed class SampleRing
{
    private readonly float[] data = new float[16384];
    private long read, write;
    public int Count => (int)(Volatile.Read(ref write) - Volatile.Read(ref read));
    public bool Push(ReadOnlySpan<float> values)
    {
        var w = write;
        if (values.Length > 12000 - (w - Volatile.Read(ref read))) return false;
        for (int i = 0; i < values.Length; ++i) data[(w + i) & 16383] = values[i];
        Volatile.Write(ref write, w + values.Length); return true;
    }
    public int Pop(Span<float> values)
    {
        var r = read; int n = Math.Min(values.Length, (int)(Volatile.Read(ref write) - r));
        for (int i = 0; i < n; ++i) values[i] = data[(r + i) & 16383];
        Volatile.Write(ref read, r + n); return n;
    }
}
