using System.Diagnostics;
using System.Globalization;
using System.Text.Json;

namespace Noise;

internal sealed record AudioMetrics(long Frames, double InputRms, double OutputRms);

internal static class PulseCommand
{
    public static string Run(string executable, params string[] args)
    {
        var info = new ProcessStartInfo(executable) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        foreach (var arg in args) info.ArgumentList.Add(arg);
        using var p = Process.Start(info) ?? throw new InvalidOperationException($"Could not start {executable}.");
        var output = p.StandardOutput.ReadToEndAsync(); var errors = p.StandardError.ReadToEndAsync();
        if (!p.WaitForExit(5000)) { p.Kill(true); throw new InvalidOperationException($"{executable} did not respond."); }
        string text = output.GetAwaiter().GetResult(); string error = errors.GetAwaiter().GetResult();
        if (p.ExitCode != 0) throw new InvalidOperationException(error.Trim().Length > 0 ? error.Trim() : $"{executable} failed.");
        return text.Trim();
    }
    public static string Pactl(params string[] args) => Run("pactl", args);
    public static JsonElement[] List(string kind)
    {
        using var document = JsonDocument.Parse(Pactl("--format=json", "list", kind));
        return document.RootElement.EnumerateArray().Select(e => e.Clone()).ToArray();
    }
    public static string Text(JsonElement e, string name) => e.TryGetProperty(name, out var value) ? value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : value.GetRawText() : "";
    public static string Prop(JsonElement e, string name) => e.TryGetProperty("properties", out var props) ? Text(props, name) : "";
}

