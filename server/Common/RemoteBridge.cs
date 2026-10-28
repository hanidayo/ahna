using System.Collections.Concurrent;
using System.Net.Http.Headers;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

namespace Ahna.Remote;

public sealed record BridgeConfig(string Url,string Key);
public sealed class RemoteBridge : IAsyncDisposable
{
    readonly Uri local;
    readonly string cache;
    readonly Func<BridgeConfig?> configuration;
    readonly bool testHttp;
    readonly string computerId;
    readonly Func<string>? pairingPin;
    readonly CancellationTokenSource stop=new();
    readonly SemaphoreSlim uploads=new(2,2);
    readonly HttpClient http=new(new SocketsHttpHandler{UseCookies=false,AllowAutoRedirect=false}){Timeout=TimeSpan.FromMinutes(45)};
    readonly Task supervisor;
    int disposed;
    CancellationTokenSource? connectionStop;
    volatile string status="서버 연결 꺼짐";
    public string Status=>status;
    public string? LastError { get; private set; }
    public RemoteBridge(Uri local,string cache,Func<BridgeConfig?> configuration,bool testHttp=false,string? computerId=null,Func<string>? pairingPin=null)
    {
        if(!local.IsLoopback || local.Scheme!="http")throw new ArgumentException("Local endpoint must be loopback HTTP.");
        this.local=local;this.cache=cache;this.configuration=configuration;this.testHttp=testHttp;
        this.computerId=computerId??Guid.NewGuid().ToString("N");this.pairingPin=pairingPin;
        if(Directory.Exists(cache))
        {
            NoLinks(cache);
            foreach(var file in Directory.EnumerateFiles(cache,"*.part"))
                if(Guid.TryParseExact(Path.GetFileNameWithoutExtension(file),"N",out _) && File.GetLastWriteTimeUtc(file)<DateTime.UtcNow.AddHours(-48))try{NoLinks(file);File.Delete(file);}catch{}
        }
        supervisor=Task.Run(Supervise);
    }
    public static Uri Validate(BridgeConfig config,bool testHttp=false)
    {
        if(!Uri.TryCreate(config.Url.Trim(),UriKind.Absolute,out var uri) || (uri.Scheme!="https" && !(testHttp && uri.Scheme=="http" && uri.IsLoopback)) || uri.AbsolutePath!="/" || uri.Query.Length>0 || uri.Fragment.Length>0 || uri.UserInfo.Length>0)throw new ArgumentException("서버 주소는 경로 없는 HTTPS 주소로 입력하세요. 예: https://ahna.example.synology.me");
        if(!Brand.IsMemberToken(config.Key) && (config.Key.Length<64 || !config.Key.All(Uri.IsHexDigit)))throw new ArgumentException("서버 연결 키는 64자리 이상의 임의의 16진수여야 합니다.");
        return uri;
    }
    public void Reload(){try{connectionStop?.Cancel();}catch(ObjectDisposedException){}}
    async Task Supervise()
    {
        while(!stop.IsCancellationRequested)
        {
            try
            {
                var config=configuration();
                if(config is null){status="서버 연결 꺼짐";await Task.Delay(1000,stop.Token);continue;}
                var endpoint=Validate(config,testHttp);
                using var linked=CancellationTokenSource.CreateLinkedTokenSource(stop.Token);connectionStop=linked;
                status="서버에 연결 중…";
                await Connect(endpoint,config.Key,linked.Token);
            }
            catch(OperationCanceledException){}
            catch(Exception ex){LastError=ex.Message;status="서버 재연결 대기 · 주소·연결 키·인증서를 확인하세요";try{await Task.Delay(4000,stop.Token);}catch(OperationCanceledException){}}
            finally{connectionStop=null;}
        }
    }
    static Uri SocketUri(Uri origin,string path)=>new UriBuilder(new Uri(origin,path)){Scheme=origin.Scheme=="https"?"wss":"ws"}.Uri;
    async Task Connect(Uri endpoint,string key,CancellationToken ct)
    {
        using var linked=CancellationTokenSource.CreateLinkedTokenSource(ct);
        using var control=new ClientWebSocket();control.Options.SetRequestHeader("Authorization","Bearer "+key);control.Options.KeepAliveInterval=TimeSpan.FromSeconds(15);
        control.Options.SetRequestHeader("X-Ahna-Computer",computerId);
        if(pairingPin is not null)control.Options.SetRequestHeader("X-Ahna-Pin-Hash",Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(pairingPin()))));
        await control.ConnectAsync(SocketUri(endpoint,"/_bridge/control"),linked.Token);
        status="서버 연결됨 · 원격 전송 가능";
        var jobs=new ConcurrentDictionary<int,Task>();int sequence=0;
        var ping=Task.Run(async()=>{try{while(!linked.IsCancellationRequested){await Wire.SendJson(control,new{type="ping"},linked.Token);await Task.Delay(15000,linked.Token);}}catch{linked.Cancel();}},linked.Token);
        try
        {
            while(!linked.IsCancellationRequested)
            {
                var message=await Wire.ReadJson<Dictionary<string,string>>(control,linked.Token);
                var id=message.GetValueOrDefault("id");
                if(!Guid.TryParseExact(id,"N",out _) || jobs.Count>=24)throw new IOException("Invalid relay request");
                var jobId=Interlocked.Increment(ref sequence);
                jobs[jobId]=Handle(endpoint,key,id!,linked.Token);
                _=jobs[jobId].ContinueWith(completed=>{jobs.TryRemove(jobId,out var removed);},TaskScheduler.Default);
            }
        }
        finally{linked.Cancel();control.Abort();try{await ping;}catch{}try{await Task.WhenAll(jobs.Values);}catch{}}
    }
    async Task Handle(Uri endpoint,string key,string id,CancellationToken ct)
    {
        using var timeout=CancellationTokenSource.CreateLinkedTokenSource(ct);timeout.CancelAfter(TimeSpan.FromMinutes(45));ct=timeout.Token;
        using var ws=new ClientWebSocket();ws.Options.SetRequestHeader("Authorization","Bearer "+key);
        string? temporary=null;bool held=false;
        try
        {
            await ws.ConnectAsync(SocketUri(endpoint,"/_bridge/data/"+id),ct);
            var head=await Wire.ReadJson<RequestHead>(ws,ct);
            if(!Wire.Allowed(head.Method,head.Path) || head.Length<0 || head.Length>Wire.MaxFile || !Wire.LargeBody(head.Path) && head.Length>16384){await Reject(ws,400,ct);return;}
            // Never expose local owner/admin sessions, even if a caller supplies a stolen owner cookie.
            if(head.Path.StartsWith("/api/") && head.Path.Split('?')[0]!="/api/pair")
            {
                // This authorization probe is not a heartbeat from the receiving
                // app. A share extension may be using the same native session.
                using var probe=new HttpRequestMessage(HttpMethod.Get,new Uri(local,"/api/state?receiving=false"));
                probe.Headers.TryAddWithoutValidation("Cookie",head.Cookie);probe.Headers.TryAddWithoutValidation("X-Ahna-Remote","1");
                using var auth=await http.SendAsync(probe,ct);
                if(!auth.IsSuccessStatusCode){await Reject(ws,(int)auth.StatusCode,ct);return;}
                using var state=JsonDocument.Parse(await auth.Content.ReadAsStringAsync(ct));
                if(state.RootElement.GetProperty("owner").GetBoolean()){await Reject(ws,403,ct);return;}
            }
            if(head.Method=="POST")
            {
                held=await uploads.WaitAsync(0,ct);if(!held){await Reject(ws,429,ct);return;}
                NoLinks(cache);Directory.CreateDirectory(cache);NoLinks(cache);
                temporary=Path.Combine(cache,Guid.NewGuid().ToString("N")+".part");
                await Wire.SendJson(ws,new ResponseHead(100),ct);
                await using(var file=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None,65536,true))await Wire.ReceiveBody(ws,file,head.Length,ct);
            }
            else await Wire.SendJson(ws,new ResponseHead(100),ct);
            using var request=new HttpRequestMessage(new HttpMethod(head.Method),new Uri(local,head.Path));
            request.Headers.TryAddWithoutValidation("Cookie",head.Cookie);request.Headers.TryAddWithoutValidation("X-Ahna-Remote","1");
            if(temporary is not null)
            {
                request.Content=new StreamContent(new FileStream(temporary,FileMode.Open,FileAccess.Read,FileShare.Read,65536,true));
                request.Content.Headers.ContentLength=head.Length;
                request.Content.Headers.ContentType=MediaTypeHeaderValue.Parse(head.ContentType??"application/octet-stream");
            }
            using var response=await http.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,ct);
            // Release the staging slot before publishing the result, so the next file in a batch can begin immediately.
            if(held)
            {
                request.Content?.Dispose();
                if(temporary is not null){File.Delete(temporary);temporary=null;}
                uploads.Release();held=false;
            }
            var headers=response.Headers.Concat(response.Content.Headers).ToDictionary(h=>h.Key,h=>h.Value.ToArray(),StringComparer.OrdinalIgnoreCase);
            // JSON/error responses are small. Files always retain their known length and stream directly.
            if(response.Content.Headers.ContentLength is not { } length || head.Path is "/" or "/index.html")
            {
                await using var input=await response.Content.ReadAsStreamAsync(ct);using var memory=new MemoryStream();
                var buffer=new byte[65536];int n;while((n=await input.ReadAsync(buffer,ct))>0){if(memory.Length+n>2*1024*1024)throw new IOException("Unbounded response");memory.Write(buffer,0,n);}
                var bytes=memory.ToArray();
                if(head.Path is "/" or "/index.html")bytes=Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(bytes).Replace("같은 네트워크에서","서버로 원격 연결").Replace("클라우드 없이, 내 네트워크 안에서 전송하세요.","집 서버를 통해 다른 네트워크에서도 전송하세요.").Replace("HTTP 로컬 전송 · 신뢰하는 개인 Wi-Fi에서 사용하세요.","HTTPS 서버 중계 · Windows 앱이 켜져 있어야 합니다."));
                await Wire.SendJson(ws,new ResponseHead((int)response.StatusCode,bytes.LongLength,headers),ct);
                await Wire.SendBody(ws,new MemoryStream(bytes),bytes.LongLength,ct);
            }
            else
            {
                await Wire.SendJson(ws,new ResponseHead((int)response.StatusCode,length,headers),ct);
                await using var input=await response.Content.ReadAsStreamAsync(ct);await Wire.SendBody(ws,input,length,ct);
            }
            // Retain the socket until the relay acknowledges all response bytes.
            await Receipt(ws,ct);
            await ws.CloseOutputAsync(WebSocketCloseStatus.NormalClosure,"done",ct);
        }
        catch(OperationCanceledException){}
        catch{if(ws.State==WebSocketState.Open){try{await Reject(ws,502,ct);await ws.CloseOutputAsync(WebSocketCloseStatus.InternalServerError,"failed",ct);}catch{}}}
        finally{if(temporary is not null){try{File.Delete(temporary);}catch{}}if(held)uploads.Release();}
    }
    static async Task Reject(WebSocket ws,int status,CancellationToken ct){await Wire.SendJson(ws,new ResponseHead(status,0),ct);await Receipt(ws,ct);}
    static async Task Receipt(WebSocket ws,CancellationToken ct){var receipt=await Wire.ReadJson<Dictionary<string,bool>>(ws,ct);if(!receipt.GetValueOrDefault("received"))throw new IOException("Relay did not acknowledge response");}
    static void NoLinks(string path){for(var p=Path.GetFullPath(path);!string.IsNullOrEmpty(p);p=Path.GetDirectoryName(p))if((Directory.Exists(p)||File.Exists(p))&&File.GetAttributes(p).HasFlag(FileAttributes.ReparsePoint))throw new IOException("Linked cache path");}
    public async ValueTask DisposeAsync(){if(Interlocked.Exchange(ref disposed,1)!=0)return;stop.Cancel();Reload();try{await supervisor;}catch{}http.Dispose();uploads.Dispose();stop.Dispose();}
}
