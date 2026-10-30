using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Ahna.Remote;

var builder=WebApplication.CreateBuilder(args);
builder.WebHost.ConfigureKestrel(k=>{k.Limits.MaxRequestBodySize=Wire.MaxFile;k.Limits.RequestHeadersTimeout=TimeSpan.FromSeconds(15);});
builder.Logging.ClearProviders();
var app=builder.Build();
var key=Environment.GetEnvironmentVariable("AHNA_KEY")??"";
var publicOrigin=Environment.GetEnvironmentVariable("AHNA_ORIGIN")??"";
var testing=Environment.GetEnvironmentVariable("AHNA_TEST_HTTP")=="1";
if(key.Length<64 || !key.All(Uri.IsHexDigit))throw new InvalidOperationException("AHNA_KEY must contain at least 64 random hex characters.");
if(!Uri.TryCreate(publicOrigin,UriKind.Absolute,out var publicUri) || (publicUri.Scheme!="https" && !(testing && publicUri.Scheme=="http" && publicUri.IsLoopback)) || publicUri.AbsolutePath!="/" || publicUri.UserInfo.Length>0 || publicUri.Query.Length>0 || publicUri.Fragment.Length>0)throw new InvalidOperationException("AHNA_ORIGIN must be an HTTPS origin, without a path.");
publicOrigin=publicUri.GetLeftPart(UriPartial.Authority);
var expectedKey=SHA256.HashData(Encoding.UTF8.GetBytes("Bearer "+key));
var pending=new ConcurrentDictionary<string,(TaskCompletionSource<WebSocket> Waiting,RelayConnection Bridge)>();
var controls=new ConcurrentDictionary<string,RelayConnection>();
var requests=new SemaphoreSlim(24,24);
var pairGate=new object();var pairAttempts=new Dictionary<string,(int Count,DateTimeOffset Since)>();
int pairTotal=0;var pairWindow=DateTimeOffset.UtcNow;
bool Authorized(HttpContext c)=>CryptographicOperations.FixedTimeEquals(SHA256.HashData(Encoding.UTF8.GetBytes(c.Request.Headers.Authorization.ToString())),expectedKey);
// 아나(Ahna): when AHNA_INVITE is set, a device joins with the invite code and receives a token bound to its own
// computer id: "ahna.{computer}.{HMAC(key, computer)}". Nothing is stored; changing AHNA_KEY revokes every token.
var invite=(Environment.GetEnvironmentVariable("AHNA_INVITE")??"").Trim();
if(invite.Length is >0 and <6)throw new InvalidOperationException("AHNA_INVITE must be at least 6 characters.");
var inviteHash=SHA256.HashData(Encoding.UTF8.GetBytes(invite.ToUpperInvariant()));
var revoked=new HashSet<string>((Environment.GetEnvironmentVariable("AHNA_REVOKED")??"").Split(',',StringSplitOptions.RemoveEmptyEntries|StringSplitOptions.TrimEntries),StringComparer.OrdinalIgnoreCase);
var joinGate=new object();var joinAttempts=new Dictionary<string,(int Count,DateTimeOffset Since)>();
var dataRoot=Environment.GetEnvironmentVariable("AHNA_DATA")??"/data";
// 관리자 페이지: 서버에 연결한 기기 목록·사용량·차단·초기화 (/data/admin.json)
var registry=new AdminStore(Path.Combine(dataRoot,"admin.json"));
// 기기를 초기화하거나 전체 초기화하면 세대 번호가 바뀌어 예전 토큰이 더 이상 맞지 않습니다(둘 다 0이면 처음 형식 그대로).
string DeviceToken(string computer){var (gen,epoch)=registry.Generation(computer);var suffix=gen==0&&epoch==0?"":$":{epoch}:{gen}";return Convert.ToHexString(HMACSHA256.HashData(Encoding.UTF8.GetBytes(key),Encoding.UTF8.GetBytes("ahna:"+computer+suffix))).ToLowerInvariant();}
bool IsBlocked(string computer)=>revoked.Contains(computer)||registry.Blocked(computer);
// 컨테이너는 127.0.0.1에만 열려 있어 NAS의 역방향 프록시만 들어옵니다. 프록시가 붙여 준 실제 주소를 씁니다.
string ClientIp(HttpContext c){var remote=c.Connection.RemoteIpAddress;var forwarded=c.Request.Headers["X-Forwarded-For"].ToString().Split(',',StringSplitOptions.RemoveEmptyEntries|StringSplitOptions.TrimEntries);return remote is not null&&System.Net.IPAddress.IsLoopback(remote.IsIPv4MappedToIPv6?remote.MapToIPv4():remote)&&forwarded.Length>0?forwarded[^1]:remote?.ToString()??"";}
string CleanText(string? value,int max){var t=new string((value??"").Where(ch=>!char.IsControl(ch)).ToArray()).Trim();return t.Length>max?t[..max]:t;}
const string ResetText="관리자가 이 기기의 서버 연결을 초기화했습니다. 초대 코드를 다시 입력하면 다시 연결됩니다.";
const string BlockedText="서버 관리자가 이 기기를 차단했습니다. 서버를 통한 전송을 쓸 수 없습니다.";
// The computer id a device token speaks for, or null (admin key or no token).
string? TokenComputer(HttpContext c)
{
    if(invite.Length==0)return null;
    var auth=c.Request.Headers.Authorization.ToString();
    if(!auth.StartsWith("Bearer ahna.",StringComparison.Ordinal))return null;
    var parts=auth[7..].Split('.');
    if(parts.Length!=3||!Guid.TryParseExact(parts[1],"N",out _)||parts[1]!=parts[1].ToLowerInvariant()||IsBlocked(parts[1]))return null;
    if(!CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(parts[2]),Encoding.ASCII.GetBytes(DeviceToken(parts[1]))))return null;
    registry.Touch(parts[1],ClientIp(c));
    return parts[1];
}
// 초기화·차단으로 더 이상 맞지 않는 토큰을 가진, 서버가 아는 기기 ID (그 기기에 다시 연결하라고 알려 줄 때)
string? StaleComputer(HttpContext c)
{
    var auth=c.Request.Headers.Authorization.ToString();
    if(invite.Length==0||!auth.StartsWith("Bearer ahna.",StringComparison.Ordinal))return null;
    var parts=auth[7..].Split('.');
    return parts.Length==3&&Guid.TryParseExact(parts[1],"N",out _)&&parts[1]==parts[1].ToLowerInvariant()&&registry.Known(parts[1])?parts[1]:null;
}
var relayVersion=typeof(Wire).Assembly.GetName().Version is { } v?$"{v.Major}.{v.Minor}.{v.Build}":"0.0.0";
app.UseWebSockets(new WebSocketOptions{KeepAliveInterval=TimeSpan.FromSeconds(20)});
// Container health check: answered before the Host check so Docker can probe 127.0.0.1 inside the container.
app.Use(async(c,next)=>
{
    if(c.Request.Path=="/_ahna/health"&&c.Request.Method=="GET"){c.Response.Headers.CacheControl="no-store";await c.Response.WriteAsJsonAsync(new{status="ok",version=relayVersion});return;}
    await next(c);
});
app.Use(async(c,next)=>
{
    c.Response.Headers.CacheControl="no-store";c.Response.Headers["Referrer-Policy"]="no-referrer";c.Response.Headers["X-Content-Type-Options"]="nosniff";
    if(!string.Equals(c.Request.Host.Value,publicUri.Authority,StringComparison.OrdinalIgnoreCase)){c.Response.StatusCode=400;return;}
    var origin=c.Request.Headers.Origin.ToString();
    // A guest link (/s/...) may be opened from another site (a shared link or a messenger); only that page view is let through.
    if((origin.Length>0 && origin!=publicOrigin) || c.Request.Headers["Sec-Fetch-Site"]=="cross-site" && !((Wire.GuestPage(c.Request.Method,c.Request.Path.Value??"") || c.Request.Method=="GET" && (c.Request.Path.StartsWithSegments("/_ahna/update") || c.Request.Path=="/_ahna/download" || c.Request.Path=="/d")) && c.Request.Headers["Sec-Fetch-Mode"]=="navigate")){c.Response.StatusCode=403;return;}
    try{await next(c);}catch(OperationCanceledException){if(!c.Response.HasStarted)c.Response.StatusCode=504;else c.Abort();}
    catch{if(!c.Response.HasStarted){c.Response.StatusCode=502;await c.Response.WriteAsync("아나 연결이 끊겼습니다. 상대 기기의 아나와 인터넷 연결을 확인하세요.");}else c.Abort();}
});
app.MapGet("/_ahna/version",()=>Results.Json(new{name="ahna-relay",version=relayVersion,invite=invite.Length>0}));
// 앱 업데이트: GitHub Actions가 빌드한 파일을 PUT /_ahna/admin/update/{이름} 으로 올리고(AHNA_PUBLISH_KEY),
// 앱은 GET /_ahna/update/latest.json 을 확인합니다. 파일은 컨테이너의 /data 볼륨에 있어 컨테이너를 다시 만들 필요가 없습니다.
var updateDir=Path.Combine(dataRoot,"updates");
var publishKey=(Environment.GetEnvironmentVariable("AHNA_PUBLISH_KEY")??"").Trim();
if(publishKey.Length is >0 and <32)throw new InvalidOperationException("AHNA_PUBLISH_KEY must be at least 32 characters.");
var publishHash=SHA256.HashData(Encoding.UTF8.GetBytes("Bearer "+publishKey));
bool UpdateName(string n)=>n.Length is >0 and <=100 && n[0]!='.' && n.All(ch=>char.IsAsciiLetterOrDigit(ch)||ch is '.' or '-' or '_');
app.MapGet("/_ahna/update/{name}",(string name)=>
{
    var path=Path.Combine(updateDir,name);
    if(!UpdateName(name)||!File.Exists(path))return Results.NotFound();
    var type=name.EndsWith(".json",StringComparison.OrdinalIgnoreCase)?"application/json; charset=utf-8":"application/octet-stream";
    return Results.File(path,type,name.EndsWith(".json",StringComparison.OrdinalIgnoreCase)?null:name,enableRangeProcessing:true);
});
// 짧은 주소: {서버}/d → 내려받기 화면
app.MapGet("/d",()=>Results.Redirect("/_ahna/download"));
// 지인에게 보낼 수 있는 내려받기 화면
app.MapGet("/_ahna/download",async (HttpContext c)=>
{
    string version="",windows="",ios="",android="",mac="";bool windowsSetup=false;
    try
    {
        using var doc=JsonDocument.Parse(await File.ReadAllBytesAsync(Path.Combine(updateDir,"latest.json")));
        version=doc.RootElement.GetProperty("version").GetString()??"";
        string Link(string key)=>doc.RootElement.GetProperty("platforms").TryGetProperty(key,out var p)?p.GetProperty("url").GetString()??"":"";
        windows=Link("windows");ios=Link("ios");android=Link("android");mac=Link("mac");
        // Windows는 설치 파일 하나(있으면)
        if(doc.RootElement.TryGetProperty("downloads",out var extra)&&extra.TryGetProperty("windows",out var setup)&&setup.GetString() is { Length: >0 } setupUrl){windows=setupUrl;windowsSetup=true;}
    }catch{}
    string Row(string title,string url,string note)=>url.Length==0?"":$"<a class=\"row\" href=\"{System.Net.WebUtility.HtmlEncode(url)}\"><b>{title}</b><small>{note}</small></a>";
    c.Response.ContentType="text/html; charset=utf-8";
    c.Response.Headers["Content-Security-Policy"]="default-src 'none'; style-src 'unsafe-inline'; img-src data:";
    await c.Response.WriteAsync($$$"""
<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>아나 내려받기</title>
<style>:root{--bg:#eef1f5;--s:#fff;--t:#1b1b1b;--m:#5c5c5c;--a:#005fb8;--b:#e3e6ea}@media(prefers-color-scheme:dark){:root{--bg:#1c1c1c;--s:#272727;--t:#f0f0f0;--m:#c5c5c5;--a:#4cc2ff;--b:#3a3a3a}}
body{margin:0;background:var(--bg);color:var(--t);font-family:system-ui,'Malgun Gothic',sans-serif}main{max-width:460px;margin:0 auto;padding:40px 16px}
.logo{width:64px;height:64px;border-radius:16px;background:#005fb8;display:grid;place-items:center}h1{font-size:30px;margin:16px 0 4px}p{color:var(--m);margin:0 0 24px}.mean{color:var(--t);font-size:15px;margin:0 0 10px;line-height:1.5}
.row{display:flex;flex-direction:column;gap:2px;padding:14px 16px;margin-bottom:10px;border-radius:12px;background:var(--s);border:1px solid var(--b);color:var(--t);text-decoration:none}.row b{color:var(--a)}.row small{color:var(--m)}</style></head>
<body><main><div class="logo"><svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 2 11 13"/><path d="M22 2 15 22l-4-9-9-4 20-7z"/></svg></div>
<h1>아나</h1><p class="mean">경상도 말로 “옛다, 받아라”<br>— 툭 건네듯 주고받는 앱입니다</p>{{{(version.Length>0?"<p>v"+System.Net.WebUtility.HtmlEncode(version)+"</p>":"")}}}
{{{Row("Windows",windows,windowsSetup?"내려받아 실행하면 설치됩니다. ‘Windows의 PC 보호’ 창이 뜨면 [추가 정보] → [실행]을 누르세요.":"압축을 풀고 설치.cmd 실행")}}}{{{Row("iPhone · iPad",ios,"IPA 파일")}}}{{{Row("Android",android,"APK 설치")}}}{{{Row("Mac",mac,"압축을 풀고 아나를 응용 프로그램 폴더로 옮기세요. 처음 열 때 ‘확인되지 않은 개발자’ 경고가 뜨면 시스템 설정 › 개인정보 보호 및 보안 맨 아래의 [그래도 열기]를 누르세요.")}}}
</main></body></html>
""");
});
app.MapPut("/_ahna/admin/update/{name}",async (string name,HttpContext c)=>
{
    if(publishKey.Length==0){c.Response.StatusCode=404;return;}
    if(!CryptographicOperations.FixedTimeEquals(SHA256.HashData(Encoding.UTF8.GetBytes(c.Request.Headers.Authorization.ToString())),publishHash)){c.Response.StatusCode=401;return;}
    if(!UpdateName(name)){c.Response.StatusCode=400;return;}
    Directory.CreateDirectory(updateDir);
    var part=Path.Combine(updateDir,"."+Guid.NewGuid().ToString("N")+".part");
    try
    {
        await using(var file=new FileStream(part,FileMode.CreateNew,FileAccess.Write,FileShare.None,1<<16,FileOptions.Asynchronous))await c.Request.Body.CopyToAsync(file,c.RequestAborted);
        File.Move(part,Path.Combine(updateDir,name),true);
    }
    finally{if(File.Exists(part))File.Delete(part);}
    // latest.json이 마지막에 올라오면, 거기에 없는 예전 파일은 지웁니다.
    if(name=="latest.json")
    {
        var keep=new HashSet<string>(StringComparer.Ordinal){"latest.json"};
        try
        {
            using var doc=JsonDocument.Parse(await File.ReadAllBytesAsync(Path.Combine(updateDir,name)));
            foreach(var p in doc.RootElement.GetProperty("platforms").EnumerateObject())keep.Add((p.Value.GetProperty("url").GetString()??"").Split('/').Last());
            if(doc.RootElement.TryGetProperty("downloads",out var extra))foreach(var p in extra.EnumerateObject())keep.Add((p.Value.GetString()??"").Split('/').Last());
            foreach(var f in Directory.GetFiles(updateDir))if(!keep.Contains(Path.GetFileName(f)))File.Delete(f);
        }catch(JsonException){}
    }
    await c.Response.WriteAsJsonAsync(new{saved=name});
});
app.MapPost("/_ahna/join",async (HttpContext c)=>
{
    if(invite.Length==0){c.Response.StatusCode=404;return;}
    lock(joinGate)
    {
        var now=DateTimeOffset.UtcNow;var ip=c.Connection.RemoteIpAddress?.ToString()??"unknown";
        var attempt=joinAttempts.GetValueOrDefault(ip);
        if(now-attempt.Since>TimeSpan.FromMinutes(10))attempt=(0,now);
        if(attempt.Count>=10){c.Response.StatusCode=429;return;}
        joinAttempts[ip]=(attempt.Count+1,attempt.Since);
        if(joinAttempts.Count>4096)joinAttempts.Clear();
    }
    if(c.Request.ContentLength is null or >4096){c.Response.StatusCode=411;return;}
    Dictionary<string,string>? body;
    try{body=await JsonSerializer.DeserializeAsync<Dictionary<string,string>>(c.Request.Body,cancellationToken:c.RequestAborted);}catch(JsonException){c.Response.StatusCode=400;return;}
    var code=(body?.GetValueOrDefault("invite")??"").Trim().ToUpperInvariant();
    var computer=(body?.GetValueOrDefault("computer")??"").ToLowerInvariant();
    if(!Guid.TryParseExact(computer,"N",out _)){c.Response.StatusCode=400;return;}
    if(!CryptographicOperations.FixedTimeEquals(SHA256.HashData(Encoding.UTF8.GetBytes(code)),inviteHash)){c.Response.StatusCode=403;await c.Response.WriteAsJsonAsync(new{error="초대 코드가 맞지 않습니다."});return;}
    if(IsBlocked(computer)){c.Response.StatusCode=403;await c.Response.WriteAsJsonAsync(new{error="이 기기는 서버 관리자가 차단했습니다."});return;}
    registry.Touch(computer,ClientIp(c),CleanText(body?.GetValueOrDefault("name"),40),CleanText(body?.GetValueOrDefault("platform"),20));
    await c.Response.WriteAsJsonAsync(new{token=$"ahna.{computer}.{DeviceToken(computer)}"});
});
app.MapGet("/_bridge/control",async (HttpContext c)=>
{
    var member=TokenComputer(c);
    // 알림을 받을 수 있는 앱(X-Ahna-Features: notice)이면, 초기화·차단된 기기에 이유를 알려 주고 닫습니다.
    var features=c.Request.Headers["X-Ahna-Features"].ToString().Split(',',StringSplitOptions.TrimEntries);
    var notices=features.Contains("notice");
    if(member is null&&!Authorized(c)&&notices&&c.WebSockets.IsWebSocketRequest&&StaleComputer(c) is { } stale)
    {
        using var gone=await c.WebSockets.AcceptWebSocketAsync();
        var blocked=IsBlocked(stale);
        try{await Wire.SendJson(gone,new Dictionary<string,string>{["type"]="notice",["action"]=blocked?"blocked":"rejoin",["text"]=blocked?BlockedText:ResetText},c.RequestAborted);await gone.CloseAsync(WebSocketCloseStatus.PolicyViolation,"",c.RequestAborted);}catch{}
        return;
    }
    if(!(Authorized(c)||member is not null) || !c.WebSockets.IsWebSocketRequest){c.Response.StatusCode=401;return;}
    var computer=c.Request.Headers["X-Ahna-Computer"].ToString();
    // A member token only ever registers its own computer id.
    if(member is not null&&computer!=member){c.Response.StatusCode=403;return;}
    if(computer.Length==0)computer="legacy";
    if(computer!="legacy"&&!Guid.TryParseExact(computer,"N",out _)){c.Response.StatusCode=400;return;}
    if(computer!="legacy"&&IsBlocked(computer)){c.Response.StatusCode=403;return;}
    if(controls.ContainsKey(computer)){c.Response.StatusCode=409;return;}
    string deviceName;try{deviceName=CleanText(Uri.UnescapeDataString(c.Request.Headers["X-Ahna-Name"].ToString()),40);}catch(UriFormatException){deviceName="";}
    if(computer!="legacy")registry.Touch(computer,ClientIp(c),deviceName,CleanText(c.Request.Headers["X-Ahna-Platform"].ToString(),20));
    using var ws=await c.WebSockets.AcceptWebSocketAsync();
    var bridge=new RelayConnection(computer,ws,c.Request.Headers["X-Ahna-Pin-Hash"].ToString(),notices,features.Contains("notices"));
    if(!controls.TryAdd(computer,bridge)){ws.Abort();return;}
    try{while(ws.State==WebSocketState.Open){using var idle=CancellationTokenSource.CreateLinkedTokenSource(c.RequestAborted);idle.CancelAfter(TimeSpan.FromSeconds(45));var ping=await Wire.ReadJson<Dictionary<string,string>>(ws,idle.Token);if(ping.GetValueOrDefault("type")!="ping")break;}}
    finally{controls.TryRemove(computer,out _);foreach(var item in pending.Where(p=>ReferenceEquals(p.Value.Bridge,bridge)))if(pending.TryRemove(item.Key,out var job))job.Waiting.TrySetCanceled();}
});
app.MapGet("/_bridge/data/{id}",async (HttpContext c)=>
{
    var id=c.Request.RouteValues["id"]?.ToString()??"";
    var member=TokenComputer(c);
    if(!(Authorized(c)||member is not null)||!c.WebSockets.IsWebSocketRequest||!pending.TryGetValue(id,out var waiting)||member is not null&&waiting.Bridge.Id!=member||!pending.TryRemove(id,out _)){c.Response.StatusCode=401;return;}
    using var ws=await c.WebSockets.AcceptWebSocketAsync();
    if(!waiting.Waiting.TrySetResult(ws)){ws.Abort();return;}
    // The HTTP request owns the socket until it closes it. Keep this endpoint alive.
    try{while(ws.State==WebSocketState.Open && !c.RequestAborted.IsCancellationRequested)await Task.Delay(200,c.RequestAborted);}catch(OperationCanceledException){}
});
// 맡겨 두기(drop): 아이폰 공유 메뉴처럼 받는 쪽 서버를 열 수 없는 곳에서 근처 기기로 보낼 때,
// 보내는 기기(가입한 기기)가 파일을 잠시 서버에 올려 두고 /s/{0×32}/{토큰} 주소를 근처 기기에 알립니다.
// 받는 쪽은 평소의 1회용 링크와 똑같이 info → file/{i}로 받습니다. 다 받거나 10분이 지나면 지웁니다.
var dropId=new string('0',32);
var dropDir=Path.Combine(dataRoot,"drops");
var drops=new ConcurrentDictionary<string,Drop>();
const long DropLimit=2L*1024*1024*1024;
try{if(Directory.Exists(dropDir))Directory.Delete(dropDir,true);}catch{}
void EndDrop(Drop d,string state){lock(d){if(d.State is "done" or "declined" or "expired")return;d.State=state;}_=Task.Run(async()=>{await Task.Delay(TimeSpan.FromSeconds(state=="done"?30:5));drops.TryRemove(d.Token,out _);try{Directory.Delete(Path.Combine(dropDir,d.Token),true);}catch{}});}
_=Task.Run(async()=>{while(true){await Task.Delay(TimeSpan.FromMinutes(1));foreach(var d in drops.Values)if(DateTimeOffset.UtcNow-d.Created>TimeSpan.FromMinutes(10))EndDrop(d,"expired");}});
Drop? OwnDrop(HttpContext c,string token)=>TokenComputer(c) is { } member&&drops.TryGetValue(token,out var d)&&d.Owner==member?d:null;
app.MapPost("/_ahna/drop",async (HttpContext c)=>
{
    var member=TokenComputer(c);
    if(member is null){c.Response.StatusCode=401;return;}
    if(OverLimit(member)){c.Response.StatusCode=429;await c.Response.WriteAsJsonAsync(new{error=LimitText(true)});return;}
    if(c.Request.ContentLength is null or >65536){c.Response.StatusCode=411;return;}
    if(drops.Values.Count(d=>d.Owner==member)>=4){c.Response.StatusCode=429;await c.Response.WriteAsJsonAsync(new{error="보내는 중인 것이 너무 많습니다. 잠시 후 다시 시도하세요."});return;}
    JsonDocument doc;
    try{doc=await JsonDocument.ParseAsync(c.Request.Body,cancellationToken:c.RequestAborted);}catch(JsonException){c.Response.StatusCode=400;return;}
    using(doc)
    {
        var root=doc.RootElement;
        var list=root.TryGetProperty("files",out var f)&&f.ValueKind==JsonValueKind.Array?f.EnumerateArray().ToArray():[];
        if(list.Length is <1 or >256){c.Response.StatusCode=400;return;}
        var files=new List<(string Name,long Bytes)>();
        foreach(var item in list)
        {
            var name=(item.TryGetProperty("name",out var n)?n.GetString():null)??"";
            var bytes=item.TryGetProperty("bytes",out var b)&&b.TryGetInt64(out var v)?v:-1;
            name=name.Replace('/','_').Replace('\\','_').Trim();
            if(name.Length is <1 or >255||name.StartsWith('.')||bytes<0){c.Response.StatusCode=400;return;}
            files.Add((name,bytes));
        }
        if(files.Sum(x=>x.Bytes)>DropLimit){c.Response.StatusCode=413;await c.Response.WriteAsJsonAsync(new{error="근처 기기로는 한 번에 2 GB까지 보낼 수 있습니다."});return;}
        var code=root.TryGetProperty("code",out var cd)?cd.GetString()??"":"";
        if(code.Length!=2||!code.All(char.IsAsciiDigit))code=RandomNumberGenerator.GetInt32(10,100).ToString(System.Globalization.CultureInfo.InvariantCulture);
        var sender=(root.TryGetProperty("sender",out var sn)?sn.GetString():null)??"아나";
        var token=Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).TrimEnd('=').Replace('+','-').Replace('/','_');
        var drop=new Drop(token,member,sender.Length>40?sender[..40]:sender,code,files.ToArray());
        Directory.CreateDirectory(Path.Combine(dropDir,token));
        drops[token]=drop;
        await c.Response.WriteAsJsonAsync(new{token,code,url=publicOrigin+"/s/"+dropId+"/"+token});
    }
});
app.MapPut("/_ahna/drop/{token}/{index:int}",async (string token,int index,HttpContext c)=>
{
    var d=OwnDrop(c,token);
    if(d is null||index<0||index>=d.Files.Length||d.State!="uploading"){c.Response.StatusCode=404;return;}
    // 큰 파일은 조각으로: X-Ahna-Offset(지금까지 올린 양)부터 이어 붙입니다.
    var offset=0L;
    if(c.Request.Headers["X-Ahna-Offset"].ToString() is { Length: >0 } offsetText&&!long.TryParse(offsetText,System.Globalization.NumberStyles.None,System.Globalization.CultureInfo.InvariantCulture,out offset)){c.Response.StatusCode=400;return;}
    var length=c.Request.ContentLength??-1;
    var target=Path.Combine(dropDir,token,index.ToString(System.Globalization.CultureInfo.InvariantCulture));
    var have=File.Exists(target)?new FileInfo(target).Length:0;
    if(offset!=have||length<0||offset+length>d.Files[index].Bytes||offset==0&&length==0&&d.Files[index].Bytes>0){c.Response.StatusCode=409;await c.Response.WriteAsJsonAsync(new{received=have});return;}
    await using(var file=new FileStream(target,offset==0?FileMode.Create:FileMode.Append,FileAccess.Write,FileShare.None,1<<16,FileOptions.Asynchronous))await c.Request.Body.CopyToAsync(file,c.RequestAborted);
    var size=new FileInfo(target).Length;
    if(size!=offset+length){c.Response.StatusCode=400;return;}
    Count(d.Owner,length);
    if(size==d.Files[index].Bytes)lock(d){d.Uploaded[index]=true;if(d.Uploaded.All(x=>x)&&d.State=="uploading")d.State="ready";}
    await c.Response.WriteAsJsonAsync(new{state=d.State,received=size});
});
});
app.MapGet("/_ahna/drop/{token}",(string token,HttpContext c)=>OwnDrop(c,token) is { } d?Results.Json(new{state=d.State,completed=d.Completed.Count(x=>x),count=d.Files.Length}):Results.NotFound());
app.MapPost("/_ahna/drop/{token}/cancel",(string token,HttpContext c)=>{if(OwnDrop(c,token) is { } d)EndDrop(d,"declined");return Results.Ok();});
// 받는 쪽(근처 기기): /s/{0×32}/{토큰}[/info|/status|/file/N|/decline]
async Task ServeDrop(HttpContext c,string path)
{
    var rest=path.Split('?')[0][36..];var slash=rest.IndexOf('/');
    var token=slash<0?rest:rest[..slash];var tail=slash<0?"":rest[slash..];
    if(!drops.TryGetValue(token,out var d)||d.State is "uploading"){c.Response.StatusCode=404;await c.Response.WriteAsJsonAsync(new{error="이미 끝났거나 없는 링크입니다."});return;}
    if(c.Request.Method=="GET"&&tail=="/info"){await c.Response.WriteAsJsonAsync(new{v=1,kind="send",owner=d.Sender,state=d.State,expiresIn=(int)Math.Max(0,(TimeSpan.FromMinutes(10)-(DateTimeOffset.UtcNow-d.Created)).TotalSeconds),code=d.Code,files=d.Files.Select((f,i)=>new{i,name=f.Name,bytes=f.Bytes})});return;}
    if(c.Request.Method=="GET"&&tail=="/status"){await c.Response.WriteAsJsonAsync(new{state=d.State,code=d.Code});return;}
    if(c.Request.Method=="POST"&&tail=="/decline"){lock(d){}if(d.State=="ready")EndDrop(d,"declined");await c.Response.WriteAsJsonAsync(new{state=d.State});return;}
    if(c.Request.Method=="GET"&&tail.StartsWith("/file/")&&int.TryParse(tail[6..],System.Globalization.NumberStyles.None,System.Globalization.CultureInfo.InvariantCulture,out var i)&&i>=0&&i<d.Files.Length)
    {
        lock(d){if(d.State is "done" or "declined" or "expired"){c.Response.StatusCode=404;return;}d.State="transferring";}
        var file=Path.Combine(dropDir,token,i.ToString(System.Globalization.CultureInfo.InvariantCulture));
        c.Response.ContentType="application/octet-stream";c.Response.ContentLength=new FileInfo(file).Length;
        c.Response.Headers.ContentDisposition="attachment; filename*=UTF-8''"+Uri.EscapeDataString(d.Files[i].Name);
        await c.Response.SendFileAsync(file,c.RequestAborted);
        Count(d.Owner,d.Files[i].Bytes);
        bool all;lock(d){d.Completed[i]=true;all=d.Completed.All(x=>x);}
        if(all)EndDrop(d,"done");
        return;
    }
    c.Response.StatusCode=404;
}
var chunks=new ConcurrentDictionary<string,ChunkUpload>();
app.MapFallback("/{**path}",async (HttpContext c)=>
{
    var path=c.Request.Path+c.Request.QueryString.ToString();
    if(Wire.GuestComputer(path)==dropId&&Wire.Allowed(c.Request.Method,path)){await ServeDrop(c,path);return;}
    if(!Wire.Allowed(c.Request.Method,path)){c.Response.StatusCode=404;return;}
    var length=c.Request.ContentLength??0;
    using var jsonBody=new MemoryStream();
    if(c.Request.Method=="POST" && c.Request.ContentLength is null)
    {
        if(Wire.LargeBody(path)){c.Response.StatusCode=411;return;}
        var buffer=new byte[4096];int n;
        while((n=await c.Request.Body.ReadAsync(buffer,c.RequestAborted))>0){if(jsonBody.Length+n>16384){c.Response.StatusCode=413;return;}jsonBody.Write(buffer,0,n);}
        length=jsonBody.Length;jsonBody.Position=0;c.Request.Body=jsonBody;
    }
    if(length<0 || length>Wire.MaxFile){c.Response.StatusCode=413;return;}
    if(c.Request.Method=="GET" && length!=0){c.Response.StatusCode=400;return;}
    if(!Wire.LargeBody(path) && length>16384){c.Response.StatusCode=413;return;}
    // 큰 파일 나눠 올리기: 첫 조각에 X-Ahna-Total(전체 크기)을 붙이면 받는 기기로는 한 요청처럼 이어서 보내고,
    // 나머지 조각은 PUT /_ahna/chunk/{upload}로 받습니다(Cloudflare 같은 프록시의 요청 크기 제한을 피함).
    long total=length;
    if(c.Request.Headers["X-Ahna-Total"].ToString() is { Length: >0 } totalText)
    {
        if(c.Request.Method!="POST"||!Wire.LargeBody(path)||!long.TryParse(totalText,System.Globalization.NumberStyles.None,System.Globalization.CultureInfo.InvariantCulture,out total)||total<length||total>Wire.MaxFile||length<1){c.Response.StatusCode=400;return;}
    }
    // Keep pair routing bounded and rate-limited, even when a PIN matches no PC.
    string? pinHash=null;
    if(c.Request.Method=="POST"&&path.Split('?')[0]=="/api/pair")
    {
        lock(pairGate)
        {
            var now=DateTimeOffset.UtcNow;var ip=c.Connection.RemoteIpAddress?.ToString()??"unknown";
            if(now-pairWindow>TimeSpan.FromMinutes(1)){pairTotal=0;pairWindow=now;pairAttempts.Clear();}
            var attempt=pairAttempts.GetValueOrDefault(ip);
            if(now-attempt.Since>TimeSpan.FromMinutes(1))attempt=(0,now);
            if(attempt.Count>=10||pairTotal>=60){c.Response.StatusCode=429;return;}
            pairAttempts[ip]=(attempt.Count+1,attempt.Since);pairTotal++;
        }
        if(jsonBody.Length==0)
        {
            var buffer=new byte[4096];int n;
            while((n=await c.Request.Body.ReadAsync(buffer,c.RequestAborted))>0){if(jsonBody.Length+n>16384){c.Response.StatusCode=413;return;}jsonBody.Write(buffer,0,n);}
        }
        length=jsonBody.Length;jsonBody.Position=0;c.Request.Body=jsonBody;
        try
        {
            using var body=JsonDocument.Parse(jsonBody.ToArray());
            if(body.RootElement.ValueKind!=JsonValueKind.Object||!body.RootElement.TryGetProperty("pin",out var pin)||pin.ValueKind!=JsonValueKind.String||pin.GetString() is not { Length:6 } code||!code.All(char.IsAsciiDigit)){c.Response.StatusCode=400;return;}
            pinHash=Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(code)));
        }
        catch(JsonException){c.Response.StatusCode=400;return;}
    }
    RelayConnection? selected=null;
    var online=controls.Values.ToArray();
    // A guest link names its host in the path (/s/{computer}/...), ahead of headers, cookies and codes.
    var guestHost=Wire.GuestComputer(path);
    var target=guestHost??c.Request.Headers["X-Ahna-Computer"].ToString();
    if(target.Length==0&&pinHash is null)target=c.Request.Cookies["ahna-computer"]??"";
    if(target.Length>0)controls.TryGetValue(target,out selected);
    else if(pinHash is not null)
    {
        var matches=online.Where(b=>b.PinHash==pinHash).ToArray();
        if(matches.Length>1){c.Response.StatusCode=409;await c.Response.WriteAsJsonAsync(new{error="연결 코드가 겹칩니다. 받는 기기에서 연결 코드를 새로 만든 뒤 다시 시도하세요."});return;}
        if(matches.Length==1)selected=matches[0];
        else if(online.Length==1&&online[0].PinHash.Length==0)selected=online[0];
        else if(!controls.IsEmpty){c.Response.StatusCode=401;return;}
    }
    else if(online.Length==1)selected=online[0];
    if(selected is null)
    {
        c.Response.StatusCode=target.Length>0||controls.IsEmpty?503:409;
        await c.Response.WriteAsJsonAsync(new{error=target.Length>0||controls.IsEmpty?"상대 기기가 오프라인입니다. 자동으로 다시 연결합니다.":"여러 기기가 연결되어 있습니다. 앱에서 연결 코드로 기기를 추가하세요."});return;
    }
    var heavy=Wire.LargeBody(path)||path.StartsWith("/api/download/")||guestHost is not null&&path.Split('?')[0].Contains("/file/");
    if(heavy&&OverLimit(selected.Id)){c.Response.StatusCode=429;await c.Response.WriteAsJsonAsync(new{error=LimitText(false)});return;}
    if(!await requests.WaitAsync(0,c.RequestAborted)){c.Response.StatusCode=429;return;}
    var id=Guid.NewGuid().ToString("N");
    using var timeout=CancellationTokenSource.CreateLinkedTokenSource(c.RequestAborted);timeout.CancelAfter(Wire.LargeBody(path) || path.StartsWith("/api/download/") || guestHost is not null && path.Split('?')[0].Contains("/file/")?TimeSpan.FromMinutes(45):TimeSpan.FromSeconds(40));
    var ct=timeout.Token;WebSocket? data=null;var handedOff=false;
    try
    {
        var bridge=selected.Socket;
        if(bridge.State!=WebSocketState.Open){c.Response.StatusCode=503;return;}
        var waiting=new TaskCompletionSource<WebSocket>(TaskCreationOptions.RunContinuationsAsynchronously);pending[id]=(waiting,selected);
        await selected.Send.WaitAsync(ct);try{await Wire.SendJson(bridge,new{id},ct);}finally{selected.Send.Release();}
        data=await waiting.Task.WaitAsync(TimeSpan.FromSeconds(20),ct);
        await Wire.SendJson(data,new RequestHead(c.Request.Method,path,total,c.Request.Headers.Cookie.ToString(),c.Request.ContentType),ct);
        var head=await Wire.ReadJson<ResponseHead>(data,ct);
        if(head.Status==100)
        {
            await Wire.SendBody(data,c.Request.Body,length,ct);
            if(total>length)
            {
                // 첫 조각만 보냄: 이 연결을 나눠 올리기로 넘기고, 나머지 조각을 기다립니다.
                var upload=Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
                chunks[upload]=new ChunkUpload(selected,data,path,guestHost,total){Sent=length,Touched=DateTimeOffset.UtcNow};
                data=null;handedOff=true;
                c.Response.StatusCode=202;await c.Response.WriteAsJsonAsync(new{upload,received=length});return;
            }
            head=await Wire.ReadJson<ResponseHead>(data,ct);
        }
        await Relay(c,data,head,selected,path,guestHost,total,ct);
    }
    finally{pending.TryRemove(id,out _);data?.Abort();data?.Dispose();if(!handedOff)requests.Release();}
});
// 받는 기기의 응답을 그대로 돌려줍니다.
async Task Relay(HttpContext c,WebSocket data,ResponseHead head,RelayConnection selected,string path,string? guestHost,long sent,CancellationToken ct)
{
    if(head.Status is <200 or >599 || head.Length is null or <0 || head.Length>Wire.MaxFile)throw new IOException("Invalid response");
    c.Response.StatusCode=head.Status;c.Response.ContentLength=head.Length;
    c.Response.Headers["X-Ahna-Computer"]=selected.Id;
    var allowed=new HashSet<string>(StringComparer.OrdinalIgnoreCase){"Content-Type","Content-Disposition","Content-Security-Policy","Set-Cookie","Cache-Control"};
    // Guest responses never set cookies on the NAS origin.
    if(guestHost is not null)allowed.Remove("Set-Cookie");
    if(head.Headers is not null)foreach(var h in head.Headers)if(allowed.Contains(h.Key))c.Response.Headers[h.Key]=h.Value;
    if(c.Response.Headers.TryGetValue("Set-Cookie",out var cookies))c.Response.Headers["Set-Cookie"]=cookies.Select(v=>v+"; Secure").ToArray();
    if(head.Status is >=200 and <300 && path.Split('?')[0] is "/api/pair" or "/api/state")
        c.Response.Cookies.Append("ahna-computer",selected.Id,new CookieOptions{HttpOnly=true,Secure=!testing,SameSite=SameSiteMode.Strict,Path="/",MaxAge=TimeSpan.FromDays(30)});
    await Wire.ReceiveBody(data,c.Response.Body,head.Length.Value,ct);
    Count(selected.Id,sent+head.Length.Value);
    await Wire.SendJson(data,new{received=true},ct);
}
// 나눠 올리기의 다음 조각: X-Ahna-Offset은 지금까지 보낸 양과 같아야 합니다. 마지막 조각이면 받는 기기의 응답을 돌려줍니다.
void EndChunk(string upload,ChunkUpload u){if(!chunks.TryRemove(upload,out _))return;try{u.Data.Abort();u.Data.Dispose();}catch{}requests.Release();}
_=Task.Run(async()=>{while(true){await Task.Delay(TimeSpan.FromSeconds(30));foreach(var item in chunks)if(DateTimeOffset.UtcNow-item.Value.Touched>TimeSpan.FromMinutes(3)&&item.Value.Gate.CurrentCount==1)EndChunk(item.Key,item.Value);}});
app.MapPut("/_ahna/chunk/{upload}",async (string upload,HttpContext c)=>
{
    if(!chunks.TryGetValue(upload,out var u)){c.Response.StatusCode=404;await c.Response.WriteAsJsonAsync(new{error="전송이 끊겼습니다. 처음부터 다시 보내 주세요."});return;}
    if(!await u.Gate.WaitAsync(0)){c.Response.StatusCode=409;return;}
    var finished=false;
    try
    {
        var length=c.Request.ContentLength??-1;
        if(!long.TryParse(c.Request.Headers["X-Ahna-Offset"].ToString(),System.Globalization.NumberStyles.None,System.Globalization.CultureInfo.InvariantCulture,out var offset)||offset!=u.Sent||length<1||u.Sent+length>u.Total)
        {c.Response.StatusCode=409;await c.Response.WriteAsJsonAsync(new{error="조각 순서가 맞지 않습니다.",received=u.Sent});return;}
        using var timeout=CancellationTokenSource.CreateLinkedTokenSource(c.RequestAborted);timeout.CancelAfter(TimeSpan.FromMinutes(45));var ct=timeout.Token;
        try
        {
            await Wire.SendBody(u.Data,c.Request.Body,length,ct);
            u.Sent+=length;u.Touched=DateTimeOffset.UtcNow;
            if(u.Sent<u.Total){c.Response.StatusCode=202;await c.Response.WriteAsJsonAsync(new{upload,received=u.Sent});return;}
            finished=true;
            var head=await Wire.ReadJson<ResponseHead>(u.Data,ct);
            await Relay(c,u.Data,head,u.Bridge,u.Path,u.GuestHost,u.Total,ct);
        }
        catch{finished=true;throw;}
    }
    finally{u.Gate.Release();if(finished)EndChunk(upload,u);}
});
// 사용량: 서버를 거친 양을 그 기기 몫으로 더하고, 오늘 처음 한도를 넘으면 그 기기 앱에 알립니다.
bool OverLimit(string computer)=>registry.Enforce&&registry.Used(computer)>=registry.LimitBytes;
string LimitText(bool own)=>(own?"이 기기":"받는 기기")+$"가 오늘 서버 사용량 한도({registry.LimitGB:0.#} GB)를 다 썼습니다. 내일 다시 시도하거나 서버 관리자에게 문의하세요.";
void Count(string computer,long bytes)
{
    if(computer=="legacy"||!registry.Add(computer,bytes))return;
    _=Notice(computer,registry.Enforce?$"오늘 서버 사용량이 한도({registry.LimitGB:0.#} GB)를 넘었습니다. 오늘은 서버를 통한 파일 전송이 막힙니다(0시에 풀립니다).":$"오늘 서버 사용량이 관리자가 정한 기준({registry.LimitGB:0.#} GB)을 넘었습니다. 큰 파일은 가까이 있을 때 근처 기기로 보내 주세요.","limit");
}
async Task<bool> Notice(string computer,string text,string action)
{
    if(!controls.TryGetValue(computer,out var r)||!r.Notices||action=="notices"&&!r.Board)return false;
    try
    {
        using var cts=new CancellationTokenSource(TimeSpan.FromSeconds(10));
        await r.Send.WaitAsync(cts.Token);
        try{await Wire.SendJson(r.Socket,new Dictionary<string,string>{["type"]="notice",["action"]=action,["text"]=text},cts.Token);}finally{r.Send.Release();}
        return true;
    }catch{return false;}
}
void Kick(string computer){if(controls.TryGetValue(computer,out var r))try{r.Socket.Abort();}catch{}}