internal sealed class LinuxAudio : IAudioBackend
{
    private readonly object gate = new();
    private readonly string token = Guid.NewGuid().ToString("N")[..12];
    private readonly string journalPath = Path.Combine(Path.GetDirectoryName(Settings.FilePath)!, "linux-routing.json");
    private RoutingJournal journal = new();
    private bool recovered;
    private Settings? settings;
    private LinuxRoute? speaker, microphone;
    private string? error;
    private string lastOutput = "";
    private AudioApplication? currentApp;
    public bool AutomaticAppRouting => true;
    public bool CanPickWindow => Environment.GetEnvironmentVariable("XDG_SESSION_TYPE") != "wayland" &&
        !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("DISPLAY")) && File.Exists("/usr/bin/xdotool");
    public bool HasTrayHost
    {
        get
        {
            try { return PulseCommand.Run("gdbus", "call", "--session", "--dest", "org.freedesktop.DBus", "--object-path", "/org/freedesktop/DBus", "--method", "org.freedesktop.DBus.NameHasOwner", "org.kde.StatusNotifierWatcher").Contains("true"); }
            catch { return false; }
        }
    }
    public bool SpeakerRunning => speaker != null;
    public bool MicrophoneRunning => microphone != null;
    public string SetupInstructions => "Selected apps are routed automatically. Playback follows the system's current output. For outgoing calls, choose a physical microphone here, turn filtering on, then select Noise_Microphone as the microphone in your call app. Stop all silences that virtual microphone; Quit removes it. Choose your physical microphone in the call app before quitting Noise. Window picking is available in X11 sessions with xdotool; use the application checkboxes on Wayland.";
    public AudioMetrics? SpeakerMetrics => speaker?.Metrics;
    public AudioMetrics? MicrophoneMetrics => microphone?.Metrics;
    public string MicrophoneSource => journal.MicSource;
    public string IncomingSink => journal.Incoming;

    internal sealed class RoutingJournal
    {
        public string Incoming { get; set; } = "";
        public string MicSink { get; set; } = "";
        public string MicSource { get; set; } = "";
        public Dictionary<string, string> OriginalSinks { get; set; } = [];
        public HashSet<string> FollowDefault { get; set; } = [];
        public Dictionary<string, string> Modules { get; set; } = [];
    }
    private void SaveJournal()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(journalPath)!);
        File.WriteAllText(journalPath + ".tmp", JsonSerializer.Serialize(journal));
        File.Move(journalPath + ".tmp", journalPath, true);
    }
    private void Recover()
    {
        if (recovered) return;
        if (File.Exists(journalPath))
        {
            journal = JsonSerializer.Deserialize<RoutingJournal>(File.ReadAllText(journalPath)) ?? new();
            Restore(); RemoveModules();
        }
        journal = new(); recovered = true;
    }
    private static bool Owned(JsonElement stream) => PulseCommand.Prop(stream, "noise.owner").Length > 0;
    private static string AppId(JsonElement stream)
    {
        var id = PulseCommand.Prop(stream, "application.id");
        if (id.Length > 0) return "app:" + id;
        return "exe:" + (Executable(PulseCommand.Prop(stream, "application.process.id")) ?? PulseCommand.Prop(stream, "application.process.binary"));
    }
    private static string? Executable(string pid)
    {
        try { return File.ResolveLinkTarget("/proc/" + int.Parse(pid) + "/exe", true)?.FullName; } catch { return null; }
    }
    private static Dictionary<int, int> Parents()
    {
        var parents = new Dictionary<int, int>();
        foreach (string dir in Directory.EnumerateDirectories("/proc"))
            if (int.TryParse(Path.GetFileName(dir), out var pid))
                try { string stat = File.ReadAllText(dir + "/stat"); parents[pid] = int.Parse(stat[(stat.LastIndexOf(')') + 2)..].Split(' ')[1]); } catch { }
        return parents;
    }
    private static bool Selected(JsonElement stream, Settings s, Dictionary<int, int> parents)
    {
        if (Owned(stream)) return false;
        var selected = s.Applications.ToHashSet();
        if (selected.Contains(AppId(stream))) return true;
        if (!int.TryParse(PulseCommand.Prop(stream, "application.process.id"), out int pid)) return false;
        return ApplicationTree.SelectedRoot(pid, parents, p => "exe:" + Executable(p.ToString()), selected) != 0;
    }
    public IReadOnlyList<AudioDevice> Outputs() => PulseCommand.List("sinks").Where(e => !PulseCommand.Text(e, "name").StartsWith("noise_")).Select(Device).ToArray();
    public IReadOnlyList<AudioDevice> Inputs() => PulseCommand.List("sources").Where(e =>
        !PulseCommand.Text(e, "name").StartsWith("noise_") && !PulseCommand.Text(e, "name").EndsWith(".monitor") &&
        (PulseCommand.Text(e, "monitor_of_sink") is "" or "null" or "4294967295")).Select(Device).ToArray();
    private static AudioDevice Device(JsonElement e) => new(PulseCommand.Text(e, "name"), PulseCommand.Text(e, "description"));
    public IReadOnlyList<AudioApplication> Applications() => PulseCommand.List("sink-inputs").Where(e => !Owned(e))
        .GroupBy(AppId).Select(g => new AudioApplication(g.Key, PulseCommand.Prop(g.First(), "application.name") is { Length: > 0 } name ? name : g.Key)).OrderBy(a => a.Name).ToArray();
    private AudioApplication? AppForPid(string pid)
    {
        var streams = PulseCommand.List("sink-inputs").Where(e => !Owned(e)).ToArray();
        var matching = streams.FirstOrDefault(e => PulseCommand.Prop(e, "application.process.id") == pid);
        if (matching.ValueKind != JsonValueKind.Undefined) return new(AppId(matching), PulseCommand.Prop(matching, "application.name"));
        var exe = Executable(pid); return exe == null ? null : new("exe:" + exe, Path.GetFileName(exe));
    }
    public AudioApplication? CurrentApplication() => currentApp;
    public async Task<AudioApplication?> PickWindow(CancellationToken cancel)
    {
        if (!CanPickWindow) return null;
        var start = new ProcessStartInfo("xdotool") { RedirectStandardOutput = true, RedirectStandardError = true };
        start.ArgumentList.Add("selectwindow");
        using var p = Process.Start(start)!;
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel); timeout.CancelAfter(TimeSpan.FromSeconds(30));
            string id = await p.StandardOutput.ReadToEndAsync(timeout.Token); await p.WaitForExitAsync(timeout.Token);
            return currentApp = AppForPid(PulseCommand.Run("xdotool", "getwindowpid", id.Trim()));
        }
        finally { if (!p.HasExited) p.Kill(); }
    }
    private string DefaultOutput()
    {
        var name = PulseCommand.Pactl("get-default-sink");
        if (name.StartsWith("noise_")) throw new InvalidOperationException("Choose real speakers or headphones as the system output before starting Noise.");
        return name;
    }
    private void Module(string type, string name, params string[] args)
    {
        string id = PulseCommand.Pactl(new[] { "load-module", type }.Concat(args).ToArray());
        journal.Modules[id] = name; SaveJournal();
    }
    private void EnsureIncoming()
    {
        if (journal.Incoming.Length > 0) return;
        journal.Incoming = "noise_in_" + token; SaveJournal();
        Module("module-null-sink", journal.Incoming, "sink_name=" + journal.Incoming, "rate=48000", "channels=1", "channel_map=mono", "sink_properties=device.description=Noise_Incoming");
    }
    private void EnsureMicrophone()
    {
        if (journal.MicSink.Length > 0) return;
        journal.MicSink = "noise_mic_" + token; journal.MicSource = "noise_microphone_" + token; SaveJournal();
        Module("module-null-sink", journal.MicSink, "sink_name=" + journal.MicSink, "rate=48000", "channels=1", "channel_map=mono", "sink_properties=device.description=Noise_Microphone_Bus");
        Module("module-remap-source", journal.MicSource, "master=" + journal.MicSink + ".monitor", "source_name=" + journal.MicSource, "channels=1", "channel_map=mono", "source_properties=device.description=Noise_Microphone");
    }
    private void RouteSelected()
    {
        if (settings == null || journal.Incoming.Length == 0) return;
        var sinks = PulseCommand.List("sinks").ToDictionary(e => PulseCommand.Text(e, "index"), e => PulseCommand.Text(e, "name"));
        var parents = Parents();
        foreach (var stream in PulseCommand.List("sink-inputs"))
        {
            string index = PulseCommand.Text(stream, "index"); string sink = sinks.GetValueOrDefault(PulseCommand.Text(stream, "sink"), "");
            if (Selected(stream, settings, parents))
            {
                if (sink == journal.Incoming) continue;
                if (sink.StartsWith("noise_")) throw new InvalidOperationException("A selected app is already using another Noise route.");
                journal.OriginalSinks[index] = sink; SaveJournal();
                if (sink == lastOutput) journal.FollowDefault.Add(index); else journal.FollowDefault.Remove(index);
                SaveJournal();
                PulseCommand.Pactl("move-sink-input", index, journal.Incoming);
            }
            else if (!Owned(stream) && sink == journal.Incoming && journal.OriginalSinks.TryGetValue(index, out var original))
            { PulseCommand.Pactl("move-sink-input", index, journal.FollowDefault.Contains(index) ? DefaultOutput() : sinks.Values.Contains(original) ? original : DefaultOutput()); journal.OriginalSinks.Remove(index); journal.FollowDefault.Remove(index); SaveJournal(); }
        }
    }
    private void Restore()
    {
        if (journal.Incoming.Length == 0) return;
        var sinks = PulseCommand.List("sinks").ToDictionary(e => PulseCommand.Text(e, "index"), e => PulseCommand.Text(e, "name"));
        foreach (var stream in PulseCommand.List("sink-inputs"))
        {
            var id = PulseCommand.Text(stream, "index");
            if (sinks.GetValueOrDefault(PulseCommand.Text(stream, "sink")) != journal.Incoming) continue;
            var original = journal.OriginalSinks.GetValueOrDefault(id, "");
            PulseCommand.Pactl("move-sink-input", id, journal.FollowDefault.Contains(id) ? DefaultOutput() : sinks.Values.Contains(original) ? original : DefaultOutput());
        }
        journal.OriginalSinks.Clear(); journal.FollowDefault.Clear(); SaveJournal();
    }
    private void RemoveModules()
    {
        var modules = PulseCommand.List("modules");
        foreach (var module in journal.Modules.Reverse().ToArray())
        {
            var actual = modules.FirstOrDefault(e => PulseCommand.Text(e, "index") == module.Key);
            // IDs can be reused after a daemon restart. Require our unique device name too.
            if (actual.ValueKind != JsonValueKind.Undefined && PulseCommand.Text(actual, "argument").Contains(module.Value))
                PulseCommand.Pactl("unload-module", module.Key);
            journal.Modules.Remove(module.Key); SaveJournal();
        }
        File.Delete(journalPath);
    }
    public Task StartSpeaker(Settings s)
    {
        lock (gate)
        {
            Recover(); StopSpeakerCore(); settings = s;
            if (s.Applications.Count == 0) throw new InvalidOperationException("Select one or more applications first. Play audio in an app to make it appear in the chooser.");
            lastOutput = DefaultOutput(); EnsureIncoming();
            speaker = LinuxRoute.Start(s.Speaker, journal.Incoming + ".monitor", lastOutput, token + "_speaker");
            try { RouteSelected(); } catch { StopSpeakerCore(); throw; }
        }
        return Task.CompletedTask;
    }
    public Task StartMicrophone(Settings s)
    {
        lock (gate)
        {
            Recover(); StopMicrophoneCore(); settings = s;
            if (!Inputs().Any(d => d.Id == s.MicrophoneDevice)) throw new InvalidOperationException("Choose an active physical microphone in Settings first.");
            EnsureMicrophone(); microphone = LinuxRoute.Start(s.Microphone, s.MicrophoneDevice, journal.MicSink, token + "_microphone");
        }
        return Task.CompletedTask;
    }
    private void StopSpeakerCore() { var old = speaker; speaker = null; old?.Dispose(); Restore(); }
    private void StopMicrophoneCore() { var old = microphone; microphone = null; old?.Dispose(); } // Keep a silent virtual microphone until Quit.
    public Task StopSpeaker() { lock (gate) { if (recovered) StopSpeakerCore(); } return Task.CompletedTask; }
    public Task StopMicrophone() { lock (gate) StopMicrophoneCore(); return Task.CompletedTask; }
    public void SettingsChanged() { lock (gate) { if (settings != null) { speaker?.Configure(settings.Speaker); microphone?.Configure(settings.Microphone); } } }
    public void Update()
    {
        lock (gate)
        {
            try
            {
                Recover();
                if (CanPickWindow)
                {
                    try {
                    var pid = PulseCommand.Run("xdotool", "getwindowpid", PulseCommand.Run("xdotool", "getactivewindow"));
                    if (pid != Environment.ProcessId.ToString() && AppForPid(pid) is {} app) currentApp = app;
                    } catch { } // No active X11 window is normal on an empty desktop.
                }
                if (speaker != null && settings != null)
                {
                    var output = DefaultOutput();
                    if (output != lastOutput) { speaker.Dispose(); speaker = LinuxRoute.Start(settings.Speaker, journal.Incoming + ".monitor", output, token + "_speaker"); lastOutput = output; }
                    RouteSelected();
                }
            }
            catch (Exception e) { error = e.Message; }
        }
    }
    public string? PollError() { lock (gate) { var message = error ?? speaker?.Error ?? microphone?.Error; error = null; return message; } }
    public ValueTask DisposeAsync()
    {
        lock (gate) { StopMicrophoneCore(); if (recovered) { StopSpeakerCore(); RemoveModules(); journal = new(); } }
        return ValueTask.CompletedTask;
    }
    internal void SimulateCrashForTest() { lock (gate) { speaker?.Dispose(); microphone?.Dispose(); speaker = microphone = null; } }
}

