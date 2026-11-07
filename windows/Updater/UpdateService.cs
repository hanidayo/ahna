// 아나 — GitHub Releases 자동 업데이트 (Windows)
//
// 1. 시작 30초 뒤, 그리고 6시간마다 릴리스의 latest.json을 확인합니다.
//    {서버}/_ahna/update/latest.json
//    (API가 아니라 릴리스 파일 주소라 호출 횟수 제한이 없습니다.)
// 2. 새 버전이 있으면 Notify로 알립니다. 사용자가 알림을 누르거나 트레이의 [업데이트 확인]에서
//    설치하면 ZIP을 받아 SHA-256을 확인하고 %TEMP%에 풉니다.
// 3. apply-update.ps1(내장 리소스)을 실행하고 앱을 종료합니다. 스크립트가 종료를 기다린 뒤
//    %LOCALAPPDATA%\Programs\Ahna를 교체하고 아나를 다시 실행합니다.
//    설정·연결·기록은 %LOCALAPPDATA%\Ahna에 있어 그대로 유지됩니다.

using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http.Json;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json.Serialization;

namespace Ahna.Update;

public sealed record UpdateAsset(
    [property: JsonPropertyName("url")] string Url,
    [property: JsonPropertyName("sha256")] string Sha256,
    [property: JsonPropertyName("size")] long Size);

public sealed record UpdateManifest(
    [property: JsonPropertyName("version")] string Version,
    [property: JsonPropertyName("notesUrl")] string? NotesUrl,
    [property: JsonPropertyName("fullInstallRequired")] bool FullInstallRequired,
    [property: JsonPropertyName("platforms")] Dictionary<string, UpdateAsset> Platforms);

public sealed class UpdateService : IDisposable
{
    // 아나 서버가 업데이트 파일을 보관합니다(GitHub Actions가 빌드 후 자동으로 올림).
    public static readonly string ReleasesPage = Ahna.Remote.Brand.Server + "/_ahna/download";
    static readonly Uri ManifestUri = new(Ahna.Remote.Brand.Server + "/_ahna/update/latest.json");
    static readonly TimeSpan Interval = TimeSpan.FromHours(6);

    readonly HttpClient http = new(new SocketsHttpHandler { AllowAutoRedirect = true, MaxAutomaticRedirections = 5 })
    { Timeout = TimeSpan.FromMinutes(20) };
    readonly SemaphoreSlim gate = new(1, 1);
    System.Threading.Timer? timer;
    int installing;

    /// <summary>알림 표시: (제목, 내용, 누르면 설치할지). 백그라운드 스레드에서 호출될 수 있습니다.</summary>
    public Action<string, string, bool>? Notify { get; set; }
    /// <summary>설치 스크립트를 실행한 뒤 앱을 종료하는 방법(트레이의 ExitThread).</summary>
    public Action RequestExit { get; set; } = () => Environment.Exit(0);
    /// <summary>전송 중이면 설치를 미룹니다.</summary>
    public Func<bool> IsBusy { get; set; } = () => false;
    public UpdateManifest? Pending { get; private set; }
    /// <summary>마지막 확인이 실패했을 때의 이유(성공하면 null). 웹 옵션 화면이 결과를 보여 줄 때 씁니다.</summary>
    public string? LastError { get; private set; }
    public static string CurrentText => $"{Current.Major}.{Current.Minor}.{Current.Build}";
    public static Version Current { get; } = ReadCurrentVersion();

    public UpdateService() => http.DefaultRequestHeaders.UserAgent.ParseAdd($"Ahna-Windows/{CurrentText}");

    public void Start() => timer = new System.Threading.Timer(async _ => await CheckAsync(false), null, TimeSpan.FromSeconds(30), Interval);

    public async Task<UpdateManifest?> CheckAsync(bool userInitiated)
    {
        if (!await gate.WaitAsync(0)) return null;
        try
        {
            LastError = null;
            var manifest = await http.GetFromJsonAsync<UpdateManifest>(ManifestUri);
            if (manifest is null || !TryParseVersion(manifest.Version, out var latest) || !manifest.Platforms.ContainsKey("windows"))
                throw new InvalidDataException("업데이트 정보를 읽을 수 없습니다.");
            if (latest <= Current)
            {
                if (userInitiated) Notify?.Invoke("아나 업데이트", $"최신 버전입니다. (v{CurrentText})", false);
                return null;
            }
            Pending = manifest;
            if (manifest.FullInstallRequired)
            {
                Notify?.Invoke("아나 업데이트", $"v{manifest.Version}은 설치 파일로 직접 설치해야 합니다. 여기를 누르면 릴리스 페이지를 엽니다.", false);
                if (userInitiated) Open(manifest.NotesUrl ?? ReleasesPage);
                return manifest;
            }
            Notify?.Invoke("아나 업데이트", $"새 버전 v{manifest.Version}이 있습니다. 여기를 누르면 설치하고 다시 시작합니다.", true);
            return manifest;
        }
        catch (Exception e)
        {
            LastError = e.Message;
            if (userInitiated) Notify?.Invoke("아나 업데이트", "업데이트 확인 실패: " + e.Message, false);
            return null;
        }
        finally { gate.Release(); }
    }