// 전체 공지: 연결한 기기가 받아 갑니다. 새 공지가 생기거나 지워지면 온라인 기기에 "notices" 알림을 보내 다시 받아 가게 합니다.
app.MapGet("/_ahna/notices",(HttpContext c)=>TokenComputer(c) is null?Results.Unauthorized():Results.Json(new{notices=registry.Notices()}));
app.MapPost("/_ahna/notices/{id}/read",(string id,HttpContext c)=>{if(TokenComputer(c) is not { } member)return Results.Unauthorized();registry.ReadNotice(id,member);return Results.Ok();});
async Task BroadcastNotices(){foreach(var id in controls.Keys.Where(k=>k!="legacy").ToArray())await Notice(id,"","notices");}

// 관리자 페이지: .env의 AHNA_ADMIN_PASSWORD 가 있을 때만 열립니다.
var adminPassword=(Environment.GetEnvironmentVariable("AHNA_ADMIN_PASSWORD")??"").Trim();
if(adminPassword.Length is >0 and <8)throw new InvalidOperationException("AHNA_ADMIN_PASSWORD must be at least 8 characters.");
var adminHash=SHA256.HashData(Encoding.UTF8.GetBytes(adminPassword));
var adminGate=new object();var adminFails=new Dictionary<string,(int Count,DateTimeOffset Since)>();
string AdminSignature(long expires)=>Convert.ToHexString(HMACSHA256.HashData(Encoding.UTF8.GetBytes(key),Encoding.UTF8.GetBytes($"ahna-admin:{expires}:{Convert.ToHexString(adminHash)}"))).ToLowerInvariant();
bool IsAdmin(HttpContext c)
{
    if(adminPassword.Length==0||c.Request.Headers["X-Ahna-Admin"]!="1")return false;
    var parts=(c.Request.Cookies["ahna-admin"]??"").Split('.');
    return parts.Length==2&&long.TryParse(parts[0],out var expires)&&expires>DateTimeOffset.UtcNow.ToUnixTimeSeconds()&&CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(parts[1]),Encoding.ASCII.GetBytes(AdminSignature(expires)));
}
bool AdminDevice(string id)=>Guid.TryParseExact(id,"N",out _)&&id==id.ToLowerInvariant()&&registry.Known(id);
app.MapGet("/_ahna/admin",(HttpContext c)=>
{
    if(adminPassword.Length==0)return Results.NotFound();
    var nonce=Convert.ToBase64String(RandomNumberGenerator.GetBytes(16));
    c.Response.Headers["Content-Security-Policy"]=$"default-src 'none'; script-src 'nonce-{nonce}'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
    c.Response.Headers["X-Frame-Options"]="DENY";
    return Results.Content(AdminPage.Html(nonce),"text/html; charset=utf-8");
});
app.MapPost("/_ahna/admin/login",async (HttpContext c)=>
{
    if(adminPassword.Length==0||c.Request.Headers["X-Ahna-Admin"]!="1"){c.Response.StatusCode=404;return;}
    var ip=ClientIp(c);bool locked;
    lock(adminGate)
    {
        var now=DateTimeOffset.UtcNow;var fails=adminFails.GetValueOrDefault(ip);
        if(now-fails.Since>TimeSpan.FromMinutes(15))fails=(0,now);
        if(adminFails.Count>4096)adminFails.Clear();
        adminFails[ip]=fails;locked=fails.Count>=5;
    }
    if(locked){c.Response.StatusCode=429;await c.Response.WriteAsJsonAsync(new{error="비밀번호를 너무 많이 틀렸습니다. 15분 뒤에 다시 시도하세요."});return;}
    if(c.Request.ContentLength is null or >1024){c.Response.StatusCode=411;return;}
    Dictionary<string,string>? body;
    try{body=await JsonSerializer.DeserializeAsync<Dictionary<string,string>>(c.Request.Body,cancellationToken:c.RequestAborted);}catch(JsonException){c.Response.StatusCode=400;return;}
    if(!CryptographicOperations.FixedTimeEquals(SHA256.HashData(Encoding.UTF8.GetBytes(body?.GetValueOrDefault("password")??"")),adminHash))
    {
        lock(adminGate){var f=adminFails.GetValueOrDefault(ip);adminFails[ip]=(f.Count+1,f.Since);}
        await Task.Delay(800);c.Response.StatusCode=403;await c.Response.WriteAsJsonAsync(new{error="비밀번호가 맞지 않습니다."});return;
    }
    lock(adminGate)adminFails.Remove(ip);
    var expires=DateTimeOffset.UtcNow.AddHours(12).ToUnixTimeSeconds();
    c.Response.Cookies.Append("ahna-admin",$"{expires}.{AdminSignature(expires)}",new CookieOptions{HttpOnly=true,Secure=!testing,SameSite=SameSiteMode.Strict,Path="/_ahna/admin",MaxAge=TimeSpan.FromHours(12)});
    await c.Response.WriteAsJsonAsync(new{ok=true});
});
app.MapPost("/_ahna/admin/logout",(HttpContext c)=>{c.Response.Cookies.Delete("ahna-admin",new CookieOptions{Path="/_ahna/admin"});return Results.Ok();});
app.MapGet("/_ahna/admin/api/state",(HttpContext c)=>IsAdmin(c)?Results.Json(registry.Snapshot(id=>controls.ContainsKey(id))):Results.Unauthorized());
app.MapPost("/_ahna/admin/api/settings",async (HttpContext c)=>
{
    if(!IsAdmin(c)){c.Response.StatusCode=401;return;}
    JsonDocument doc;try{doc=await JsonDocument.ParseAsync(c.Request.Body,cancellationToken:c.RequestAborted);}catch(JsonException){c.Response.StatusCode=400;return;}
    using(doc)
    {
        var limit=doc.RootElement.TryGetProperty("limitGB",out var l)&&l.TryGetDouble(out var v)&&double.IsFinite(v)?v:0;
        var enforce=doc.RootElement.TryGetProperty("enforce",out var e)&&e.ValueKind==JsonValueKind.True;
        registry.Settings(limit,enforce);
    }
    await c.Response.WriteAsJsonAsync(new{ok=true});
});
app.MapPost("/_ahna/admin/api/device/{id}/{action}",async (string id,string action,HttpContext c)=>
{
    if(!IsAdmin(c)){c.Response.StatusCode=401;return;}
    if(!AdminDevice(id)){c.Response.StatusCode=404;await c.Response.WriteAsJsonAsync(new{error="없는 기기입니다."});return;}
    switch(action)
    {
        case "notice":
            string text="";
            try{using var doc=await JsonDocument.ParseAsync(c.Request.Body,cancellationToken:c.RequestAborted);text=CleanText(doc.RootElement.TryGetProperty("text",out var t)?t.GetString():"",200);}catch(JsonException){}
            if(text.Length==0){c.Response.StatusCode=400;await c.Response.WriteAsJsonAsync(new{error="알림 내용을 입력하세요."});return;}
            await c.Response.WriteAsJsonAsync(new{delivered=await Notice(id,"서버 관리자: "+text,"message")});return;
        case "block":
            registry.SetBlocked(id,true);await Notice(id,BlockedText,"blocked");Kick(id);break;
        case "unblock":
            registry.SetBlocked(id,false);break;
        case "reset":
            registry.Reset(id);await Notice(id,ResetText,"rejoin");Kick(id);break;
        case "hide":
            registry.Hide(id);break;
        default:
            c.Response.StatusCode=404;return;
    }
    await c.Response.WriteAsJsonAsync(new{ok=true});
});
app.MapPost("/_ahna/admin/api/notices",async (HttpContext c)=>
{
    if(!IsAdmin(c)){c.Response.StatusCode=401;return;}
    string text="";
    try{using var doc=await JsonDocument.ParseAsync(c.Request.Body,cancellationToken:c.RequestAborted);text=(doc.RootElement.TryGetProperty("text",out var t)?t.GetString()??"":"").Replace("\r\n","\n").Trim();}catch(JsonException){}
    text=new string(text.Where(ch=>ch=='\n'||!char.IsControl(ch)).ToArray());
    if(text.Length is 0 or >1000){c.Response.StatusCode=400;await c.Response.WriteAsJsonAsync(new{error="공지 내용을 1~1000자로 입력하세요."});return;}
    var id=registry.Announce(text);await BroadcastNotices();
    await c.Response.WriteAsJsonAsync(new{id});
});
app.MapPost("/_ahna/admin/api/notices/{id}/delete",async (string id,HttpContext c)=>
{
    if(!IsAdmin(c)){c.Response.StatusCode=401;return;}
    if(registry.RemoveNotice(id))await BroadcastNotices();
    await c.Response.WriteAsJsonAsync(new{ok=true});
});
app.MapPost("/_ahna/admin/api/reset-all",async (HttpContext c)=>
{
    if(!IsAdmin(c)){c.Response.StatusCode=401;return;}
    registry.ResetAll();
    foreach(var id in controls.Keys.Where(k=>k!="legacy").ToArray()){await Notice(id,ResetText,"rejoin");Kick(id);}
    await c.Response.WriteAsJsonAsync(new{ok=true});
});

