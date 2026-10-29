using System.Collections.Concurrent;
using System.IO.Compression;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Ahna;

public sealed class TransferServer : IAsyncDisposable
{
    public const long MaxFile = 4L * 1024 * 1024 * 1024;
    public const int MaxClipboardBytes = 64 * 1024;
    readonly Dictionary<string, ClipboardMessage> clipboardMessages = new();
    readonly string data;
    readonly string computerId;
    readonly object gate = new();
    readonly ConcurrentDictionary<string, Device> sessions = new();
    readonly ConcurrentDictionary<string, ShareItem> shares = new();
    readonly SemaphoreSlim uploads = new(2, 2);
    readonly List<HistoryItem> history;
    readonly Dictionary<string, (int Count, DateTimeOffset Since)> attempts = new();
    int globalAttempts;
    DateTimeOffset attemptWindow = DateTimeOffset.UtcNow;
    WebApplication? app;
    int disposed;
    Ahna.Remote.RemoteBridge? bridge;
    public string RemoteStatus => bridge?.Status ?? "서버 연결 꺼짐";
    public Preferences Settings { get; private set; }
    // 이 컴퓨터 주인 화면의 비밀값. 업데이트로 다시 시작해도 열려 있던 아나 창이 그대로 쓰도록 저장해 둡니다.
    public string OwnerSecret { get; private set; } = Util.Token();
    public string Pin { get; private set; } = RandomNumberGenerator.GetInt32(100000, 1000000).ToString();
    public int Port { get; }
    public event Action<string>? Received;
    public event Action<string>? SendPrepared;
    public event Action<string>? Delivered;
    public event Action<string>? ClientSaved;
    public event Action<string>? ClipboardReceived;
    /// 서버 관리자가 보낸 알림(action: limit·message·rejoin·blocked, text). rejoin·blocked면 서버 연결 정보를 지웁니다.
    public event Action<string, string>? ServerNotice;
    public Action? ClipboardRequested;
    public Func<string, Task>? PickRequested;
    public Action? SettingsRequested;
    // Owner options page hooks. The host app (Windows tray) supplies platform features;
    // when a hook is not set the matching option is reported as unavailable.
    public Func<IntegrationState>? IntegrationsRead;
    public Action<IntegrationState>? IntegrationsWrite;
    public Func<Task<string?>>? FolderPickRequested;
    public Func<bool, Task<UpdateState>>? UpdateRequested;
    public Action? ReceivedFolderRequested;
    // Owner page drag & drop to a device this computer added (outbound). The host answers whether it
    // owns the target id, and starts sending the staged files (it then owns and deletes the folder).
    public Func<string, bool>? ExternalDropOwns;
    public Action<string, string, string[]>? ExternalDrop;
    // Devices this computer paired with as a client (서버 address + their 6-digit code).
    public IExternalDevices? ExternalDevices { get; set; }
    // Reverse pairing: a device that pairs here may also hand over a session on ITS own host, so one code
    // entry connects both ways. The host app stores it as an outbound connection and returns true when kept.
    // Not set (or false) means the requester only gets today's one-way session.
    public Func<ReverseCredential, bool>? ReverseReceived { get; set; }
    // Sessions minted by ReverseOffer while that pairing is still in progress: valid, but not listed or saved yet.
    readonly HashSet<string> reservedSessions = new();
    public string AppVersion { get; set; } = ReadAppVersion();
    // This receiver's identity (X-Ahna-Computer). Our own outbound client sends it when pairing
    // with other hosts, so they can show this computer once even if it also added them.
    public string ComputerId => computerId;
    public string LocalUrl => $"http://127.0.0.1:{Port}/";
    public string OwnerUrl => LocalUrl + "#owner=" + OwnerSecret;
    public string[] Addresses => string.IsNullOrWhiteSpace(Settings.RemoteUrl) ? [] : [Settings.RemoteUrl];
    // 1.2 nearby devices (Bluetooth) and QR: one-time guest tickets served at /s/{computer}/{token} through the 서버 relay.
    readonly ConcurrentDictionary<string, GuestTicket> tickets = new();
    string? webRootPath;
    // The name guests see ("…님이 파일을 보냈습니다", the Bluetooth card).
    public string GuestOwnerName { get; set; } = CleanName(Environment.MachineName, "컴퓨터");
    // A guest asked to upload to a receive ticket. The host shows a confirmation and answers with AnswerGuest
    // (30 seconds, then the request is declined). Not set: guest uploads are always declined.
    public Action<GuestTicket>? GuestRequested;
    // Any ticket state change (request, accepted, progress milestones, done, declined, expired).
    public event Action<GuestTicket>? GuestChanged;
    // Owner page: nearby devices and the QR window, supplied by the host app (Windows: Bluetooth LE).
    public INearbyHost? NearbyHost { get; set; }

