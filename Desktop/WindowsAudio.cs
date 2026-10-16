using System.Diagnostics;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.Wave;

namespace Noise;

internal sealed class WindowsAudio : IAudioBackend
{
    private WindowsRoute? speaker, microphone;
    private readonly SemaphoreSlim transition = new(1, 1);
    private Settings? settings;
    private HashSet<int> capturedRoots = [];
    private string? error;
    private AudioApplication? lastApplication;
    public bool SpeakerRunning => speaker != null;
    public bool MicrophoneRunning => microphone != null;
    public string SetupInstructions => "Install a signed virtual audio cable first (for example VB-CABLE). For incoming audio, route each selected app to the Incoming cable in Windows Settings → System → Sound → Volume mixer. Keep your Windows default output on your real speakers or headphones. For the microphone, choose a physical input and a DIFFERENT virtual cable output here, then select its paired recording device in Teams or your call app. Two independent cable pairs are needed to clean both directions together. ‘Listen to this device’ must be off for both cables. Restore each app’s output to Default before quitting Noise.";

    private static IReadOnlyList<AudioDevice> Devices(DataFlow flow)
    {
        using var e = new MMDeviceEnumerator();
        return e.EnumerateAudioEndPoints(flow, DeviceState.Active).Select(d =>
        { using (d) return new AudioDevice(d.ID, d.FriendlyName); }).ToArray();
    }
    public IReadOnlyList<AudioDevice> Outputs() => Devices(DataFlow.Render);
    public IReadOnlyList<AudioDevice> Inputs() => Devices(DataFlow.Capture);
    private static string? Executable(int pid)
    {
        try { using var p = Process.GetProcessById(pid); return p.MainModule?.FileName; }
        catch { return null; } // Protected, elevated, and exited processes are not selectable.
    }
    private static AudioApplication? Application(int pid)
    {
        if (pid == Environment.ProcessId || pid == 0) return null;
        var path = Executable(pid);
        return path == null ? null : new(path, Path.GetFileNameWithoutExtension(path));
    }
    private record Session(int Pid, string Path, string Device, int Root = 0);
    private static List<Session> Sessions()
    {
        List<Session> result = [];
        using var e = new MMDeviceEnumerator();
        foreach (var d in e.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
        {
            using (d)
            {
                var sessions = d.AudioSessionManager.Sessions;
                for (int i = 0; i < sessions.Count; ++i)
                {
                    var session = sessions[i];
                    if (session.State != AudioSessionState.AudioSessionStateActive) continue;
                    int pid = (int)session.GetProcessID;
                    var app = Application(pid);
                    if (app != null) result.Add(new(pid, app.Id, d.ID));
                }
            }
        }
        return result;
    }
    public IReadOnlyList<AudioApplication> Applications()
    {
        var apps = new Dictionary<string, AudioApplication>(StringComparer.OrdinalIgnoreCase);
        foreach (var p in Process.GetProcesses())
        {
            using (p)
                try { if (p.MainWindowHandle != 0 && Application(p.Id) is {} app) apps[app.Id] = app; } catch { }
        }
        foreach (var session in Sessions()) if (Application(session.Pid) is {} app) apps[app.Id] = app;
        return apps.Values.OrderBy(a => a.Name).ToArray();
    }
    public AudioApplication? CurrentApplication()
    {
        GetWindowThreadProcessId(GetForegroundWindow(), out var pid);
        if (Application((int)pid) is {} app) lastApplication = app;
        return lastApplication;
    }
    public async Task<AudioApplication?> PickWindow(CancellationToken cancel)
    {
        // Closing/hiding our picker lets Windows deliver the user's next real window click.
        for (int i = 0; i < 300; ++i)
        {
            await Task.Delay(100, cancel);
            GetWindowThreadProcessId(GetForegroundWindow(), out var pid);
            if (Application((int)pid) is {} app) return lastApplication = app;
        }
        return null;
    }
    private static Dictionary<int, int> Parents()
    {
        var result = new Dictionary<int, int>();
        var snapshot = CreateToolhelp32Snapshot(2, 0);
        if (snapshot == new nint(-1)) return result;
        try
        {
            var entry = new ProcessEntry { Size = (uint)Marshal.SizeOf<ProcessEntry>(), Exe = "" };
            if (Process32First(snapshot, ref entry))
                do { result[(int)entry.Pid] = (int)entry.Parent; } while (Process32Next(snapshot, ref entry));
        }
        finally { CloseHandle(snapshot); }
        return result;
    }
    internal static void ValidateEndpoints(Settings s, string listening)
    {
        if (string.IsNullOrEmpty(s.IncomingDevice)) throw new InvalidOperationException("Choose the Incoming isolation cable in Settings first.");
        if (s.IncomingDevice == listening || s.CleanMicrophoneDevice == listening)
            throw new InvalidOperationException("Set Windows default output to your real speakers or headphones, not a Noise routing cable.");
        if (s.IncomingDevice == s.CleanMicrophoneDevice)
            throw new InvalidOperationException("Incoming audio and the cleaned microphone need two different virtual cables.");
    }
    private static string DefaultOutput()
    {
        using var e = new MMDeviceEnumerator();
        using var d = e.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia); return d.ID;
    }
    private static List<Session> SelectedSessions(Settings s)
    {
        var selected = new HashSet<string>(s.Applications, StringComparer.OrdinalIgnoreCase);
        var parents = Parents(); var paths = new Dictionary<int, string?>();
        string? PathFor(int pid)
        {
            if (!paths.TryGetValue(pid, out var path)) paths[pid] = path = Executable(pid);
            return path;
        }
        var sessions = Sessions().Select(x => x with {
            Root = ApplicationTree.SelectedRoot(x.Pid, parents, PathFor, selected)
        }).Where(x => x.Root != 0).ToList();
        if (sessions.Any(x => x.Device != s.IncomingDevice))
            throw new InvalidOperationException("Route every selected app to the Incoming cable in Windows Volume mixer first. This prevents hearing original and cleaned audio together.");
        return sessions;
    }
    private async Task Serialized(Func<Task> action)
    {
        await transition.WaitAsync();
        try { await action(); } finally { transition.Release(); }
    }
    public Task StartSpeaker(Settings s) => Serialized(() => StartSpeakerCore(s));
    private async Task StartSpeakerCore(Settings s)
    {
        await StopSpeakerCore(); settings = s;
        ValidateEndpoints(s, DefaultOutput());
        var sessions = SelectedSessions(s);
        if (s.Applications.Count == 0 || sessions.Count == 0)
            throw new InvalidOperationException("Select an app, start audio in it, and route it to the Incoming cable in Windows Volume mixer. Then turn filtering on.");
        var pids = sessions.Select(x => x.Root).Distinct().ToArray();
        capturedRoots = pids.ToHashSet();
        speaker = await WindowsRoute.Create(s.Speaker, pids, null, null);
    }
    public Task StartMicrophone(Settings s) => Serialized(() => StartMicrophoneCore(s));
    private async Task StartMicrophoneCore(Settings s)
    {
        await StopMicrophoneCore(); settings = s;
        if (string.IsNullOrEmpty(s.MicrophoneDevice) || string.IsNullOrEmpty(s.CleanMicrophoneDevice))
            throw new InvalidOperationException("Choose a physical microphone and a cleaned-microphone virtual cable in Settings first.");
        if (s.CleanMicrophoneDevice == DefaultOutput() || s.CleanMicrophoneDevice == s.IncomingDevice)
            throw new InvalidOperationException("The cleaned-microphone cable must differ from both your listening output and incoming cable.");
        // Feedback through a cable's recording half is prevented by explicit physical-input selection.
        using var e = new MMDeviceEnumerator();
        using var input = e.GetDevice(s.MicrophoneDevice);
        if (input.FriendlyName.Contains("CABLE", StringComparison.OrdinalIgnoreCase) || input.FriendlyName.Contains("Voicemeeter", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Choose a physical microphone as the input, not a virtual cable recording device.");
        microphone = await WindowsRoute.Create(s.Microphone, [], s.MicrophoneDevice, s.CleanMicrophoneDevice);
    }
    public Task StopSpeaker() => Serialized(StopSpeakerCore);
    public Task StopMicrophone() => Serialized(StopMicrophoneCore);
    private async Task StopSpeakerCore() { var route = speaker; speaker = null; if (route != null) await route.DisposeAsync(); }
    private async Task StopMicrophoneCore() { var route = microphone; microphone = null; if (route != null) await route.DisposeAsync(); }
    public void Update() { CurrentApplication(); }
    public string? PollError()
    {
        if (error is {} old) { error = null; return old; }
        try
        {
            if (speaker != null && settings != null)
            {
                ValidateEndpoints(settings, DefaultOutput());
                var sessions = SelectedSessions(settings);
                if (sessions.Any(s => !capturedRoots.Contains(s.Root)))
                    return "A selected application started a new audio process. Reopen Choose applications and Apply, then restart filtering.";
                if (speaker.Error != null) return speaker.Error;
            }
            if (microphone != null && settings?.CleanMicrophoneDevice == DefaultOutput())
                return "The Windows default output changed to the microphone cable. Choose real headphones or speakers before restarting.";
            return microphone?.Error;
        }
        catch (Exception e) { return e.Message; }
    }
    public async ValueTask DisposeAsync() { await StopSpeaker(); await StopMicrophone(); }
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint pid);
    [DllImport("kernel32.dll")] private static extern nint CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "Process32FirstW")]
    private static extern bool Process32First(nint snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "Process32NextW")]
    private static extern bool Process32Next(nint snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(nint handle);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry
    {
        public uint Size, Usage, Pid; public nuint Heap; public uint Module, Threads, Parent;
        public int Priority; public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Exe;
    }
}

