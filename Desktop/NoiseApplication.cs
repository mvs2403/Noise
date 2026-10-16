using System.Reflection;
using System.Windows.Input;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Styling;
using Avalonia.Themes.Fluent;
using Avalonia.Threading;

namespace Noise;

internal sealed class ActionCommand(Action action) : ICommand
{
    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => action();
    public event EventHandler? CanExecuteChanged { add { } remove { } }
}

public sealed class NoiseApplication : Application
{
    private IClassicDesktopStyleApplicationLifetime? desktop;
    private ControlWindow? control;
    private IAudioBackend? backend;
    private bool quitting;
    public override void Initialize() { Styles.Add(new FluentTheme()); RequestedThemeVariant = ThemeVariant.Dark; }
    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime lifetime)
        {
            desktop = lifetime; desktop.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            bool smoke = Program.Arguments.Contains("--smoke-ui");
            backend = smoke ? new PreviewAudio() : OperatingSystem.IsWindows() ? new WindowsAudio() : OperatingSystem.IsLinux() ? new LinuxAudio() :
                throw new PlatformNotSupportedException("This release supports Windows 11 x64. Use the native Noise app on macOS.");
            control = new ControlWindow(backend, Quit, smoke);
            bool trayAvailable = backend.HasTrayHost;
            control.ShowInTaskbar = !trayAvailable;
            desktop.MainWindow = control;
            using var icon = Assembly.GetExecutingAssembly().GetManifestResourceStream("Noise.noise-icon.png")!;
            var menu = new NativeMenu();
            menu.Items.Add(new NativeMenuItem("Open Noise") { Command = new ActionCommand(Show) });
            menu.Items.Add(new NativeMenuItem("Quit Noise") { Command = new ActionCommand(async () => await Quit()) });
            var tray = new TrayIcon { Icon = new WindowIcon(icon), ToolTipText = "Noise · audio controls", Menu = menu,
                Command = new ActionCommand(Show), IsVisible = true };
            TrayIcon.SetIcons(this, new TrayIcons { tray });
            control.Closing += (_, e) => { if (!quitting) { e.Cancel = true; if (trayAvailable) control.Hide(); else control.WindowState = WindowState.Minimized; } };
            if (OperatingSystem.IsLinux())
                foreach (var signal in new[] { System.Runtime.InteropServices.PosixSignal.SIGTERM, System.Runtime.InteropServices.PosixSignal.SIGINT })
                    SignalHandlers.Add(System.Runtime.InteropServices.PosixSignalRegistration.Create(signal, context => { context.Cancel = true; Dispatcher.UIThread.Post(async () => await Quit()); }));
            control.Show();
            if (smoke) DispatcherTimer.RunOnce(() =>
            {
                using var bitmap = new RenderTargetBitmap(new PixelSize((int)control.Bounds.Width, (int)control.Bounds.Height));
                bitmap.Render(control); bitmap.Save(Path.Combine(AppContext.BaseDirectory, "windows-controls.png"));
                quitting = true; desktop.Shutdown();
            }, TimeSpan.FromSeconds(3));
        }
        base.OnFrameworkInitializationCompleted();
    }
    private void Show() { control?.Show(); control?.Activate(); }
    private static readonly List<IDisposable> SignalHandlers = [];
    private async Task Quit()
    {
        if (quitting) return;
        quitting = true;
        if (backend != null) await backend.DisposeAsync();
        desktop?.Shutdown();
    }
}

internal sealed class PreviewAudio : IAudioBackend
{
    public bool AutomaticAppRouting => OperatingSystem.IsLinux();
    public string SetupInstructions => "Virtual cable setup";
    public bool SpeakerRunning => false;
    public bool MicrophoneRunning => false;
    public IReadOnlyList<AudioDevice> Outputs() => [];
    public IReadOnlyList<AudioDevice> Inputs() => [];
    public IReadOnlyList<AudioApplication> Applications() => [new("teams", "Microsoft Teams"), new("chrome", "Google Chrome")];
    public AudioApplication? CurrentApplication() => new("teams", "Microsoft Teams");
    public Task<AudioApplication?> PickWindow(CancellationToken cancel) => Task.FromResult(CurrentApplication());
    public Task StartSpeaker(Settings s) => Task.CompletedTask;
    public Task StartMicrophone(Settings s) => Task.CompletedTask;
    public Task StopSpeaker() => Task.CompletedTask;
    public Task StopMicrophone() => Task.CompletedTask;
    public void Update() { }
    public string? PollError() => null;
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