internal sealed class LinuxRoute : IDisposable
{
    private readonly Process process;
    private readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private volatile bool stopping;
    public volatile string? Error;
    public volatile AudioMetrics? Metrics;
    private LinuxRoute(ChannelSettings channel, string input, string output, string owner)
    {
        var start = new ProcessStartInfo(Path.Combine(NativeProcessor.Runtime, "noise-audio"))
        { RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        string[] args = ["--engine", channel.RuntimeEngine.ToString(), "--libraries", NativeProcessor.Runtime, "--models", NativeProcessor.Models,
            "--input", input, "--output", output, "--owner", owner, "--enabled", channel.Enabled ? "1" : "0", "--leveling", channel.Leveling ? "1" : "0", "--strength", channel.Strength.ToString(CultureInfo.InvariantCulture)];
        foreach (var arg in args) start.ArgumentList.Add(arg);
        process = new Process { StartInfo = start, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data == "READY") ready.TrySetResult();
            else if (e.Data?.StartsWith("ERROR ") == true) { Error = e.Data[6..]; ready.TrySetException(new InvalidOperationException(Error)); }
            else if (e.Data?.StartsWith("STAT ") == true)
            {
                var parts = e.Data.Split(' ');
                if (parts.Length == 4 && long.TryParse(parts[1], out var frames) && double.TryParse(parts[2], CultureInfo.InvariantCulture, out var before) && double.TryParse(parts[3], CultureInfo.InvariantCulture, out var after)) Metrics = new(frames, before, after);
            }
        };
        process.ErrorDataReceived += (_, _) => { }; // Drain library diagnostics without recording audio.
        process.Exited += (_, _) => { if (!stopping) { Error ??= "The audio route stopped. Restart filtering."; ready.TrySetException(new InvalidOperationException(Error)); } };
        process.Start(); process.StandardInput.AutoFlush = true; process.BeginOutputReadLine(); process.BeginErrorReadLine();
    }
    public static LinuxRoute Start(ChannelSettings c, string input, string output, string owner)
    {
        var route = new LinuxRoute(c, input, output, owner);
        try { route.ready.Task.WaitAsync(TimeSpan.FromSeconds(20)).GetAwaiter().GetResult(); return route; }
        catch { route.Dispose(); throw; }
    }
    public void Configure(ChannelSettings c)
    {
        if (stopping) return;
        try { process.StandardInput.WriteLine("enabled " + (c.Enabled ? "1" : "0")); process.StandardInput.WriteLine("leveling " + (c.Leveling ? "1" : "0")); process.StandardInput.WriteLine("strength " + c.Strength.ToString(CultureInfo.InvariantCulture)); }
        catch (IOException e) { Error = e.Message; }
    }
    public void Dispose()
    {
        stopping = true;
        try { if (!process.HasExited) { process.StandardInput.WriteLine("quit"); process.StandardInput.Close(); if (!process.WaitForExit(1500)) { process.Kill(true); process.WaitForExit(); } } }
        catch (IOException) { if (!process.HasExited) process.Kill(true); }
        finally { process.Dispose(); }
    }
}
