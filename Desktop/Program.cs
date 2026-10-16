using Avalonia;

namespace Noise;

internal static class Program
{
    public static string[] Arguments = [];
    [STAThread]
    public static int Main(string[] args)
    {
        Arguments = args;
        if (args.Contains("--self-test")) return SelfTest.Run();
        return AppBuilder.Configure<NoiseApplication>().UsePlatformDetect().LogToTrace()
            .StartWithClassicDesktopLifetime(args);
    }
}
