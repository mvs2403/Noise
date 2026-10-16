using Avalonia;
using System.Security.Cryptography;
using System.Text;

namespace Noise;

internal static class Program
{
    public static string[] Arguments = [];
    [STAThread]
    public static int Main(string[] args)
    {
        Arguments = args;
        if (args.Contains("--self-test")) return SelfTest.Run();
        // A second background instance must not capture and play the same apps twice.
        string identity = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Settings.FilePath)))[..16];
        using var instance = new Mutex(false, "Noise.Desktop." + identity);
        bool owned;
        try { owned = instance.WaitOne(0); } catch (AbandonedMutexException) { owned = true; }
        if (!owned) return 0; // The running instance remains available in the notification area.
        try
        {
            return AppBuilder.Configure<NoiseApplication>().UsePlatformDetect().LogToTrace()
                .StartWithClassicDesktopLifetime(args);
        }
        finally { instance.ReleaseMutex(); }
    }
}