internal sealed class WindowsRoute : IAsyncDisposable
{
    private readonly List<WasapiRecorder> recorders = [];
    private readonly List<MMDevice> devices = [];
    private readonly List<SampleRing> sources = [];
    private readonly SampleRing output = new();
    private readonly NativeProcessor processor;
    private readonly ChannelSettings settings;
    private readonly CancellationTokenSource cancel = new();
    private Task? worker;
    private WasapiPlayer? player;
    public string? Error;
    private WindowsRoute(ChannelSettings channel) { settings = channel; processor = new(channel.RuntimeEngine); }
    public static async Task<WindowsRoute> Create(ChannelSettings channel, int[] pids, string? input, string? destination)
    {
        var route = new WindowsRoute(channel);
        try { await route.Start(pids, input, destination); return route; }
        catch { await route.DisposeAsync(); throw; }
    }
    private async Task Start(int[] pids, string? input, string? destination)
    {
        using var e = new MMDeviceEnumerator();
        var playerBuilder = new WasapiPlayerBuilder().WithLatency(50).WithMmcssThreadPriority("Pro Audio");
        if (destination == null) playerBuilder.WithDefaultDeviceStreamRouting();
        else { var d = e.GetDevice(destination); devices.Add(d); playerBuilder.WithDevice(d); }
        player = await playerBuilder.BuildAsync();
        player.Init(new OutputProvider(output));
        player.PlaybackStopped += (_, args) => { if (!cancel.IsCancellationRequested) Error = args.Exception?.Message ?? "The output device stopped. Restart this route."; };
        foreach (int pid in input != null ? new[] { 0 } : pids)
        {
            var builder = new WasapiRecorderBuilder().WithFormat(WaveFormat.CreateIeeeFloatWaveFormat(48000, 1))
                .WithBufferLength(20)
                .WithMmcssThreadPriority("Pro Audio");
            if (input != null) { var d = e.GetDevice(input); devices.Add(d); builder.WithDevice(d); }
            else builder.WithProcessLoopback((uint)pid, ProcessLoopbackMode.IncludeTargetProcessTree);
            var recorder = await builder.BuildAsync();
            recorders.Add(recorder);
            var ring = new SampleRing(); sources.Add(ring);
            recorder.DataAvailable += (bytes, flags, _, _) =>
            {
                if ((flags & AudioClientBufferFlags.Silent) != 0)
                {
                    Span<float> silence = stackalloc float[480]; silence.Clear();
                    for (int offset = 0; offset < bytes.Length / 4; offset += 480)
                        if (!ring.Push(silence[..Math.Min(480, bytes.Length / 4 - offset)])) Error = "Capture queue overloaded. Restart the route or choose a faster engine.";
                }
                else if (!ring.Push(MemoryMarshal.Cast<byte, float>(bytes))) Error = "Capture queue overloaded. Restart the route or choose a faster engine.";
            };
            recorder.RecordingStopped += (_, args) => { if (!cancel.IsCancellationRequested) Error = args.Exception?.Message ?? "The capture source stopped. Restart the route."; };
        }
        worker = Task.Factory.StartNew(Work, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
        foreach (var recorder in recorders) recorder.StartRecording();
        player.Play();
    }
    private void Work()
    {
        float[] mixed = new float[480], cleaned = new float[480], scratch = new float[481];
        try
        {
            while (!cancel.IsCancellationRequested)
            {
                if (output.Count >= 1440) { Thread.Sleep(1); continue; }
                Array.Clear(mixed);
                foreach (var ring in sources)
                {
                    int available = ring.Count;
                    if (available == 0) continue;
                    // A partial packet must be stretched into this output block,
                    // rather than dropping a whole 10 ms of speech at a clock boundary.
                    int count = Math.Min(available, available > 2880 ? 481 : 480);
                    ring.Pop(scratch.AsSpan(0, count));
                    for (int i = 0; i < 480; ++i)
                    {
                        float position = i * (count - 1f) / 479; int left = (int)position;
                        mixed[i] += scratch[left] + (scratch[Math.Min(left + 1, count - 1)] - scratch[left]) * (position - left);
                    }
                }
                for (int i = 0; i < 480; ++i) mixed[i] = Math.Clamp(mixed[i], -1, 1);
                processor.Process(mixed, cleaned, settings, settings.Enabled);
                if (!output.Push(cleaned)) throw new InvalidOperationException("Playback queue overloaded.");
            }
        }
        catch (Exception e) { Error = e.Message; }
    }
    public async ValueTask DisposeAsync()
    {
        cancel.Cancel();
        foreach (var recorder in recorders) await recorder.DisposeAsync();
        if (player != null) await player.DisposeAsync();
        if (worker != null) await worker;
        processor.Dispose(); foreach (var device in devices) device.Dispose(); cancel.Dispose();
    }
    private sealed class OutputProvider(SampleRing samples) : IWaveProvider
    {
        public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(48000, 1);
        public int Read(byte[] buffer, int offset, int count)
            => Read(buffer.AsSpan(offset, count));
        public int Read(Span<byte> buffer)
        {
            var span = MemoryMarshal.Cast<byte, float>(buffer);
            int read = samples.Pop(span); span[read..].Clear(); return buffer.Length;
        }
    }
}