    public TransferServer(string dataPath, int port)
    {
        data = dataPath; Port = port;
        Directory.CreateDirectory(data);
        var identityPath=Path.Combine(data,"computer-id.txt");
        computerId=File.Exists(identityPath)?File.ReadAllText(identityPath).Trim():Guid.NewGuid().ToString("N");
        if(!Guid.TryParseExact(computerId,"N",out _))throw new InvalidDataException("Invalid computer identity");
        if(!File.Exists(identityPath))File.WriteAllText(identityPath,computerId);
        var ownerPath=Path.Combine(data,"owner-secret.txt");
        try{if(File.Exists(ownerPath)&&RemoteKey.Unprotect(File.ReadAllText(ownerPath).Trim()) is { Length: >=20 } savedOwner)OwnerSecret=savedOwner;else File.WriteAllText(ownerPath,RemoteKey.Protect(OwnerSecret));}catch{}
        Settings = File.Exists(Path.Combine(data, "settings.json")) ? JsonSerializer.Deserialize<Preferences>(File.ReadAllText(Path.Combine(data, "settings.json")), Util.Json)! : new();
        history = File.Exists(Path.Combine(data, "history.json")) ? JsonSerializer.Deserialize<List<HistoryItem>>(File.ReadAllText(Path.Combine(data, "history.json")), Util.Json) ?? [] : [];
        try
        {
            var saved=Path.Combine(data,"native-sessions.json");
            if(File.Exists(saved))foreach(var s in JsonSerializer.Deserialize<NativeSession[]>(RemoteKey.Unprotect(File.ReadAllText(saved)),Util.Json)??[])
                if(s.LastSeen>DateTimeOffset.UtcNow.AddDays(-30))sessions[s.Token]=new(s.Id,s.Name,false){Native=true,CanReceive=s.CanReceive,LastSeen=s.LastSeen,ComputerId=PeerIdentity(s.ComputerId)};
        }catch{}
        // 아나: the server is fixed by the build; only the member token (from the invite code) is stored.
        if(Ahna.Remote.Brand.Ahna) Settings.RemoteUrl = Ahna.Remote.Brand.Server;
        Settings.RemoteEnabled = !string.IsNullOrEmpty(Settings.RemoteKeyProtected);
        if(history.Count>20) history.RemoveRange(20,history.Count-20);
        // Only our own transient folder is cleaned, never the receive directory.
        var cache = Path.Combine(data, "outbox");
        Directory.CreateDirectory(cache);
        foreach (var f in Directory.GetFiles(cache)) { try { File.Delete(f); } catch { } }
    }
    // 아나 server sign-up: POST {server}/_ahna/join {invite, computer} → {token}
    public async Task<string> JoinServer(string server, string invite, CancellationToken ct)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        HttpResponseMessage response;
        try { response = await http.PostAsync(server.TrimEnd('/') + "/_ahna/join", new StringContent(JsonSerializer.Serialize(new { invite, computer = computerId, name = GuestOwnerName, platform = OperatingSystem.IsMacOS() ? "Mac" : "Windows" }), Encoding.UTF8, "application/json"), ct); }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException) { throw new ArgumentException("서버에 연결하지 못했습니다. 인터넷 연결을 확인한 뒤 다시 시도하세요."); }
        using (response)
        {
            var body = await response.Content.ReadAsStringAsync(ct);
            string? Field(string name) { try { using var d = JsonDocument.Parse(body); return d.RootElement.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null; } catch (JsonException) { return null; } }
            if ((int)response.StatusCode == 404) throw new ArgumentException("서버에 초대 코드가 설정되지 않았습니다. 서버 관리자에게 알려 주세요.");
            if ((int)response.StatusCode == 429) throw new ArgumentException("초대 코드를 너무 많이 시도했습니다. 10분 뒤에 다시 시도하세요.");
            if (!response.IsSuccessStatusCode) throw new ArgumentException(Field("error") ?? $"연결하지 못했습니다 ({(int)response.StatusCode}).");
            var token = Field("token") ?? "";
            if (!Ahna.Remote.Brand.IsMemberToken(token)) throw new ArgumentException("서버 응답이 올바르지 않습니다.");
            return token;
        }
    }
    /// 서버에서 초기화·차단되면 연결 키를 지워, 초대 코드를 다시 입력하는 화면이 나오게 합니다.
    void ForgetServer()
    {
        lock (gate) { if (string.IsNullOrEmpty(Settings.RemoteKeyProtected)) return; Settings.RemoteKeyProtected = ""; Settings.RemoteEnabled = false; Util.SaveJson(Path.Combine(data, "settings.json"), Settings); }
        bridge?.Reload();
    }
    // ── 전체 공지 (서버 관리자) ──
    // 서버에 연결할 때마다 받아 오고, 읽음·지움은 이 기기에 저장합니다. 읽은 공지는 3일 뒤 보이지 않습니다.
    public sealed record Announcement(string Id, string Text, DateTimeOffset Created, bool Read);
    sealed class NoticeState { public Dictionary<string, DateTimeOffset> Read { get; set; } = new(); public HashSet<string> Deleted { get; set; } = new(); }
    readonly object noticeGate = new();
    (string Id, string Text, DateTimeOffset Created)[] serverNotices = [];
    NoticeState? noticeState;
    readonly HashSet<string> announced = new();
    static readonly TimeSpan ReadNoticeLife = TimeSpan.FromDays(3);
    /// 새로 받은 읽지 않은 공지(알림·팝업용, 실행 중 한 번씩)
    public event Action<Announcement[]>? NewAnnouncements;
    NoticeState NoticeStore()
    {
        if (noticeState is not null) return noticeState;
        try { var f = Path.Combine(data, "notices.json"); noticeState = File.Exists(f) ? JsonSerializer.Deserialize<NoticeState>(File.ReadAllText(f), Util.Json) ?? new() : new(); }
        catch { noticeState = new(); }
        return noticeState;
    }
    void SaveNoticeStore() { try { Util.SaveJson(Path.Combine(data, "notices.json"), noticeState); } catch { } }
    public Announcement[] Announcements()
    {
        lock (noticeGate)
        {
            var st = NoticeStore(); var now = DateTimeOffset.UtcNow;
            return serverNotices.Where(n => !st.Deleted.Contains(n.Id) && !(st.Read.TryGetValue(n.Id, out var at) && now - at > ReadNoticeLife))
                .Select(n => new Announcement(n.Id, n.Text, n.Created, st.Read.ContainsKey(n.Id))).ToArray();
        }
    }
    HttpRequestMessage? NoticeRequest(HttpMethod method, string path)
    {
        string key; try { key = string.IsNullOrEmpty(Settings.RemoteKeyProtected) ? "" : RemoteKey.Unprotect(Settings.RemoteKeyProtected); } catch { return null; }
        if (!Ahna.Remote.Brand.IsMemberToken(key) || string.IsNullOrEmpty(Settings.RemoteUrl)) return null;
        var request = new HttpRequestMessage(method, Settings.RemoteUrl.TrimEnd('/') + path);
        request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + key); return request;
    }
    public async Task RefreshAnnouncements()
    {
        try
        {
            using var request = NoticeRequest(HttpMethod.Get, "/_ahna/notices"); if (request is null) return;
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
            using var response = await http.SendAsync(request);
            if (!response.IsSuccessStatusCode) return;
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            var list = doc.RootElement.GetProperty("notices").EnumerateArray()
                .Select(n => (Id: n.GetProperty("id").GetString() ?? "", Text: n.GetProperty("text").GetString() ?? "", Created: DateTimeOffset.FromUnixTimeSeconds(n.GetProperty("created").GetInt64())))
                .Where(n => n.Id.Length is > 0 and <= 32 && n.Text.Length > 0).Take(30).ToArray();
            Announcement[] fresh;
            lock (noticeGate)
            {
                serverNotices = list;
                var st = NoticeStore(); var ids = list.Select(n => n.Id).ToHashSet();
                // 서버에서 지운 공지의 기록은 정리
                if (st.Read.Keys.Any(k => !ids.Contains(k)) || st.Deleted.Any(k => !ids.Contains(k)))
                { foreach (var k in st.Read.Keys.Where(k => !ids.Contains(k)).ToArray()) st.Read.Remove(k); st.Deleted.RemoveWhere(k => !ids.Contains(k)); SaveNoticeStore(); }
                fresh = list.Where(n => !st.Read.ContainsKey(n.Id) && !st.Deleted.Contains(n.Id) && announced.Add(n.Id)).Select(n => new Announcement(n.Id, n.Text, n.Created, false)).ToArray();
            }
            if (fresh.Length > 0) try { NewAnnouncements?.Invoke(fresh); } catch { }
        }
        catch { }
    }
    public void ReadAnnouncement(string id)
    {
        lock (noticeGate) { var st = NoticeStore(); if (!serverNotices.Any(n => n.Id == id) || st.Read.ContainsKey(id)) return; st.Read[id] = DateTimeOffset.UtcNow; SaveNoticeStore(); }
        _ = Task.Run(async () =>
        {
            try { using var request = NoticeRequest(HttpMethod.Post, "/_ahna/notices/" + Uri.EscapeDataString(id) + "/read"); if (request is null) return; using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) }; using var response = await http.SendAsync(request); }
            catch { }
        });
    }
    /// 읽은 공지 지우기
    public void DeleteAnnouncement(string id) { lock (noticeGate) { var st = NoticeStore(); if (!st.Read.ContainsKey(id) || !st.Deleted.Add(id)) return; SaveNoticeStore(); } }
    public void ClearHistory() { lock(gate) { history.Clear(); Util.SaveJson(Path.Combine(data,"history.json"),history); } }
    public HistoryItem[] HistorySnapshot() { lock(gate) return history.Take(20).ToArray(); }
    public void SaveSettings(Preferences settings)
    {
        settings.RemoteEnabled = !string.IsNullOrEmpty(settings.RemoteKeyProtected);
        if(settings.RemoteEnabled)Ahna.Remote.RemoteBridge.Validate(new(settings.RemoteUrl,RemoteKey.Unprotect(settings.RemoteKeyProtected)));
        if(!Path.IsPathFullyQualified(settings.SavePath))throw new ArgumentException("저장 폴더는 전체 경로로 지정하세요. ‘저장 폴더 선택’을 이용하면 편리합니다.");
        var path = Path.GetFullPath(settings.SavePath);
        Util.NoLinks(path); Directory.CreateDirectory(path); Util.NoLinks(path);
        using(var writable=new FileStream(Path.Combine(path,".ahna-write-test-"+Guid.NewGuid().ToString("N")),FileMode.CreateNew,FileAccess.Write,FileShare.None,1,FileOptions.DeleteOnClose)){}
        lock (gate) { settings.SavePath = path; Util.SaveJson(Path.Combine(data, "settings.json"), settings); Settings = settings; }
        bridge?.Reload();
    }
    void Record(string direction, string name, long bytes, Device device, string status)
    {
        lock (gate)
        {
            history.Insert(0, new(Guid.NewGuid().ToString("N"), DateTimeOffset.UtcNow, direction, name, bytes, device.Name, status, device.Id));
            if (history.Count > 20) history.RemoveRange(20, history.Count - 20);
            Util.SaveJson(Path.Combine(data, "history.json"), history);
        }
    }
    void SaveNativeSessions()
    {
        lock(gate)
        {
            var snapshot=sessions.Where(s=>s.Value.Native && !s.Value.Owner && !reservedSessions.Contains(s.Key)).Select(s=>new NativeSession(s.Key,s.Value.Id,s.Value.Name,s.Value.LastSeen,s.Value.CanReceive,s.Value.ComputerId)).ToArray();
            var file=Path.Combine(data,"native-sessions.json");var temporary=file+".tmp";
            File.WriteAllText(temporary,RemoteKey.Protect(JsonSerializer.Serialize(snapshot,Util.Json)));File.Move(temporary,file,true);
        }
    }
    public async Task StartAsync(string webRoot)
    {
        webRootPath = webRoot;
        var builder = WebApplication.CreateBuilder(new WebApplicationOptions { Args = [], ContentRootPath = AppContext.BaseDirectory, WebRootPath = webRoot });
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(k => { k.ListenLocalhost(Port); k.Limits.MaxRequestBodySize = MaxFile; k.Limits.RequestHeadersTimeout = TimeSpan.FromSeconds(15); });
        app = builder.Build();
        app.Use(async (ctx, next) =>
        {
            ctx.Response.Headers["X-Content-Type-Options"] = "nosniff";
            ctx.Response.Headers["Referrer-Policy"] = "no-referrer";
            ctx.Response.Headers["Cache-Control"] = "no-store";
            ctx.Response.Headers["X-Ahna-Computer"] = computerId;
            ctx.Response.Headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; form-action 'self'; base-uri 'none'";
            var host = ctx.Request.Host.Host;
            if (!(host.Equals("localhost", StringComparison.OrdinalIgnoreCase) || IPAddress.TryParse(host, out _))) { ctx.Response.StatusCode = 400; return; }
            var origin = ctx.Request.Headers.Origin.ToString();
            if ((origin.Length > 0 && origin != $"{ctx.Request.Scheme}://{ctx.Request.Host}") || ctx.Request.Headers["Sec-Fetch-Site"] == "cross-site") { ctx.Response.StatusCode = 403; return; }
            try { await next(ctx); }
            catch (Exception ex) when (!ctx.Response.HasStarted)
            {
                ctx.Response.StatusCode = ex is ArgumentException or JsonException ? 400 : ex is BadHttpRequestException bad ? bad.StatusCode : 500;
                await ctx.Response.WriteAsJsonAsync(new { error = ex is ArgumentException ? ex.Message : "요청을 완료하지 못했습니다. 파일 크기, 남은 공간과 연결을 확인하세요." });
            }
        });
        app.MapPost("/api/pair", async (HttpContext c) =>
        {
            var input = await c.Request.ReadFromJsonAsync<PairInput>();
            if (input is null) return Results.BadRequest();
            var ip = c.Connection.RemoteIpAddress?.ToString() ?? "unknown";
            lock (gate)
            {
                var now = DateTimeOffset.UtcNow;
                if (now - attemptWindow > TimeSpan.FromMinutes(1)) { globalAttempts = 0; attemptWindow = now; }
                var a = attempts.GetValueOrDefault(ip);
                if (now - a.Since > TimeSpan.FromMinutes(1)) a = (0, now);
                if (a.Count >= 10 || globalAttempts >= 60) return Results.StatusCode(429);
                attempts[ip] = (a.Count + 1, a.Since); globalAttempts++;
            }
            if (input.Pin != Pin) return Results.Json(new { error = "연결 코드가 맞지 않습니다." }, statusCode: 401);
            if (sessions.Count > 100) return Results.StatusCode(429);
            var name = new string((input.Name ?? "브라우저").Where(c => !char.IsControl(c)).Take(40).ToArray());
            var token = Util.Token(); var d = new Device(Guid.NewGuid().ToString("N"), string.IsNullOrWhiteSpace(name) ? "브라우저" : name, false){Native=input.Native,CanReceive=input.CanReceive,LastReceiverSeen=input.CanReceive?DateTimeOffset.UtcNow:DateTimeOffset.MinValue,ComputerId=input.Native?PeerIdentity(input.ComputerID):""};
            // Pairing again from the same device replaces its earlier session, so it is listed once.
            if(d.ComputerId.Length>0)foreach(var old in sessions.Where(x=>!x.Value.Owner && x.Value.ComputerId==d.ComputerId).ToArray())sessions.TryRemove(old.Key,out _);
            sessions[token] = d; Cookie(c, token,input.Native);if(input.Native)SaveNativeSessions();
            // The requester's own session for us (reverse pairing). Older apps never send it; older hosts ignore it.
            var reverse = false;
            if (input.Native && ReverseReceived is { } accept && ReverseFrom(input.Reverse) is { } credential)
            {
                try { reverse = accept(credential); } catch { reverse = false; }
            }
            return Results.Ok(new { d.Id, d.Name, reverse });
        });
        app.MapPost("/api/owner", (HttpContext c) =>
        {
            if (!IsLoopback(c) || c.Request.Headers["X-Ahna-Owner"] != OwnerSecret) return Results.Unauthorized();
            var token = Util.Token(); var d = new Device("windows", Environment.MachineName, true);
            sessions[token] = d; Cookie(c, token); return Results.Ok();
        });
        app.MapGet("/api/state", (HttpContext c) =>
        {
            var d = Authenticate(c); if (d is null) return Results.Unauthorized();
            var receiving=d.CanReceive;
            if(d.Native && c.Request.Query.TryGetValue("receiving",out var value) && (value.Count!=1 || !bool.TryParse(value.ToString(),out receiving)))return Results.BadRequest();
            // Native polling is also a heartbeat for the device's saved display name.
            // Keeping this on the existing route lets older 서버 relays pass it through.
            if (c.Request.Query.TryGetValue("deviceName", out var requestedName))
            {
                if (!d.Native || d.Owner || requestedName.Count != 1) return Results.BadRequest();
                var name = Util.DeviceName(requestedName.ToString());
                lock (gate) { if (d.Name != name) { d.Name = name; SaveNativeSessions(); } }
            }
            // Newer clients also report their own receiver identity on the heartbeat, so sessions
            // paired by an older version learn it without pairing again. Invalid values are ignored.
            if (d.Native && !d.Owner && c.Request.Query.TryGetValue("computerID", out var reportedIdentity) && reportedIdentity.Count == 1)
            {
                var identity = PeerIdentity(reportedIdentity.ToString());
                lock (gate) { if (identity.Length > 0 && d.ComputerId != identity) { d.ComputerId = identity; SaveNativeSessions(); } }
            }
            var now = DateTimeOffset.UtcNow;
            if(d.Native)
            {
                if(receiving)
                {
                    d.LastReceiverSeen=now;
                    if(!d.CanReceive){d.CanReceive=true;SaveNativeSessions();}
                }
            }
            var devices = d.Owner ? sessions.Values.Where(x => IsReceiving(x,now)).DistinctBy(x => x.Id).Select(x => new { x.Id, x.Name, computerID = x.ComputerId }).ToArray() : [];
            var peers = d.Owner ? Peers().Select(x => new { id = x.Id, name = x.Name, computerID = x.ComputerId, online = x.Online }).ToArray() : [];
            var items = shares.Values.Where(x => (d.Owner || x.Target == d.Id) && now - x.Created < TimeSpan.FromHours(24)).OrderByDescending(x => x.Created).Select(x => new { x.Id, x.Name, x.Bytes, x.Target }).ToArray();
            HistoryItem[] recent; lock (gate) recent = history.Where(h => d.Owner || h.Session == d.Id).Take(20).ToArray();
            var clipboard = ClipboardInbox(d.Owner ? "windows" : d.Id).Select(x => new { x.Id, x.Sender, x.Bytes, x.Created });
            return Results.Json(new { id = d.Id, name = d.Name, version = AppVersion, hostName = Environment.MachineName, platform = OperatingSystem.IsMacOS()?"Mac":"Windows", owner = d.Owner, pin = d.Owner ? Pin : null, urls = d.Owner ? Addresses.Concat(Settings.RemoteEnabled?new[]{Settings.RemoteUrl}:[]).Distinct(StringComparer.OrdinalIgnoreCase).ToArray() : [], remoteStatus = d.Owner ? RemoteStatus : null, savePath = d.Owner ? Settings.SavePath : null, devices, items, clipboard, maxClipboardBytes = MaxClipboardBytes, history = recent, maxFile = MaxFile, outbound = d.Owner ? ExternalDevices?.Snapshot() : null, peers, announcements = d.Owner ? Announcements() : null });
        });
        app.MapPost("/api/logout", (HttpContext c) => { if (c.Request.Cookies.TryGetValue("ahna", out var t)) sessions.TryRemove(t, out _);SaveNativeSessions(); c.Response.Cookies.Delete("ahna"); return Results.Ok(); });
        app.MapPost("/api/upload", (Delegate)Upload);
        app.MapGet("/api/download/{id}", Download);
        app.MapPost("/api/received/{id}", async (HttpContext c) =>
        {
            var d=Authenticate(c);if(d is null)return Results.Unauthorized();
            var id=c.Request.RouteValues["id"]?.ToString()??"";
            if(!shares.TryGetValue(id,out var item)||item.Target!=d.Id||DateTimeOffset.UtcNow-item.Created>TimeSpan.FromHours(24))return Results.NotFound();
            if(c.Request.ContentLength is >4096)return Results.BadRequest();
            using var body=new MemoryStream();var buffer=new byte[1024];int read;
            while((read=await c.Request.Body.ReadAsync(buffer,c.RequestAborted))>0)
            {
                if(body.Length+read>4096)return Results.BadRequest();
                body.Write(buffer,0,read);
            }
            var receipt=JsonSerializer.Deserialize<ReceiptInput>(body.ToArray(),Util.Json);
            if(receipt?.Destination is not ("files" or "photos"))return Results.BadRequest();
            var rank=receipt.Destination=="photos"?2:1;
            while(true)
            {
                var previous=Volatile.Read(ref item.ReceiptRank);if(previous>=rank)break;
                if(Interlocked.CompareExchange(ref item.ReceiptRank,rank,previous)!=previous)continue;
                var status=rank==2?"상대 기기 사진 앱 저장 완료":"상대 기기 파일 앱 저장 완료";
                Record("send",item.Name,item.Bytes,d,status);
                try{ClientSaved?.Invoke($"{d.Name} · {item.Name}\n{status}");}catch{}
                break;
            }
            return Results.Ok();
        });
        app.MapPost("/api/admin/pick", async (HttpContext c) =>
        {
            var d = Authenticate(c); if (d?.Owner != true) return Results.Unauthorized();
            var request = await c.Request.ReadFromJsonAsync<TargetInput>();
            if (request is null || !sessions.Values.Any(x => x.Id == request.Target && !x.Owner)) return Results.BadRequest(new { error = "받을 기기를 먼저 연결하세요." });
            if (PickRequested is null) return Results.StatusCode(503);
            await PickRequested(request.Target); return Results.Ok();
        });
        app.MapPost("/api/admin/announcements/{id}/read", (string id, HttpContext c) => { if (Authenticate(c)?.Owner != true) return Results.Unauthorized(); ReadAnnouncement(id); return Results.Ok(); });
        app.MapPost("/api/admin/announcements/{id}/delete", (string id, HttpContext c) => { if (Authenticate(c)?.Owner != true) return Results.Unauthorized(); DeleteAnnouncement(id); return Results.Ok(); });
        app.MapPost("/api/admin/history/clear", (HttpContext c) => { if(Authenticate(c)?.Owner != true) return Results.Unauthorized(); ClearHistory(); return Results.Ok(); });
        app.MapPost("/api/admin/settings", (HttpContext c) => { if (Authenticate(c)?.Owner != true) return Results.Unauthorized(); SettingsRequested?.Invoke(); return Results.Ok(); });
        app.MapGet("/api/version", () => Results.Json(new { version = AppVersion }));
        app.MapGet("/api/admin/options", (HttpContext c) => Authenticate(c)?.Owner != true ? Results.Unauthorized() : Results.Json(OptionsSnapshot()));
        app.MapPost("/api/admin/options", async (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            var input = await c.Request.ReadFromJsonAsync<OptionsInput>();
            if (input is null) return Results.BadRequest();
            try
            {
                var key = (input.NasKey ?? "").Trim();
                var remoteUrl = Ahna.Remote.Brand.Ahna ? Ahna.Remote.Brand.Server : (input.RemoteUrl ?? "").Trim().TrimEnd('/');
                // 아나: the key box takes the invite code; the server answers with this computer's member token.
                if (Ahna.Remote.Brand.Ahna && key.Length > 0 && !Ahna.Remote.Brand.IsMemberToken(key)) key = await JoinServer(remoteUrl, key, c.RequestAborted);
                SaveSettings(new Preferences
                {
                    SavePath = string.IsNullOrWhiteSpace(input.SavePath) ? Settings.SavePath : input.SavePath.Trim(),
                    Notifications = input.Notifications,
                    RecipientSavedNotifications = input.RecipientSavedNotifications,
                    RemoteUrl = remoteUrl,
                    RemoteKeyProtected = key.Length > 0 ? RemoteKey.Protect(key) : Settings.RemoteKeyProtected
                });
                if (IntegrationsWrite is not null && input.Startup is bool startup && input.ExplorerMenu is bool explorerMenu)
                    IntegrationsWrite(new IntegrationState(startup, explorerMenu));
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                return Results.Json(new { error = ex.Message }, statusCode: 400);
            }
            return Results.Json(OptionsSnapshot());
        });
        app.MapPost("/api/admin/pick-folder", async (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            if (FolderPickRequested is null) return Results.Json(new { error = "이 컴퓨터에서는 폴더 선택 창을 열 수 없습니다." }, statusCode: 503);
            var path = await FolderPickRequested();
            return Results.Json(new { path });
        });
        app.MapPost("/api/admin/open-folder", (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            if (ReceivedFolderRequested is null) return Results.Json(new { error = "이 컴퓨터에서는 폴더를 열 수 없습니다." }, statusCode: 503);
            ReceivedFolderRequested(); return Results.Ok();
        });
        app.MapPost("/api/admin/update-check", async (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            if (UpdateRequested is null) return Results.Json(new { error = "이 실행에서는 업데이트를 확인할 수 없습니다." }, statusCode: 503);
            return Results.Json(await UpdateRequested(false));
        });
        app.MapPost("/api/admin/update-install", async (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            if (UpdateRequested is null) return Results.Json(new { error = "이 실행에서는 업데이트를 설치할 수 없습니다." }, statusCode: 503);
            return Results.Json(await UpdateRequested(true));
        });
        app.MapGet("/api/admin/devices", (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            var external = ExternalDevices; if (external is null) return ExternalUnavailable();
            return Results.Json(external.Snapshot());
        });
        app.MapPost("/api/admin/devices/pair", async (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            var external = ExternalDevices; if (external is null) return ExternalUnavailable();
            var input = await ReadSmallJson<ExternalPairInput>(c, 8192);
            if (input is null) return Results.BadRequest();
            try { return Results.Json(await external.PairAsync(input.Address ?? "", input.Pin ?? "")); }
            catch (Exception ex) when (IsExternalFailure(ex)) { return Results.Json(new { error = ex.Message }, statusCode: 400); }
        });
        app.MapPost("/api/admin/devices/cancel", (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            var external = ExternalDevices; if (external is null) return ExternalUnavailable();
            external.CancelSend(); return Results.Ok();
        });
        app.MapPost("/api/admin/devices/{id}/remove", async (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            var external = ExternalDevices; if (external is null) return ExternalUnavailable();
            try { await external.RemoveAsync(c.Request.RouteValues["id"]?.ToString() ?? ""); return Results.Ok(); }
            catch (Exception ex) when (IsExternalFailure(ex)) { return Results.Json(new { error = ex.Message }, statusCode: 400); }
        });
        app.MapPost("/api/admin/devices/{id}/send-text", async (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            var external = ExternalDevices; if (external is null) return ExternalUnavailable();
            var input = await ReadSmallJson<ExternalTextInput>(c, MaxClipboardBytes * 6 + 4096);
            if (input is null) return Results.BadRequest();
            try { ValidateClipboard(input.Text); await external.SendTextAsync(c.Request.RouteValues["id"]?.ToString() ?? "", input.Text!); return Results.Ok(); }
            catch (Exception ex) when (IsExternalFailure(ex)) { return Results.Json(new { error = ex.Message }, statusCode: 400); }
        });
        app.MapPost("/api/admin/devices/{id}/send-files", async (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            var external = ExternalDevices; if (external is null) return ExternalUnavailable();
            try { var count = await external.PickAndSendFilesAsync(c.Request.RouteValues["id"]?.ToString() ?? ""); return Results.Json(new { count }); }
            catch (Exception ex) when (IsExternalFailure(ex)) { return Results.Json(new { error = ex.Message }, statusCode: 400); }
        });
        // Owner page drag & drop. Each dropped file is staged as outbox/drop-<batch>/<name> by
        // /api/admin/drop, then /api/admin/drop/send hands the whole batch to this computer's send queue
        // (a device that connected here) or, through ExternalDrop, to a device this computer added.
        var dropEpoch = DateTime.UtcNow;
        string DropFolder(Guid batch) => Path.Combine(data, "outbox", "drop-" + batch.ToString("N"));
        void SweepDrops()
        {
            // Batches from earlier runs, and batches past the 24-hour share lifetime.
            try
            {
                foreach (var dir in Directory.GetDirectories(Path.Combine(data, "outbox"), "drop-*"))
                {
                    try { var touched = Directory.GetLastWriteTimeUtc(dir); if (touched < dropEpoch || DateTime.UtcNow - touched > TimeSpan.FromHours(26)) Directory.Delete(dir, true); } catch { }
                }
            }
            catch { }
        }
        SweepDrops();
        app.MapPost("/api/admin/drop", async (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            if (c.Request.ContentLength is not long length) return Results.StatusCode(411);
            if (length > MaxFile) return Results.Json(new { error = "파일 한 개는 최대 4 GiB까지 보낼 수 있습니다." }, statusCode: 413);
            if (!Guid.TryParse(c.Request.Query["batch"], out var batch)) return Results.BadRequest();
            var target = c.Request.Query["target"].ToString();
            if (!sessions.Values.Any(x => x.Id == target && !x.Owner) && ExternalDropOwns?.Invoke(target) != true) return Results.Json(new { error = "받을 기기를 먼저 연결하세요." }, statusCode: 400);
            var raw = c.Request.Query["name"].ToString();
            if (raw.Contains('/') || raw.Contains('\\')) throw new ArgumentException("올바르지 않은 파일 이름입니다.");
            var name = Util.SafeRelative(raw);
            var folder = DropFolder(batch);
            if (!Directory.Exists(folder)) SweepDrops();
            Util.NoLinks(folder); Directory.CreateDirectory(folder); Util.NoLinks(folder);
            if (Directory.EnumerateFiles(folder).Count() >= 1000) throw new ArgumentException("한 번에 1000개까지 보낼 수 있습니다.");
            string? temp = Path.Combine(folder, ".ahna-" + Guid.NewGuid().ToString("N") + ".part");
            try
            {
                long bytes;
                await using (var output = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
                {
                    await c.Request.Body.CopyToAsync(output, c.RequestAborted); bytes = output.Length;
                }
                c.RequestAborted.ThrowIfCancellationRequested();
                if (bytes != length) throw new IOException("Incomplete upload");
                var destination = Path.Combine(folder, name);
                for (var i = 1; ; i++)
                {
                    try { File.Move(temp!, destination); temp = null; break; }
                    catch (IOException) when (File.Exists(destination)) { destination = Path.Combine(folder, Path.GetFileNameWithoutExtension(name) + $" ({i})" + Path.GetExtension(name)); }
                }
                return Results.Json(new { name = Path.GetFileName(destination), bytes });
            }
            finally { if (temp is not null) { try { File.Delete(temp); } catch { } } }
        });
        app.MapPost("/api/admin/drop/send", async (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            if (!Guid.TryParse(c.Request.Query["batch"], out var batch)) return Results.BadRequest();
            var target = c.Request.Query["target"].ToString();
            var folder = DropFolder(batch);
            if (!Directory.Exists(folder)) return Results.Json(new { error = "보낼 파일을 찾을 수 없습니다. 다시 끌어다 놓아 주세요." }, statusCode: 400);
            Util.NoLinks(folder);
            var files = Directory.GetFiles(folder).Where(f => !Path.GetFileName(f).StartsWith(".ahna-", StringComparison.Ordinal))
                .OrderBy(f => File.GetCreationTimeUtc(f)).ThenBy(f => f, StringComparer.Ordinal).ToArray();
            if (files.Length == 0) return Results.Json(new { error = "보낼 파일을 찾을 수 없습니다. 다시 끌어다 놓아 주세요." }, statusCode: 400);
            try
            {
                // A device this computer added: the host sends in the background and deletes the folder afterwards.
                if (ExternalDrop is { } drop && ExternalDropOwns?.Invoke(target) == true) { drop(target, folder, files); return Results.Json(new { count = files.Length, external = true }); }
                // A device that connected here: the staged files are served as they are (cleaned by SweepDrops).
                await AddPathsAsync(files, target);
                return Results.Json(new { count = files.Length, external = false });
            }
            catch { try { Directory.Delete(folder, true); } catch { } throw; }
        });
        app.MapPost("/api/admin/clipboard/open", (HttpContext c) => { if (Authenticate(c)?.Owner != true) return Results.Unauthorized(); ClipboardRequested?.Invoke(); return Results.Ok(); });
        app.MapPost("/api/admin/clipboard", async (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            const int maxBody = MaxClipboardBytes * 6 + 4096;
            if (c.Request.ContentLength is > maxBody) return Results.StatusCode(413);
            using var body = new MemoryStream(); var buffer = new byte[8192]; int read;
            while ((read = await c.Request.Body.ReadAsync(buffer, c.RequestAborted)) > 0)
            {
                if (body.Length + read > maxBody) return Results.StatusCode(413);
                body.Write(buffer, 0, read);
            }
            var input = JsonSerializer.Deserialize<ClipboardInput>(body.ToArray(), Util.Json);
            if (input is null) return Results.BadRequest();
            var message = SendClipboard(input.Text, input.Target);
            return Results.Ok(new { message.Id });
        });
        app.MapPost("/api/admin/sessions/{id}/forget", (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            ForgetSession(c.Request.RouteValues["id"]?.ToString() ?? ""); return Results.Ok();
        });
        app.MapPost("/api/admin/revoke", (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            foreach (var kv in sessions.Where(x => !x.Value.Owner)) sessions.TryRemove(kv.Key, out _);
            lock (gate) clipboardMessages.Clear();
            SaveNativeSessions();
            Pin = RandomNumberGenerator.GetInt32(100000, 1000000).ToString(); bridge?.Reload(); return Results.Ok();
        });
        app.MapGet("/api/admin/nearby", (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            return NearbyHost is { } nearby ? Results.Json(nearby.Snapshot()) : Results.Json(new { available = false, bluetooth = "none" });
        });
        app.MapPost("/api/admin/nearby/mode", async (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            if (NearbyHost is not { } nearby) return NearbyUnavailable();
            var input = await ReadSmallJson<NearbyModeInput>(c, 4096);
            if (input?.Mode is not ("off" or "registered" or "everyone")) return Results.BadRequest();
            try { nearby.SetMode(input.Mode); return Results.Json(nearby.Snapshot()); }
            catch (Exception ex) when (IsExternalFailure(ex)) { return Results.Json(new { error = ex.Message }, statusCode: 400); }
        });
        app.MapPost("/api/admin/nearby/cancel", (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            if (NearbyHost is not { } nearby) return NearbyUnavailable();
            nearby.CancelSend(); return Results.Ok();
        });
        app.MapPost("/api/admin/nearby/{id}/send-files", async (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            if (NearbyHost is not { } nearby) return NearbyUnavailable();
            try { var count = await nearby.PickAndSendAsync(c.Request.RouteValues["id"]?.ToString() ?? ""); return Results.Json(new { count }); }
            catch (Exception ex) when (IsExternalFailure(ex)) { return Results.Json(new { error = ex.Message }, statusCode: 400); }
        });
        app.MapPost("/api/admin/qr/open", (HttpContext c) =>
        {
            if (Authenticate(c)?.Owner != true) return Results.Unauthorized();
            if (NearbyHost is not { } nearby) return NearbyUnavailable();
            nearby.OpenQr(); return Results.Ok();
        });
        MapGuest(app);
        app.UseDefaultFiles(); app.UseStaticFiles();
        await app.StartAsync();
        bridge=new(new Uri(LocalUrl),Path.Combine(data,"remote-parts"),()=>Settings.RemoteEnabled?new(Settings.RemoteUrl,RemoteKey.Unprotect(Settings.RemoteKeyProtected)):null,computerId:computerId,pairingPin:()=>Pin);
        bridge.DeviceName=()=>GuestOwnerName; bridge.Platform=OperatingSystem.IsMacOS()?"Mac":"Windows";
        bridge.Connected+=()=>{_=RefreshAnnouncements();};
        bridge.Notice+=(action,text)=>
        {
            if(action=="notices"){_=RefreshAnnouncements();return;}
            if(action is "rejoin" or "blocked")ForgetServer();
            try { ServerNotice?.Invoke(action, text); } catch { }
        };
    }
    static IResult NearbyUnavailable() => Results.Json(new { error = "이 컴퓨터에서는 근처 기기와 QR을 쓸 수 없습니다." }, statusCode: 503);
    static IResult ExternalUnavailable() => Results.Json(new { error = "이 컴퓨터에서는 다른 기기를 추가할 수 없습니다." }, statusCode: 503);
    static bool IsExternalFailure(Exception ex) => ex is ArgumentException or InvalidOperationException or IOException or InvalidDataException or HttpRequestException;
    static async Task<T?> ReadSmallJson<T>(HttpContext c, int maxBytes) where T : class
    {
        if (c.Request.ContentLength is long declared && declared > maxBytes) throw new ArgumentException("요청이 너무 큽니다.");
        using var body = new MemoryStream(); var buffer = new byte[8192]; int read;
        while ((read = await c.Request.Body.ReadAsync(buffer, c.RequestAborted)) > 0)
        {
            if (body.Length + read > maxBytes) throw new ArgumentException("요청이 너무 큽니다.");
            body.Write(buffer, 0, read);
        }
        return body.Length == 0 ? null : JsonSerializer.Deserialize<T>(body.ToArray(), Util.Json);
    }
    // Used by the host's outbound client so files and text from added devices show up
    // in the same history and clipboard lists as everything else.
    public void RecordExternal(string direction, string name, long bytes, string deviceId, string deviceName, string status, bool notify = false)
    {
        Record(direction, name, bytes, new Device(deviceId, deviceName, false), status);
        if (notify && direction == "receive") { try { Received?.Invoke($"{deviceName} · {name}"); } catch { } }
    }
    public void AddExternalClipboard(string text, string deviceId, string deviceName)
    {
        ValidateClipboard(text);
        var message = StoreClipboard(text, deviceName, "windows");
        Record("receive", "클립보드 텍스트", message.Bytes, new Device(deviceId, deviceName, false), "텍스트 수신 완료");
        try { ClipboardReceived?.Invoke(deviceName); } catch { }
    }
    object OptionsSnapshot()
    {
        var integrations = IntegrationsRead?.Invoke();
        var s = Settings;
        return new
        {
            version = AppVersion,
            savePath = s.SavePath,
            notifications = s.Notifications,
            recipientSavedNotifications = s.RecipientSavedNotifications,
            remoteUrl = s.RemoteUrl,
            remoteKeySaved = !string.IsNullOrEmpty(s.RemoteKeyProtected),
            ahna = Ahna.Remote.Brand.Ahna,
            remoteEnabled = s.RemoteEnabled,
            remoteStatus = RemoteStatus,
            integrationsAvailable = integrations is not null,
            startup = integrations?.Startup ?? false,
            explorerMenu = integrations?.ExplorerMenu ?? false,
            folderPicker = FolderPickRequested is not null,
            updates = UpdateRequested is not null
        };
    }
    static string ReadAppVersion()
    {
        var assembly = System.Reflection.Assembly.GetEntryAssembly() ?? typeof(TransferServer).Assembly;
        var info = System.Reflection.CustomAttributeExtensions.GetCustomAttribute<System.Reflection.AssemblyInformationalVersionAttribute>(assembly)?.InformationalVersion;
        var text = (info ?? assembly.GetName().Version?.ToString() ?? "0.0.0").TrimStart('v', 'V').Split('+', '-')[0];
        return Version.TryParse(text, out var v) ? $"{v.Major}.{v.Minor}.{Math.Max(0, v.Build)}" : text;
    }
    static bool IsLoopback(HttpContext c) => c.Request.Headers["X-Ahna-Remote"].Count==0 && c.Connection.RemoteIpAddress is { } ip && IPAddress.IsLoopback(ip.IsIPv4MappedToIPv6 ? ip.MapToIPv4() : ip);
    Device? Authenticate(HttpContext c)
    {
        if (!c.Request.Cookies.TryGetValue("ahna", out var token) || !sessions.TryGetValue(token, out var d) || DateTimeOffset.UtcNow - d.LastSeen > (d.Native?TimeSpan.FromDays(30):TimeSpan.FromHours(12)) || (d.Owner && !IsLoopback(c))) return null;
        d.LastSeen = DateTimeOffset.UtcNow; return d;
    }
    static void Cookie(HttpContext c, string token,bool native=false) => c.Response.Cookies.Append("ahna", token, new CookieOptions { HttpOnly = true, SameSite = SameSiteMode.Strict, IsEssential = true, Path = "/", MaxAge = native?TimeSpan.FromDays(30):TimeSpan.FromHours(12) });
    async Task<IResult> Upload(HttpContext c)
    {
        var d = Authenticate(c); if (d is null) return Results.Unauthorized();
        if (c.Request.ContentLength is null) return Results.StatusCode(411);
        if (c.Request.ContentLength > MaxFile) return Results.StatusCode(413);
        if (c.Request.Query["kind"] == "clipboard")
        {
            if (d.Owner || !Guid.TryParse(c.Request.Query["batch"], out _)) return Results.BadRequest();
            if (c.Request.ContentLength > MaxClipboardBytes) return Results.StatusCode(413);
            using var body = new MemoryStream();
            var buffer = new byte[4096]; int count;
            while ((count = await c.Request.Body.ReadAsync(buffer, c.RequestAborted)) > 0)
            {
                if (body.Length + count > MaxClipboardBytes) return Results.StatusCode(413);
                body.Write(buffer, 0, count);
            }
            if (body.Length != c.Request.ContentLength) return Results.BadRequest();
            string text;
            try { text = new UTF8Encoding(false, true).GetString(body.ToArray()); }
            catch (DecoderFallbackException) { return Results.BadRequest(); }
            ValidateClipboard(text);
            var message = StoreClipboard(text, d.Name, "windows");
            Record("receive", "클립보드 텍스트", message.Bytes, d, "텍스트 수신 완료");
            try { ClipboardReceived?.Invoke(d.Name); } catch { }
            return Results.Ok(new { message.Id });
        }
        var relative = Util.SafeRelative(c.Request.Query["path"].ToString());
        if (!Guid.TryParse(c.Request.Query["batch"], out _)) return Results.BadRequest();
        if (!await uploads.WaitAsync(0)) return Results.Json(new { error = "다른 전송이 진행 중입니다. 잠시 후 다시 시도하세요." }, statusCode: 429);
        string? temp = null;
        try
        {
            // Ordinary files go straight into the configured receive folder.
            // Only the relative paths supplied by an explicit folder upload are retained.
            var basePath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Settings.SavePath));
            Util.NoLinks(basePath);
            Directory.CreateDirectory(basePath);
            var destination = Path.GetFullPath(Path.Combine(basePath, relative));
            var prefix = Path.EndsInDirectorySeparator(basePath) ? basePath : basePath + Path.DirectorySeparatorChar;
            if (!destination.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("올바르지 않은 경로입니다.");
            Util.NoLinks(destination); Directory.CreateDirectory(Path.GetDirectoryName(destination)!); Util.NoLinks(destination);
            temp = Path.Combine(Path.GetDirectoryName(destination)!, ".ahna-" + Guid.NewGuid().ToString("N") + ".part");
            long bytes;
            await using (var output = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
            {
                await c.Request.Body.CopyToAsync(output, c.RequestAborted); bytes = output.Length;
            }
            c.RequestAborted.ThrowIfCancellationRequested();
            if (bytes != c.Request.ContentLength) throw new IOException("Incomplete upload");
            var original = destination;
            for (var i = 1; ; i++)
            {
                try { File.Move(temp!, destination); temp = null; break; }
                catch (IOException) when (File.Exists(destination)) { destination = Path.Combine(Path.GetDirectoryName(original)!, Path.GetFileNameWithoutExtension(original) + $" ({i})" + Path.GetExtension(original)); }
            }
            Record("receive", relative, bytes, d, "저장 완료");
            try { Received?.Invoke($"{d.Name} · {relative}"); } catch { }
            return Results.Ok(new { name = Path.GetFileName(destination), bytes });
        }
        catch { Record("receive", relative, c.Request.ContentLength ?? 0, d, "실패"); throw; }
        finally { if (temp is not null) { try { File.Delete(temp); } catch { } } uploads.Release(); }
    }
    async Task Download(HttpContext c)
    {
        var d = Authenticate(c); if (d is null) { c.Response.StatusCode = 401; return; }
        var id = c.Request.RouteValues["id"]?.ToString() ?? "";
        if (c.Request.Query["kind"] == "clipboard")
        {
            var message = FindClipboard(id, d.Owner ? "windows" : d.Id);
            if (message is null) { c.Response.StatusCode = 404; return; }
            c.Response.ContentType = "text/plain; charset=utf-8";
            c.Response.ContentLength = message.Bytes;
            await c.Response.WriteAsync(message.Text, c.RequestAborted);
            return;
        }
        if (!shares.TryGetValue(id, out var item) || (!d.Owner && item.Target != d.Id) || DateTimeOffset.UtcNow - item.Created > TimeSpan.FromHours(24)) { c.Response.StatusCode = 404; return; }
        try
        {
            Util.NoLinks(item.Path);
            await using var file = new FileStream(item.Path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, true);
            c.Response.ContentType = "application/octet-stream";
            c.Response.ContentLength = file.Length;
            c.Response.Headers.ContentDisposition = "attachment; filename*=UTF-8''" + Uri.EscapeDataString(item.Name);
            await file.CopyToAsync(c.Response.Body, c.RequestAborted);
            await c.Response.Body.FlushAsync(c.RequestAborted);
            Record("send", item.Name, file.Length, d, "응답 전송 완료");
            if(Interlocked.Exchange(ref item.DeliveryNotified,1)==0){try{Delivered?.Invoke($"{d.Name} · {item.Name}\n파일 전달 완료 · 상대 저장 확인 대기");}catch{}}
        }
        catch { Record("send", item.Name, item.Bytes, d, "실패/중단"); throw; }
    }
    public async Task AddPathsAsync(IEnumerable<string> paths, string target, bool snapshot = false)
    {
        if (!sessions.Values.Any(d => d.Id == target && !d.Owner)) throw new ArgumentException("받을 기기를 먼저 연결하세요.");
        var prepared=0;
        foreach (var raw in paths)
        {
            var path = Path.GetFullPath(raw); Util.NoLinks(path);
            var temporary = false; var name = Path.GetFileName(Path.TrimEndingDirectorySeparator(path));
            if (Directory.Exists(path))
            {
                // Validate every entry before zipping; reparse points must never be followed.
                await Task.Run(() => ValidateTree(path)); // 파일이 많은 폴더도 화면이 멈추지 않게
                var zip = Path.Combine(data, "outbox", Guid.NewGuid().ToString("N") + ".zip");
                try { await Task.Run(() => ZipFile.CreateFromDirectory(path, zip, CompressionLevel.Fastest, true)); }
                catch { if (File.Exists(zip)) File.Delete(zip); throw; }
                path = zip; name += ".zip"; temporary = true;
            }
            if (!File.Exists(path)) throw new ArgumentException("파일을 찾을 수 없습니다.");
            var bytes = new FileInfo(path).Length;
            if (bytes > MaxFile) { if (temporary) File.Delete(path); throw new ArgumentException("파일 또는 ZIP 한 개는 최대 4 GiB까지 지원합니다."); }
            if (snapshot && !temporary)
            {
                var copy = Path.Combine(data, "outbox", Guid.NewGuid().ToString("N") + ".file");
                try { await Task.Run(() => File.Copy(path, copy)); }
                catch { if (File.Exists(copy)) File.Delete(copy); throw; }
                path = copy; temporary = true;
                bytes = new FileInfo(path).Length;
                if (bytes > MaxFile) { File.Delete(path); throw new ArgumentException("파일 한 개는 최대 4 GiB까지 지원합니다."); }
            }
            var id = Guid.NewGuid().ToString("N"); shares[id] = new(id, name, path, bytes, target, temporary, DateTimeOffset.UtcNow);
            prepared++;
        }
        if(prepared>0){try{SendPrepared?.Invoke($"{sessions.Values.First(d=>d.Id==target).Name} · {prepared}개 파일\n전송 준비 완료 · 상대 기기 연결을 기다립니다.");}catch{}}
    }
    static void ValidateTree(string dir)
    {
        foreach (var entry in Directory.EnumerateFileSystemEntries(dir))
        {
            if (File.GetAttributes(entry).HasFlag(FileAttributes.ReparsePoint)) throw new ArgumentException("연결 폴더/심볼릭 링크는 전송할 수 없습니다.");
            if (Directory.Exists(entry)) ValidateTree(entry);
        }
    }
    static void ValidateClipboard(string? text)
    {
        if (string.IsNullOrEmpty(text)) throw new ArgumentException("보낼 글자를 먼저 붙여넣어 주세요.");
        if (text.Contains('\0') || Encoding.UTF8.GetByteCount(text) > MaxClipboardBytes) throw new ArgumentException("클립보드 텍스트는 최대 64 KB까지 보낼 수 있습니다. 긴 글은 파일로 보내세요.");
    }
    void PruneClipboard()
    {
        foreach (var item in clipboardMessages.Values.Where(x => DateTimeOffset.UtcNow - x.Created >= TimeSpan.FromHours(24)).ToArray()) clipboardMessages.Remove(item.Id);
    }
    ClipboardMessage StoreClipboard(string text, string sender, string target)
    {
        lock (gate)
        {
            PruneClipboard();
            var message = new ClipboardMessage(Guid.NewGuid().ToString("N"), text, sender, target, DateTimeOffset.UtcNow);
            clipboardMessages.Add(message.Id, message);
            foreach (var old in clipboardMessages.Values.Where(x => x.Target == target).OrderByDescending(x => x.Created).Skip(20).ToArray()) clipboardMessages.Remove(old.Id);
            foreach (var old in clipboardMessages.Values.OrderByDescending(x => x.Created).Skip(100).ToArray()) clipboardMessages.Remove(old.Id);
            return message;
        }
    }
    public ClipboardMessage SendClipboard(string text, string target)
    {
        ValidateClipboard(text);
        var device = sessions.Values.FirstOrDefault(x => x.Id == target && IsReceiving(x, DateTimeOffset.UtcNow)) ?? throw new ArgumentException("받을 기기에서 아나를 열고 연결을 확인하세요.");
        var message = StoreClipboard(text, Environment.MachineName, target);
        Record("send", "클립보드 텍스트", message.Bytes, device, "텍스트 전송 준비 완료");
        return message;
    }
    public ClipboardMessage[] ClipboardInbox(string target = "windows")
    {
        lock (gate) { PruneClipboard(); return clipboardMessages.Values.Where(x => x.Target == target).OrderByDescending(x => x.Created).ToArray(); }
    }
    public ClipboardMessage? FindClipboard(string id, string target = "windows") => ClipboardInbox(target).FirstOrDefault(x => x.Id == id);
    static bool IsReceiving(Device d,DateTimeOffset now) => !d.Owner && d.CanReceive && now-(d.Native?d.LastReceiverSeen:d.LastSeen)<TimeSpan.FromSeconds(40);
    // Every device that paired with this receiver (one row per session id), for the merged device lists.
    public PeerInfo[] Peers()
    {
        var now = DateTimeOffset.UtcNow;
        string[] reserved; lock (gate) reserved = reservedSessions.ToArray();
        return sessions.Where(kv => !reserved.Contains(kv.Key)).Select(kv => kv.Value).Where(d => !d.Owner && (d.Native || IsReceiving(d, now))).GroupBy(d => d.Id)
            .Select(g => { var d = g.OrderByDescending(x => x.LastSeen).First(); return new PeerInfo(d.Id, d.Name, d.ComputerId, g.Any(x => IsReceiving(x, now))); }).ToArray();
    }
    // Drops one paired device on this side (and any other session of the same device identity).
    public void ForgetSession(string id)
    {
        if (string.IsNullOrEmpty(id)) return;
        var identity = sessions.Values.Where(d => !d.Owner && d.Id == id).Select(d => d.ComputerId).FirstOrDefault(x => x.Length > 0) ?? "";
        foreach (var kv in sessions.Where(x => !x.Value.Owner && (x.Value.Id == id || (identity.Length > 0 && x.Value.ComputerId == identity))).ToArray()) sessions.TryRemove(kv.Key, out _);
        SaveNativeSessions();
    }
    // Reverse pairing, requester side: mints a normal paired session on this host for the device we are about
    // to pair with (same token, expiry and persistence as /api/pair). Null when this host is not reachable
    // through its 서버, because the other side could not use the session then. Always finish with CompleteReverse.
    public ReverseCredential? ReverseOffer()
    {
        var address = Settings.RemoteEnabled ? NasOrigin(Settings.RemoteUrl) : null;
        if (address is null || sessions.Count > 100) return null;
        var token = Util.Token();
        lock (gate) reservedSessions.Add(token);
        sessions[token] = new Device(Guid.NewGuid().ToString("N"), "기기", false) { Native = true, CanReceive = true };
        return new ReverseCredential(address, computerId, token, CleanName(Environment.MachineName, "컴퓨터"));
    }
    // Keeps the minted session when the other host accepted it (it now has a connection to us), else drops it.
    public void CompleteReverse(string token, bool accepted, string? name, string? peerComputerId)
    {
        lock (gate) { if (!reservedSessions.Remove(token)) return; }
        if (!accepted || !sessions.TryGetValue(token, out var d)) { sessions.TryRemove(token, out _); return; }
        var identity = PeerIdentity(peerComputerId);
        lock (gate)
        {
            d.Name = CleanName(name, d.Name);
            if (identity.Length > 0) d.ComputerId = identity;
        }
        // Like pairing again: the device's earlier session here is replaced, so it is listed once.
        if (d.ComputerId.Length > 0) foreach (var old in sessions.Where(x => x.Key != token && !x.Value.Owner && x.Value.ComputerId == d.ComputerId).ToArray()) sessions.TryRemove(old.Key, out _);
        SaveNativeSessions();
    }
    ReverseCredential? ReverseFrom(ReverseInput? input)
    {
        if (input is null) return null;
        var address = NasOrigin(input.Address);
        var identity = (input.ComputerID ?? "").Trim();
        var token = (input.Token ?? "").Trim();
        if (address is null || !Guid.TryParseExact(identity, "N", out _) || identity.Equals(computerId, StringComparison.OrdinalIgnoreCase)) return null;
        if (token.Length is < 32 or > 256 || !token.All(c => char.IsAsciiLetterOrDigit(c) || c == '-' || c == '_')) return null;
        return new ReverseCredential(address, identity.ToLowerInvariant(), token, CleanName(input.Name, "기기"));
    }
    // A 서버 HTTPS origin (no path, query or credentials), normalised without a trailing slash.
    public static string? NasOrigin(string? value)
    {
        if (!Uri.TryCreate((value ?? "").Trim(), UriKind.Absolute, out var uri) || uri.Scheme != "https" || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0 || uri.AbsolutePath != "/") return null;
        return uri.GetLeftPart(UriPartial.Authority);
    }
    static string CleanName(string? value, string fallback)
    {
        var text = new string((value ?? "").Where(c => !char.IsControl(c)).Take(40).ToArray()).Trim();
        return text.Length == 0 ? fallback : text;
    }
    public static string PeerIdentity(string? value)
    {
        var text = (value ?? "").Trim();
        return text.Length == 32 && text.All(char.IsAsciiHexDigit) ? text.ToLowerInvariant() : "";
    }
    public (string Id, string Name)[] Nearby() => sessions.Values.Where(d => IsReceiving(d,DateTimeOffset.UtcNow)).DistinctBy(d => d.Id).Select(d => (d.Id, d.Name)).ToArray();
    public async ValueTask DisposeAsync() { if(Interlocked.Exchange(ref disposed,1)!=0)return;foreach(var t in tickets.Values)EndTicket(t,"expired");SaveNativeSessions();if(bridge is not null){await bridge.DisposeAsync();bridge=null;}if (app is not null) { var current = app; app = null; await current.StopAsync(); await current.DisposeAsync(); } }
    // ---- Guest tickets (1.2) ----------------------------------------------------------------------------------
    // A ticket is a one-time permission for a device that is not paired: "send" gives it the chosen files,
    // "receive" lets it upload after the owner accepts. Tickets live in memory, expire after 10 minutes and are
    // dropped as soon as they end (finished tickets answer only info/status for two more minutes).
    public const string NasRequired = "서버 설정이 필요합니다. 옵션에서 서버를 설정하세요.";
    public static readonly TimeSpan GuestLifetime = TimeSpan.FromMinutes(10);
    public sealed record GuestFile(string Name, long Bytes, string? Path, bool Temporary);
    public sealed class GuestTicket
    {
        internal GuestTicket(string token, string kind, string peer, string? code, GuestFile[] files)
        {
            Token = token; Kind = kind; Peer = peer; Code = code; Files = files; Completed = new bool[files.Length];
            Expires = Created + GuestLifetime;
        }
        internal readonly object Gate = new();
        internal bool[] Completed;
        internal long transferred;
        volatile string state = "ready";
        public string Token { get; }
        public string Kind { get; }
        // The other side: the nearby device it was offered to, the name a guest typed, or "QR".
        public string Peer { get; internal set; }
        public string? Code { get; internal set; }
        public GuestFile[] Files { get; internal set; }
        public DateTimeOffset Created { get; } = DateTimeOffset.UtcNow;
        public DateTimeOffset Expires { get; }
        public DateTimeOffset Ended { get; internal set; }
        public string State { get => state; internal set => state = value; }
        public long Total => Files.Sum(f => f.Bytes);
        public long Transferred => Interlocked.Read(ref transferred);
        public int CompletedCount { get { lock (Gate) return Completed.Count(x => x); } }
        public bool Finished => State is "done" or "declined" or "expired";
        public TimeSpan Remaining => Finished ? TimeSpan.Zero : Expires - DateTimeOffset.UtcNow > TimeSpan.Zero ? Expires - DateTimeOffset.UtcNow : TimeSpan.Zero;
    }
    public string? GuestOrigin => Settings.RemoteEnabled ? NasOrigin(Settings.RemoteUrl) : null;
    public string GuestUrl(GuestTicket ticket) => (GuestOrigin ?? throw new InvalidOperationException(NasRequired)) + "/s/" + computerId.ToLowerInvariant() + "/" + ticket.Token;
    public GuestTicket? FindTicket(string token) => tickets.TryGetValue(token, out var t) ? t : null;
    static string NewGuestToken() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    public static string NewGuestCode() => RandomNumberGenerator.GetInt32(10, 100).ToString(System.Globalization.CultureInfo.InvariantCulture);
    void CheckGuestCapacity()
    {
        if (GuestOrigin is null) throw new InvalidOperationException(NasRequired);
        if (tickets.Values.Count(t => !t.Finished) >= 32) throw new InvalidOperationException("열린 공유 링크가 너무 많습니다. 잠시 후 다시 시도하세요.");
    }
    // Files (and folders, sent as ZIP) a guest may download once. code: the 2-digit number shown on both screens.
    public async Task<GuestTicket> CreateSendTicketAsync(IEnumerable<string> paths, string peer, string? code = null)
    {
        CheckGuestCapacity();
        var files = new List<GuestFile>();
        try
        {
            foreach (var raw in paths)
            {
                if (files.Count >= 1000) throw new ArgumentException("한 번에 1000개까지 보낼 수 있습니다.");
                var path = Path.GetFullPath(raw); Util.NoLinks(path);
                var temporary = false; var name = Path.GetFileName(Path.TrimEndingDirectorySeparator(path));
                if (Directory.Exists(path))
                {
                    await Task.Run(() => ValidateTree(path));
                    var zip = Path.Combine(data, "outbox", Guid.NewGuid().ToString("N") + ".zip");
                    try { await Task.Run(() => ZipFile.CreateFromDirectory(path, zip, CompressionLevel.Fastest, true)); }
                    catch { if (File.Exists(zip)) File.Delete(zip); throw; }
                    path = zip; name += ".zip"; temporary = true;
                    files.Add(new GuestFile(name, 0, path, true));
                }
                if (!File.Exists(path)) throw new ArgumentException("파일을 찾을 수 없습니다.");
                var bytes = new FileInfo(path).Length;
                if (bytes > MaxFile) throw new ArgumentException("파일 또는 ZIP 한 개는 최대 4 GiB까지 지원합니다.");
                if (temporary) files[^1] = files[^1] with { Bytes = bytes };
                else files.Add(new GuestFile(name, bytes, path, false));
            }
            if (files.Count == 0) throw new ArgumentException("보낼 파일을 고르세요.");
        }
        catch { foreach (var f in files) DeleteGuestFile(f); throw; }
        var ticket = new GuestTicket(NewGuestToken(), "send", CleanName(peer, "상대 기기"), code is { Length: 2 } && code.All(char.IsAsciiDigit) ? code : NewGuestCode(), files.ToArray());
        tickets[ticket.Token] = ticket; _ = WatchTicket(ticket);
        return ticket;
    }
    // A link a guest opens to upload files here; every upload needs the owner's confirmation first.
    public GuestTicket CreateReceiveTicket(string peer = "QR")
    {
        CheckGuestCapacity();
        var ticket = new GuestTicket(NewGuestToken(), "receive", CleanName(peer, "QR"), null, []);
        tickets[ticket.Token] = ticket; _ = WatchTicket(ticket);
        return ticket;
    }
    // The owner's answer to a receive request (GuestRequested). False when the request is no longer waiting.
    public bool AnswerGuest(string token, bool accept)
    {
        if (!tickets.TryGetValue(token, out var t)) return false;
        lock (t.Gate)
        {
            if (t.State != "waiting") return false;
            if (accept) t.State = "accepted";
        }
        if (accept) RaiseGuest(t); else EndTicket(t, "declined");
        return true;
    }
    // Ends a ticket now (the owner cancelled, or the window closed). Files already received stay saved.
    public void CancelTicket(string token) { if (tickets.TryGetValue(token, out var t)) EndTicket(t, "declined"); }
    void RaiseGuest(GuestTicket t) { try { GuestChanged?.Invoke(t); } catch { } }
    void EndTicket(GuestTicket t, string state)
    {
        lock (t.Gate)
        {
            if (t.Finished) return;
            t.State = state; t.Ended = DateTimeOffset.UtcNow;
        }
        foreach (var f in t.Files) if (f.Temporary) DeleteGuestFile(f);
        RaiseGuest(t);
    }
    static void DeleteGuestFile(GuestFile f) { if (f.Temporary && f.Path is not null) { try { File.Delete(f.Path); } catch { } } }
    async Task WatchTicket(GuestTicket t)
    {
        try
        {
            while (!t.Finished && Volatile.Read(ref disposed) == 0)
            {
                await Task.Delay(TimeSpan.FromSeconds(5));
                ExpireIfDue(t);
            }
            await Task.Delay(TimeSpan.FromMinutes(2));
        }
        catch { }
        finally { tickets.TryRemove(t.Token, out _); }
    }
    void ExpireIfDue(GuestTicket t)
    {
        var now = DateTimeOffset.UtcNow;
        if (t.Finished || now < t.Expires) return;
        // A transfer that is still running may finish (up to an hour); anything else ends at ten minutes.
        if (t.State is "transferring" or "accepted" && now < t.Expires + TimeSpan.FromMinutes(50)) return;
        EndTicket(t, "expired");
    }
    GuestTicket? Guest(HttpContext c, bool live = true)
    {
        var cid = c.Request.RouteValues["cid"]?.ToString() ?? "";
        var token = c.Request.RouteValues["token"]?.ToString() ?? "";
        if (!cid.Equals(computerId, StringComparison.OrdinalIgnoreCase) || token.Length is < 22 or > 64 || !tickets.TryGetValue(token, out var t)) return null;
        ExpireIfDue(t);
        return live && t.Finished ? null : t;
    }
    Device GuestDevice(GuestTicket t) => new("guest-" + t.Token[..12], t.Peer, false);
    static IResult GuestMissing() => Results.Text("링크가 만료되었거나 올바르지 않습니다.", "text/plain; charset=utf-8", statusCode: 404);
    object GuestInfo(GuestTicket t) => new
    {
        v = 1, kind = t.Kind, owner = GuestOwnerName, state = t.State, expiresIn = (int)Math.Ceiling(t.Remaining.TotalSeconds), code = t.Code,
        files = t.Files.Select((f, i) => new { i, name = f.Name, bytes = f.Bytes }).ToArray()
    };
    void MapGuest(WebApplication web)
    {
        web.MapGet("/s/{cid}/{token}", async (HttpContext c) =>
        {
            var t = Guest(c, live: false);
            var page = webRootPath is null ? null : Path.Combine(webRootPath, "guest.html");
            if (t is null || page is null || !File.Exists(page)) { c.Response.StatusCode = 404; c.Response.ContentType = "text/plain; charset=utf-8"; await c.Response.WriteAsync("링크가 만료되었거나 올바르지 않습니다."); return; }
            // Self-contained page: inline CSS/JS allowed only through this response's nonce.
            var nonce = Convert.ToBase64String(RandomNumberGenerator.GetBytes(18));
            var html = (await File.ReadAllTextAsync(page, c.RequestAborted)).Replace("<script>", $"<script nonce=\"{nonce}\">").Replace("<style>", $"<style nonce=\"{nonce}\">");
            var bytes = Encoding.UTF8.GetBytes(html);
            c.Response.Headers["Content-Security-Policy"] = $"default-src 'none'; script-src 'nonce-{nonce}'; style-src 'nonce-{nonce}'; img-src data: blob:; media-src blob:; connect-src 'self'; frame-ancestors 'none'; form-action 'none'; base-uri 'none'";
            c.Response.ContentType = "text/html; charset=utf-8";
            c.Response.ContentLength = bytes.Length;
            await c.Response.Body.WriteAsync(bytes, c.RequestAborted);
        });
        web.MapGet("/s/{cid}/{token}/info", (HttpContext c) => Guest(c, live: false) is { } t ? Results.Json(GuestInfo(t)) : GuestMissing());
        web.MapGet("/s/{cid}/{token}/status", (HttpContext c) => Guest(c, live: false) is { } t ? Results.Json(new { state = t.State, code = t.Code }) : GuestMissing());
        web.MapPost("/s/{cid}/{token}/decline", (HttpContext c) =>
        {
            var t = Guest(c); if (t is null) return GuestMissing();
            // A nearby receiver pressed [거절] (send), or a guest gave up before the owner answered (receive).
            if (t.Kind == "send" ? t.State == "ready" : t.State is "ready" or "waiting") EndTicket(t, "declined");
            return Results.Json(new { state = t.State });
        });
        web.MapGet("/s/{cid}/{token}/file/{index}", async (HttpContext c) =>
        {
            var t = Guest(c);
            if (t is null || t.Kind != "send" || !int.TryParse(c.Request.RouteValues["index"]?.ToString(), System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var i) || i < 0 || i >= t.Files.Length || t.Files[i].Path is not { } path)
            { c.Response.StatusCode = 404; return; }
            var f = t.Files[i];
            lock (t.Gate) { if (t.Finished) { c.Response.StatusCode = 404; return; } if (t.State == "ready") t.State = "transferring"; }
            RaiseGuest(t);
            Util.NoLinks(path);
            await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, true);
            c.Response.ContentType = "application/octet-stream";
            c.Response.ContentLength = file.Length;
            c.Response.Headers.ContentDisposition = "attachment; filename*=UTF-8''" + Uri.EscapeDataString(f.Name);
            var buffer = new byte[65536]; int read; long sent = 0;
            try
            {
                while ((read = await file.ReadAsync(buffer, c.RequestAborted)) > 0)
                {
                    await c.Response.Body.WriteAsync(buffer.AsMemory(0, read), c.RequestAborted);
                    sent += read; Interlocked.Add(ref t.transferred, read);
                }
                await c.Response.Body.FlushAsync(c.RequestAborted);
            }
            catch { Interlocked.Add(ref t.transferred, -sent); throw; }
            bool first, all;
            lock (t.Gate) { first = !t.Completed[i]; t.Completed[i] = true; all = t.Completed.All(x => x); }
            if (!first) Interlocked.Add(ref t.transferred, -sent);
            if (first) Record("send", f.Name, f.Bytes, GuestDevice(t), "응답 전송 완료");
            if (all && !t.Finished)
            {
                EndTicket(t, "done");
                try { Delivered?.Invoke($"{t.Peer} · " + (t.Files.Length == 1 ? f.Name : $"{t.Files.Length}개 파일") + "\n보냈습니다"); } catch { }
            }
            else RaiseGuest(t);
        });
        web.MapPost("/s/{cid}/{token}/request", async (HttpContext c) =>
        {
            var t = Guest(c); if (t is null || t.Kind != "receive") return GuestMissing();
            var input = await ReadSmallJson<GuestRequestInput>(c, 16384);
            if (input?.Files is not { Length: > 0 and <= 1000 } list) return Results.Json(new { error = "보낼 파일을 고르세요." }, statusCode: 400);
            var files = new GuestFile[list.Length];
            for (var i = 0; i < list.Length; i++)
            {
                var raw = list[i]?.Name ?? "";
                if (raw.Contains('/') || raw.Contains('\\')) throw new ArgumentException("올바르지 않은 파일 이름입니다.");
                if (list[i]!.Bytes is < 0 or > MaxFile) return Results.Json(new { error = "파일 한 개는 최대 4 GiB까지 보낼 수 있습니다." }, statusCode: 413);
                files[i] = new GuestFile(Util.SafeRelative(raw), list[i]!.Bytes, null, false);
            }
            var peer = CleanName(input!.Name, "이름 없는 기기");
            lock (t.Gate)
            {
                if (t.State != "ready") return Results.Json(new { error = "이미 사용한 링크입니다.", state = t.State }, statusCode: 409);
                t.Peer = peer; t.Files = files; t.Completed = new bool[files.Length]; t.Code = NewGuestCode(); t.State = "waiting";
            }
            RaiseGuest(t);
            if (GuestRequested is { } ask) { try { ask(t); } catch { EndTicket(t, "declined"); } }
            else EndTicket(t, "declined");
            // Nobody answered: declined after 30 seconds, like the confirmation window.
            _ = Task.Run(async () => { await Task.Delay(TimeSpan.FromSeconds(30)); lock (t.Gate) { if (t.State != "waiting") return; } EndTicket(t, "declined"); });
            return Results.Json(new { state = t.State, code = t.Code });
        });
        web.MapPost("/s/{cid}/{token}/upload", async (HttpContext c) =>
        {
            var t = Guest(c); if (t is null || t.Kind != "receive") return GuestMissing();
            if (c.Request.ContentLength is not long length) return Results.StatusCode(411);
            if (!int.TryParse(c.Request.Query["i"].ToString(), System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var i) || i < 0 || i >= t.Files.Length) return Results.BadRequest();
            var f = t.Files[i];
            var raw = c.Request.Query["name"].ToString();
            if (raw.Contains('/') || raw.Contains('\\') || Util.SafeRelative(raw) != f.Name || length != f.Bytes) return Results.Json(new { error = "요청한 파일과 다릅니다." }, statusCode: 400);
            lock (t.Gate)
            {
                if (t.State is not ("accepted" or "transferring")) return Results.Json(new { error = "상대가 아직 받기를 누르지 않았습니다.", state = t.State }, statusCode: 409);
                if (t.Completed[i]) return Results.Json(new { error = "이미 받은 파일입니다." }, statusCode: 409);
                t.State = "transferring";
            }
            RaiseGuest(t);
            if (!await uploads.WaitAsync(TimeSpan.FromSeconds(30), c.RequestAborted)) return Results.Json(new { error = "다른 전송이 진행 중입니다. 잠시 후 다시 시도하세요." }, statusCode: 429);
            string? temp = null;
            try
            {
                var folder = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Settings.SavePath));
                Util.NoLinks(folder); Directory.CreateDirectory(folder); Util.NoLinks(folder);
                temp = Path.Combine(folder, ".ahna-" + Guid.NewGuid().ToString("N") + ".part");
                long bytes = 0;
                await using (var output = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
                {
                    var buffer = new byte[65536]; int read;
                    while ((read = await c.Request.Body.ReadAsync(buffer, c.RequestAborted)) > 0)
                    {
                        bytes += read; if (bytes > length) throw new IOException("Incomplete upload");
                        await output.WriteAsync(buffer.AsMemory(0, read), c.RequestAborted);
                        Interlocked.Add(ref t.transferred, read);
                    }
                }
                c.RequestAborted.ThrowIfCancellationRequested();
                if (bytes != length) throw new IOException("Incomplete upload");
                var destination = Path.Combine(folder, f.Name);
                for (var n = 1; ; n++)
                {
                    try { Util.NoLinks(destination); File.Move(temp!, destination); temp = null; break; }
                    catch (IOException) when (File.Exists(destination)) { destination = Path.Combine(folder, Path.GetFileNameWithoutExtension(f.Name) + $" ({n})" + Path.GetExtension(f.Name)); }
                }
                bool all;
                lock (t.Gate) { t.Completed[i] = true; all = t.Completed.All(x => x); }
                Record("receive", Path.GetFileName(destination), bytes, GuestDevice(t), "저장 완료");
                try { Received?.Invoke($"{t.Peer} · {Path.GetFileName(destination)}"); } catch { }
                if (all) EndTicket(t, "done"); else RaiseGuest(t);
                return Results.Ok(new { name = Path.GetFileName(destination), bytes });
            }
            catch
            {
                Record("receive", f.Name, length, GuestDevice(t), "실패");
                throw;
            }
            finally { if (temp is not null) { try { File.Delete(temp); } catch { } } uploads.Release(); }
        });
    }
    sealed record GuestRequestInput(string? Name, GuestRequestFile?[]? Files);
    sealed record GuestRequestFile(string? Name, long Bytes);
    sealed record NearbyModeInput(string? Mode);
    // Owner page hooks for nearby devices (Bluetooth) and the QR window. Mode: "off" | "registered" | "everyone".
    public interface INearbyHost
    {
        object Snapshot();
        void SetMode(string mode);
        Task<int> PickAndSendAsync(string id);
        void CancelSend();
        void OpenQr();
    }
    sealed record PairInput(string Pin, string? Name,bool Native=false,bool CanReceive=true,string? ComputerID=null,ReverseInput? Reverse=null);
    sealed record ReverseInput(string? Address, string? ComputerID, string? Token, string? Name);
    // Address: the 서버 origin where that host is reachable; ComputerId: its X-Ahna-Computer; Token: its "ahna" cookie.
    public sealed record ReverseCredential(string Address, string ComputerId, string Token, string Name);
    sealed record NativeSession(string Token,string Id,string Name,DateTimeOffset LastSeen,bool CanReceive,string? ComputerId=null);
    public sealed record PeerInfo(string Id, string Name, string ComputerId, bool Online);
    sealed record TargetInput(string Target);
    sealed record ReceiptInput(string Destination);
    sealed record ClipboardInput(string Text, string Target);
    sealed record OptionsInput(string? SavePath, bool Notifications, bool RecipientSavedNotifications, string? RemoteUrl, string? NasKey, bool? Startup, bool? ExplorerMenu);
    sealed record ExternalPairInput(string? Address, string? Pin);
    sealed record ExternalTextInput(string? Text);
    public sealed record IntegrationState(bool Startup, bool ExplorerMenu);
    public interface IExternalDevices
    {
        object Snapshot();
        Task<object> PairAsync(string address, string pin);
        Task RemoveAsync(string id);
        Task SendTextAsync(string id, string text);
        Task<int> PickAndSendFilesAsync(string id);
        void CancelSend();
    }
    public sealed record UpdateState(string Current, string? Latest, bool Available, bool FullInstallRequired, string Message);
}
