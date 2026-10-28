using System.Net.WebSockets;
using System.Text.Json;

namespace Ahna.Remote;

public sealed record RequestHead(string Method, string Path, long Length, string? Cookie, string? ContentType);
public sealed record ResponseHead(int Status, long? Length = null, Dictionary<string,string[]>? Headers = null);
// Build flavor. scripts/ahna-brand.py rewrites these three lines for the friends-only app 아나 (Ahna).
public static class Brand
{
    public const bool Ahna = true;
    public const string Name = "아나";
    public const string Server = "https://example.synology.me";
    // A member token from an Ahna server: ahna.{32 hex computer id}.{64 hex}
    public static bool IsMemberToken(string key)
    {
        var p = key.Split('.');
        return p.Length == 3 && p[0] == "ahna" && p[1].Length == 32 && p[2].Length == 64 && p[1].All(Uri.IsHexDigit) && p[2].All(Uri.IsHexDigit);
    }
}
public static class Wire
{
    public const long MaxFile = 4L * 1024 * 1024 * 1024;
    public static bool Allowed(string method, string path)
    {
        var p=path.Split('?')[0];
        if(path.Length>4096 || !path.StartsWith('/') || path.StartsWith("//") || path.Contains('#') || path.Contains('\\'))return false;
        return method=="GET" && (p is "/" or "/index.html" or "/app.js" or "/style.css" or "/api/state" || p.StartsWith("/api/download/") && Guid.TryParseExact(p[14..],"N",out _))
            || method=="POST" && (p is "/api/pair" or "/api/logout" or "/api/upload" || p.StartsWith("/api/received/") && Guid.TryParseExact(p[14..],"N",out _))
            || GuestAllowed(method,p);
    }
    // 1.2 guest links: P = /s/{computer id: 32 lowercase hex}/{one-time token}. The token is the only credential.
    // GET P, P/info, P/status, P/file/{0-999}; POST P/decline, P/request, P/upload?i=..&name=..
    static bool GuestAllowed(string method,string p)
    {
        if(GuestComputer(p) is null)return false;
        var rest=p[36..];
        var slash=rest.IndexOf('/');var tail=slash<0?"":rest[slash..];
        if(method=="GET")return tail is "" or "/info" or "/status" || tail.StartsWith("/file/") && tail.Length is >6 and <=9 && tail[6..].All(char.IsAsciiDigit) && (tail.Length==7 || tail[6]!='0');
        return method=="POST" && tail is "/decline" or "/request" or "/upload";
    }
    // The host a guest path belongs to, or null when the path is not a well-formed guest path.
    public static string? GuestComputer(string path)
    {
        var p=path.Split('?')[0];
        if(p.Length<3+32+1+22 || !p.StartsWith("/s/") || p[35]!='/')return null;
        var cid=p[3..35];
        if(!cid.All(c=>c is >='0' and <='9' or >='a' and <='f'))return null;
        var rest=p[36..];var slash=rest.IndexOf('/');var token=slash<0?rest:rest[..slash];
        return token.Length is >=22 and <=64 && token.All(c=>char.IsAsciiLetterOrDigit(c)||c=='-'||c=='_')?cid:null;
    }
    // Large raw bodies are allowed only for the normal upload and a guest upload (both ≤ MaxFile, Content-Length required).
    public static bool LargeBody(string path)
    {
        var p=path.Split('?')[0];
        return p=="/api/upload" || GuestComputer(p) is not null && p.EndsWith("/upload",StringComparison.Ordinal) && p.Count(c=>c=='/')==4;
    }
    // A guest page the browser opens directly (camera / shared link): allowed as a cross-site top-level navigation.
    public static bool GuestPage(string method,string path)=>method=="GET" && GuestComputer(path) is not null && path.Split('?')[0].Count(c=>c=='/')==3;
    public static Task SendJson<T>(WebSocket ws,T value,CancellationToken ct)=>ws.SendAsync(JsonSerializer.SerializeToUtf8Bytes(value),WebSocketMessageType.Text,true,ct);
    public static async Task<T> ReadJson<T>(WebSocket ws,CancellationToken ct)
    {
        using var m=new MemoryStream();var buffer=new byte[4096];WebSocketReceiveResult r;
        do {r=await ws.ReceiveAsync(buffer,ct);if(r.MessageType!=WebSocketMessageType.Text || m.Length+r.Count>32768)throw new IOException("Invalid relay message");m.Write(buffer,0,r.Count);}while(!r.EndOfMessage);
        return JsonSerializer.Deserialize<T>(m.ToArray())??throw new IOException("Missing relay message");
    }
    public static async Task SendBody(WebSocket ws,Stream input,long length,CancellationToken ct)
    {
        var buffer=new byte[65536];long left=length;
        while(left>0){var n=await input.ReadAsync(buffer.AsMemory(0,(int)Math.Min(buffer.Length,left)),ct);if(n==0)throw new IOException("Incomplete body");await ws.SendAsync(buffer.AsMemory(0,n),WebSocketMessageType.Binary,true,ct);left-=n;}
    }
    public static async Task ReceiveBody(WebSocket ws,Stream output,long length,CancellationToken ct)
    {
        var buffer=new byte[65536];long left=length;
        while(left>0){var r=await ws.ReceiveAsync(buffer,ct);if(r.MessageType!=WebSocketMessageType.Binary || r.Count==0 || r.Count>left)throw new IOException("Invalid relay body");await output.WriteAsync(buffer.AsMemory(0,r.Count),ct);left-=r.Count;}
    }
}
