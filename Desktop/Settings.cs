using System.Text.Json;

namespace Noise;

public sealed class ChannelSettings
{
    // Live routes are deliberately not resumed after launch without a user action.
    public bool Leveling { get; set; } = true;
    public double Strength { get; set; } = 1;
    public int Engine { get; set; }
    public bool MainSpeaker { get; set; }
    [System.Text.Json.Serialization.JsonIgnore] public bool Enabled { get; set; }
    public int RuntimeEngine => MainSpeaker ? 3 : Engine;
}

public sealed class Settings
{
    public ChannelSettings Speaker { get; set; } = new();
    public ChannelSettings Microphone { get; set; } = new();
    public List<string> Applications { get; set; } = [];
    public string IncomingDevice { get; set; } = "";
    public string MicrophoneDevice { get; set; } = "";
    public string CleanMicrophoneDevice { get; set; } = "";
    public static string FilePath => Path.Combine(Environment.GetEnvironmentVariable("NOISE_DATA_DIR") ?? Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Noise", "settings.json");
    public static Settings Load()
    {
        try
        {
            var value = JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new();
            value.Speaker ??= new(); value.Microphone ??= new(); value.Applications ??= [];
            foreach (var c in new[] { value.Speaker, value.Microphone })
            { c.Strength = double.IsFinite(c.Strength) ? Math.Clamp(c.Strength, 0, 1) : 1; c.Engine = Math.Clamp(c.Engine, 0, 2); }
            return value;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return new(); }
    }
    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        var temporary = FilePath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, FilePath, true);
    }
}

public record AudioDevice(string Id, string Name) { public override string ToString() => Name; }
public record AudioApplication(string Id, string Name) { public override string ToString() => Name; }

public interface IAudioBackend : IAsyncDisposable
{
    bool AutomaticAppRouting => false;
    bool CanPickWindow => true;
    bool HasTrayHost => true;
    void SettingsChanged() { }
    string SetupInstructions { get; }
    IReadOnlyList<AudioDevice> Outputs();
    IReadOnlyList<AudioDevice> Inputs();
    IReadOnlyList<AudioApplication> Applications();
    AudioApplication? CurrentApplication();
    Task<AudioApplication?> PickWindow(CancellationToken cancel);
    Task StartSpeaker(Settings settings);
    Task StartMicrophone(Settings settings);
    Task StopSpeaker();
    Task StopMicrophone();
    void Update();
    string? PollError();
    bool SpeakerRunning { get; }
    bool MicrophoneRunning { get; }
}