    public async Task InstallPendingAsync()
    {
        var manifest = Pending ?? await CheckAsync(true);
        if (manifest is null || manifest.FullInstallRequired) return;
        if (IsBusy()) { Notify?.Invoke("아나 업데이트", "전송이 끝난 뒤 다시 눌러 주세요.", true); return; }
        if (Interlocked.Exchange(ref installing, 1) != 0) return;
        var asset = manifest.Platforms["windows"];
        // 시도마다 새 폴더를 씁니다. 앞선 시도의 설치 스크립트(PowerShell)가 아직 그 폴더를 쓰고 있으면
        // 지우지 못해 "다른 프로세스가 사용 중" 오류가 났습니다. 지난 폴더는 지울 수 있는 것만 지웁니다.
        var root = Path.Combine(Path.GetTempPath(), "Ahna-update");
        if (Directory.Exists(root))
            foreach (var old in Directory.GetDirectories(root))
                try { Directory.Delete(old, true); } catch { }
        var work = Path.Combine(root, manifest.Version + "-" + Guid.NewGuid().ToString("N")[..8]);
        try
        {
            Directory.CreateDirectory(work);
            var zip = Path.Combine(work, "package.zip");
            Notify?.Invoke("아나 업데이트", $"v{manifest.Version} 내려받는 중…", false);
            await using (var source = await http.GetStreamAsync(asset.Url))
            await using (var target = File.Create(zip))
                await source.CopyToAsync(target);

            await using (var check = File.OpenRead(zip))
            {
                var hash = Convert.ToHexString(await SHA256.HashDataAsync(check));
                if (!hash.Equals(asset.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("내려받은 파일이 손상되었습니다(SHA-256 불일치).");
            }
            var extracted = Path.Combine(work, "package");
            await Task.Run(() => ZipFile.ExtractToDirectory(zip, extracted));
            var app = Directory.GetDirectories(extracted, "app", SearchOption.AllDirectories).FirstOrDefault()
                      ?? throw new InvalidDataException("패키지에 app 폴더가 없습니다.");
            if (!File.Exists(Path.Combine(app, "Ahna.exe"))) throw new InvalidDataException("패키지에 Ahna.exe가 없습니다.");

            var script = Path.Combine(work, "apply-update.ps1");
            await using (var res = typeof(UpdateService).Assembly.GetManifestResourceStream("Ahna.Update.apply-update.ps1")
                                   ?? throw new InvalidOperationException("apply-update.ps1 리소스가 없습니다."))
            await using (var file = File.Create(script))
                await res.CopyToAsync(file);

            var install = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            var psi = new ProcessStartInfo("powershell.exe") { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetTempPath() };
            foreach (var a in new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", script,
                                      "-ProcessId", Environment.ProcessId.ToString(), "-Source", app, "-Destination", install,
                                      "-Version", manifest.Version })
                psi.ArgumentList.Add(a);
            Process.Start(psi);
            RequestExit();
        }
        catch (Exception e)
        {
            Interlocked.Exchange(ref installing, 0);
            Notify?.Invoke("아나 업데이트", "업데이트 설치 실패: " + e.Message, false);
        }
    }

    public static void Open(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });

    static bool TryParseVersion(string text, out Version version)
    {
        version = new Version(0, 0, 0);
        if (!Version.TryParse(text.TrimStart('v', 'V').Split('+', '-')[0], out var v)) return false;
        version = Normalize(v); return true;
    }
    static Version Normalize(Version v) => new(v.Major, v.Minor, Math.Max(0, v.Build));
    static Version ReadCurrentVersion()
    {
        var info = typeof(UpdateService).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        if (info is not null && TryParseVersion(info, out var v)) return v;
        return Normalize(typeof(UpdateService).Assembly.GetName().Version ?? new Version(0, 0, 0));
    }

    public void Dispose() { timer?.Dispose(); http.Dispose(); }
}
