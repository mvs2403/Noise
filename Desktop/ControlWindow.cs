using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;

namespace Noise;

internal sealed class ControlWindow : Window
{
    private readonly IAudioBackend backend;
    private readonly Settings settings;
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = Brushes.LightGray };
    private readonly Button apps = new() { HorizontalAlignment = HorizontalAlignment.Stretch, MinHeight = 48 };
    private readonly List<ToggleSwitch> toggles = [];
    private bool updating, polling;
    private CancellationTokenSource? pick;
    public ControlWindow(IAudioBackend audio, Func<Task> quit, bool preview)
    {
        backend = audio; settings = preview ? new Settings { Applications = ["teams", "chrome"] } : Settings.Load();
        Title = "Noise"; Width = 380; CanResize = false; ShowInTaskbar = false;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var tabs = new TabControl { ItemsSource = new[] {
            new TabItem { Header = "🔊  Speaker", Content = Channel(settings.Speaker, false) },
            new TabItem { Header = "🎙  Microphone", Content = Channel(settings.Microphone, true) }
        }};
        var controls = Column(16);
        var heading = new DockPanel();
        var settingsButton = Button("⚙", async () => await SettingsWindow()); DockPanel.SetDock(settingsButton, Dock.Right);
        heading.Children.Add(settingsButton);
        heading.Children.Add(new TextBlock { Text = "Noise", FontSize = 22, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        controls.Children.Add(heading); controls.Children.Add(tabs);
        controls.Children.Add(status);
        var footer = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        footer.Children.Add(Button("Stop all", async () => await StopAll()));
        footer.Children.Add(Button("Quit", quit)); controls.Children.Add(footer);
        controls.Children.Add(new TextBlock { Text = "Audio stays on this device", FontSize = 11, Foreground = Brushes.Gray });
        Content = new Border { Padding = new Thickness(20), Child = controls };
        RefreshApps(); status.Text = "Ready. Configure audio routing in Settings before your first call.";
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        timer.Tick += async (_, _) =>
        {
            if (polling || preview) return;
            polling = true;
            try
            {
                var error = await Task.Run(() => { backend.Update(); return backend.PollError(); });
                if (error != null) { await StopAll(); status.Text = error; }
            }
            catch (Exception e) { status.Text = e.Message; }
            finally { polling = false; }
        };
        timer.Start(); Closed += (_, _) => { timer.Stop(); pick?.Cancel(); };
    }
    private static StackPanel Column(double spacing = 12) => new() { Spacing = spacing };
    private static TextBlock Label(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap };
    private Button Button(string text, Func<Task> action)
    {
        var button = new Button { Content = text };
        button.Click += async (_, _) =>
        {
            try { await action(); }
            catch (Exception e) { status.Text = e.Message; }
        };
        return button;
    }
    private Control Channel(ChannelSettings channel, bool mic)
    {
        var panel = Column(16); panel.Margin = new Thickness(0, 16, 0, 8);
        panel.Children.Add(Label(mic ? "What they can hear" : "What you can hear"));
        if (!mic) { apps.Click += async (_, _) => await ChooseApps(); panel.Children.Add(apps); }
        var toggle = new ToggleSwitch { Content = "Noise cancellation", IsChecked = false };
        var leveling = new ToggleSwitch { Content = "Voice leveling", IsChecked = channel.Leveling, IsEnabled = false };
        var strength = new Slider { Minimum = 0, Maximum = 1, Value = channel.Strength, TickFrequency = .05, IsSnapToTickEnabled = true };
        var strengthLabel = Label("Noise reduction");
        var strengthBox = Column(4); strengthBox.Children.Add(strengthLabel); strengthBox.Children.Add(strength); strengthBox.IsVisible = false;
        strength.ValueChanged += (_, _) => { channel.Strength = strength.Value; Save(); };
        leveling.IsCheckedChanged += (_, _) => { channel.Leveling = leveling.IsChecked == true; Save(); };
        toggles.Add(toggle);
        toggle.IsCheckedChanged += async (_, _) =>
        {
            if (updating) return;
            bool enabled = toggle.IsChecked == true;
            channel.Enabled = enabled; toggle.IsEnabled = false;
            try
            {
                if (enabled && !(mic ? backend.MicrophoneRunning : backend.SpeakerRunning))
                {
                    if (mic) await Task.Run(() => backend.StartMicrophone(settings));
                    else await Task.Run(() => backend.StartSpeaker(settings));
                }
                status.Text = enabled ? "Filtering active" : "Original audio · voice leveling off";
            }
            catch (Exception e) { channel.Enabled = false; updating = true; toggle.IsChecked = false; updating = false; status.Text = e.Message; }
            finally { toggle.IsEnabled = true; strengthBox.IsVisible = channel.Enabled; leveling.IsEnabled = channel.Enabled; }
        };
        panel.Children.Add(toggle); panel.Children.Add(strengthBox); panel.Children.Add(leveling);
        panel.Children.Add(new TextBlock { Text = "Quiet voices up. Loud voices down.", FontSize = 12, Foreground = Brushes.Gray });
        return panel;
    }
    private void Save() { try { settings.Save(); } catch (Exception e) { status.Text = "Could not save settings: " + e.Message; } }
    private void RefreshApps() => apps.Content = settings.Applications.Count == 0 ? "Choose applications…" : $"Choose applications  ·  {settings.Applications.Count} selected  ›";
    private async Task StopAll()
    {
        settings.Speaker.Enabled = settings.Microphone.Enabled = false;
        // Use switch events so the dependent slider and leveling controls update too.
        foreach (var toggle in toggles) toggle.IsChecked = false;
        await backend.StopSpeaker(); await backend.StopMicrophone();
        status.Text = "Stopped. Restore app outputs to Default in Windows Volume mixer before quitting.";
    }
    private Window Dialog(string title, StackPanel panel, double width = 520)
    {
        return new Window { Title = title, Width = width, MaxHeight = 760, SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, Content = new ScrollViewer { Content = new Border { Padding = new Thickness(24), Child = panel } } };
    }
    private async Task ChooseApps()
    {
        var panel = Column(12); var window = Dialog("Choose applications", panel);
        var selected = new HashSet<string>(settings.Applications, OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
        var choices = Column(8); var message = Label("");
        void Add(AudioApplication app)
        {
            selected.Add(app.Id); Rebuild();
        }
        void Rebuild()
        {
            choices.Children.Clear();
            var available = backend.Applications().ToDictionary(a => a.Id);
            foreach (var id in selected) if (!available.ContainsKey(id))
                available[id] = new(id, id.StartsWith("package:") ? id[8..].Split('_')[0] : Path.GetFileNameWithoutExtension(id));
            foreach (var app in available.Values.OrderBy(a => a.Name))
            {
                var check = new CheckBox { Content = app.Name, IsChecked = selected.Contains(app.Id) };
                check.IsCheckedChanged += (_, _) => { if (check.IsChecked == true) selected.Add(app.Id); else selected.Remove(app.Id); };
                choices.Children.Add(check);
            }
        }
        panel.Children.Add(Label("Filter one or more apps with one shared engine."));
        panel.Children.Add(Button("Use current app", () => { if (backend.CurrentApplication() is {} app) Add(app); else message.Text = "Switch to the app once, then reopen this picker."; return Task.CompletedTask; }));
        panel.Children.Add(Button("Click a window to select it", async () =>
        {
            pick?.Cancel(); pick = new CancellationTokenSource(); window.Hide(); Hide();
            try { var app = await backend.PickWindow(pick.Token); if (app != null) Add(app); else message.Text = "No application selected. Try again."; }
            catch (OperationCanceledException) { }
            finally { Show(); Activate(); window.Show(); window.Activate(); }
        }));
        panel.Children.Add(Button("Refresh applications", () => { Rebuild(); return Task.CompletedTask; }));
        panel.Children.Add(choices); panel.Children.Add(message);
        panel.Children.Add(Button("Apply", async () =>
        {
            bool restart = backend.SpeakerRunning; settings.Applications = selected.ToList(); Save(); RefreshApps();
            if (restart) try { await Task.Run(() => backend.StartSpeaker(settings)); } catch (Exception e) { await StopAll(); status.Text = e.Message; }
            window.Close();
        }));
        window.Closed += (_, _) => pick?.Cancel(); Rebuild(); await window.ShowDialog(this);
    }
    private async Task SettingsWindow()
    {
        var panel = Column(14); var window = Dialog("Noise settings", panel, 620);
        var processingChoices = new List<(ChannelSettings Channel, ComboBox Engine, ComboBox Voices)>();
        panel.Children.Add(new TextBlock { Text = "Audio processing", FontSize = 20, FontWeight = FontWeight.SemiBold });
        foreach (var pair in new[] { ("Speaker", settings.Speaker), ("Microphone", settings.Microphone) })
        {
            panel.Children.Add(Label(pair.Item1));
            var engines = new ComboBox { ItemsSource = new[] { "DPDFNet (default)", "DeepFilterNet 3", "RNNoise" }, SelectedIndex = pair.Item2.Engine, HorizontalAlignment = HorizontalAlignment.Stretch };
            var voices = new ComboBox { ItemsSource = new[] { "All voices", "Main speaker only (experimental)" }, SelectedIndex = pair.Item2.MainSpeaker ? 1 : 0, HorizontalAlignment = HorizontalAlignment.Stretch };
            processingChoices.Add((pair.Item2, engines, voices));
            panel.Children.Add(engines); panel.Children.Add(voices);
        }
        panel.Children.Add(Label("Main speaker is automatic and uses the Hush model. No voice sample is required. It can attenuate the foreground voice in difficult audio."));
        panel.Children.Add(new Separator()); panel.Children.Add(Label("Audio routing · follows Windows default listening output"));
        var outputs = backend.Outputs(); var inputs = backend.Inputs();
        ComboBox Device(string label, IReadOnlyList<AudioDevice> devices, string id)
        {
            panel.Children.Add(Label(label));
            var options = new[] { new AudioDevice("", "Choose a device…") }.Concat(devices).ToArray();
            var combo = new ComboBox { ItemsSource = options, SelectedIndex = Math.Max(0, Array.FindIndex(options, d => d.Id == id)), HorizontalAlignment = HorizontalAlignment.Stretch };
            panel.Children.Add(combo); return combo;
        }
        var incoming = Device("Incoming isolation cable (playback endpoint)", outputs, settings.IncomingDevice);
        var mic = Device("Physical microphone", inputs, settings.MicrophoneDevice);
        var cleanedMic = Device("Cleaned microphone cable (different playback endpoint)", outputs, settings.CleanMicrophoneDevice);
        panel.Children.Add(new TextBlock { Text = backend.SetupInstructions, TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = Brushes.LightGray });
        panel.Children.Add(Button("Open Windows sound settings", () => { OpenUrl("ms-settings:apps-volume"); return Task.CompletedTask; }));
        panel.Children.Add(Button("Virtual cable installation guide", () => { OpenUrl("https://github.com/mvs2403/Noise/blob/main/docs/WINDOWS.md"); return Task.CompletedTask; }));
        panel.Children.Add(Button("Apply settings", async () =>
        {
            foreach (var choice in processingChoices)
            {
                choice.Channel.Engine = Math.Max(0, choice.Engine.SelectedIndex);
                choice.Channel.MainSpeaker = choice.Voices.SelectedIndex == 1;
            }
            settings.IncomingDevice = (incoming.SelectedItem as AudioDevice)?.Id ?? "";
            settings.MicrophoneDevice = (mic.SelectedItem as AudioDevice)?.Id ?? "";
            settings.CleanMicrophoneDevice = (cleanedMic.SelectedItem as AudioDevice)?.Id ?? "";
            Save(); bool speaker = backend.SpeakerRunning, microphone = backend.MicrophoneRunning;
            try
            {
                if (speaker) await Task.Run(() => backend.StartSpeaker(settings));
                if (microphone) await Task.Run(() => backend.StartMicrophone(settings));
                window.Close();
            }
            catch (Exception e) { await StopAll(); status.Text = e.Message; window.Close(); }
        }));
        await window.ShowDialog(this);
    }
    private static void OpenUrl(string url) => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });
}
