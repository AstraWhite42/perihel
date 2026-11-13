using System;
using System.IO;
using System.Text.Json;

namespace Perihel;

internal enum Theme { System, Readable }
internal enum DepletionDirection { Counterclockwise, Clockwise }
internal enum MenuBarDisplay { Remaining, Budget, IconOnly }
internal enum ProgressStyle { CalendarDays, RollingDays, Continuous }

internal record Settings(string? CliPath = null, bool HasCompletedSetup = false,
    Theme Theme = Theme.System, DepletionDirection DepletionDirection = DepletionDirection.Counterclockwise,
    MenuBarDisplay MenuBarDisplay = MenuBarDisplay.Remaining, ProgressStyle ProgressStyle = ProgressStyle.CalendarDays)
{
    private static readonly string FilePath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Perihel", "settings.json");
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) {
        Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };
    public static Settings Load()
    {
        try
        {
            var fields = JsonSerializer.Deserialize<System.Collections.Generic.Dictionary<string, JsonElement>>(File.ReadAllText(FilePath));
            if (fields == null) return new();
            var prefs = new System.Collections.Generic.Dictionary<string, JsonElement>(fields, StringComparer.OrdinalIgnoreCase);
            string? Text(string key) => prefs.TryGetValue(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
            T Choice<T>(string key, T fallback) where T : struct, Enum =>
                Enum.TryParse<T>(Text(key), true, out var value) && Enum.IsDefined(value) ? value : fallback;
            var legacy = prefs.TryGetValue("showPercentage", out var old) && old.ValueKind == JsonValueKind.False;
            return new(Text("cliPath"), prefs.TryGetValue("hasCompletedSetup", out var done) && done.ValueKind == JsonValueKind.True,
                Choice("theme", Theme.System), Choice("depletionDirection", DepletionDirection.Counterclockwise),
                Choice("menuBarDisplay", legacy ? MenuBarDisplay.IconOnly : MenuBarDisplay.Remaining),
                Choice("progressStyle", ProgressStyle.CalendarDays));
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return new(); }
    }
    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        File.WriteAllText(FilePath + ".tmp", JsonSerializer.Serialize(this, Json));
        File.Move(FilePath + ".tmp", FilePath, true);
    }
}