await app.RunAsync();

sealed record RelayConnection(string Id,WebSocket Socket,string PinHash,bool Notices=false,bool Board=false)
{
    public SemaphoreSlim Send { get; }=new(1,1);
}

sealed class ChunkUpload(RelayConnection bridge,WebSocket data,string path,string? guestHost,long total)
{
    public RelayConnection Bridge{get;}=bridge; public WebSocket Data{get;}=data; public string Path{get;}=path; public string? GuestHost{get;}=guestHost;
    public long Total{get;}=total; public long Sent{get;set;}
    public DateTimeOffset Touched{get;set;}
    public SemaphoreSlim Gate{get;}=new(1,1);
}

sealed class Drop((string Name,long Bytes)[] files)
{
    public Drop(string token,string owner,string sender,string code,(string Name,long Bytes)[] files):this(files){Token=token;Owner=owner;Sender=sender;Code=code;Uploaded=new bool[files.Length];Completed=new bool[files.Length];State=files.All(f=>f.Bytes==0)?"ready":"uploading";}
    public string Token{get;}=""; public string Owner{get;}=""; public string Sender{get;}=""; public string Code{get;}="";
    public (string Name,long Bytes)[] Files{get;}=files;
    public bool[] Uploaded{get;}=[]; public bool[] Completed{get;}=[];
    public string State{get;set;}="uploading";
    public DateTimeOffset Created{get;}=DateTimeOffset.UtcNow;
}
