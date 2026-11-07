using System.Security.Cryptography;
using System.Text.Json;

namespace Ahna;

/// Preview: 글자(클립보드) 전송이면 앞부분 한 줄
public sealed record HistoryItem(string Id, DateTimeOffset At, string Direction, string Name, long Bytes, string Device, string Status, string Session, string? Preview = null);
public sealed record ClipboardMessage(string Id, string Text, string Sender, string Target, DateTimeOffset Created)
{
    public int Bytes => System.Text.Encoding.UTF8.GetByteCount(Text);
}
public sealed class Preferences
{
    public string SavePath { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "아나");
    public bool Notifications { get; set; } = true;
    bool? recipientSavedNotifications;
    // Older settings used one switch for every notification. Preserve that choice
    // until the user saves an explicit choice for recipient confirmations.
    public bool RecipientSavedNotifications { get => recipientSavedNotifications ?? Notifications; set => recipientSavedNotifications = value; }
    public bool RemoteEnabled { get; set; }
    public string RemoteUrl { get; set; } = "";
    public string RemoteKeyProtected { get; set; } = "";
}
public sealed class Device(string id, string name, bool owner)
{
    public string Id { get; } = id;
    public string Name { get; set; } = name;
    public bool Owner { get; } = owner;
    public DateTimeOffset LastSeen { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset LastReceiverSeen { get; set; } = DateTimeOffset.MinValue;
    public bool Native { get; init; }
    public bool CanReceive { get; set; } = true;
    // The paired device's own receiver identity (32 hex), when its app reports it. Empty for older apps.
    public string ComputerId { get; set; } = "";
}
public sealed record ShareItem(string Id, string Name, string Path, long Bytes, string Target, bool Temporary, DateTimeOffset Created)
{
    public int DeliveryNotified;
    public int ReceiptRank;
}
public static class Util
{
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { WriteIndented = true };
    public static string Token() => Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
    public static string DeviceName(string value)
    {
        var name = value.Trim().Normalize(System.Text.NormalizationForm.FormC);
        if (name.Length is 0 or > 40 || name.Any(char.IsControl)) throw new ArgumentException("기기 이름은 1~40자로 입력하세요.");
        return name;
    }
    public static void SaveJson<T>(string path, T value)
    {
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(value, Json));
        File.Move(tmp, path, true);
    }
    public static string SafeRelative(string name)
    {
        if (string.IsNullOrWhiteSpace(name) || name.Length > 1000 || Path.IsPathRooted(name)) throw new ArgumentException("올바르지 않은 파일 경로입니다.");
        // Apple file providers can send decomposed Hangul; compose names before
        // validating and resolving collisions on the Windows filesystem.
        name = name.Normalize(System.Text.NormalizationForm.FormC);
        var parts = name.Replace('\\', '/').Split('/');
        foreach (var p in parts)
        {
            var stem = p.Split('.')[0].ToUpperInvariant();
            if (p.Length is 0 or > 180 || p is "." or ".." || p.EndsWith(' ') || p.EndsWith('.') || p.Any(c => c < 32 || "<>:\"|?*".Contains(c)) ||
                stem is "CON" or "PRN" or "AUX" or "NUL" or "CLOCK$" ||
                (stem.Length == 4 && (stem.StartsWith("COM") || stem.StartsWith("LPT")) && "123456789¹²³".Contains(stem[3])))
                throw new ArgumentException("Windows에서 저장할 수 없는 파일 이름입니다.");
        }
        return Path.Combine(parts);
    }
    public static void NoLinks(string path)
    {
        for (var p = Path.GetFullPath(path); !string.IsNullOrEmpty(p); p = Path.GetDirectoryName(p))
            if ((File.Exists(p) || Directory.Exists(p)) && File.GetAttributes(p).HasFlag(FileAttributes.ReparsePoint))
                throw new ArgumentException("연결 폴더/심볼릭 링크는 지원하지 않습니다.");
    }
}
