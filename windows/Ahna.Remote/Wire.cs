using System;
using System.IO;
using System.Linq;
using System.Net.WebSockets;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Ahna.Remote;

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
	public const long MaxFile = 4294967296L;

	public static bool Allowed(string method, string path)
	{
		string text = path.Split('?')[0];
		if (path.Length > 4096 || !path.StartsWith('/') || path.StartsWith("//") || path.Contains('#') || path.Contains('\\'))
		{
			return false;
		}
		bool flag = method == "GET";
		Guid result;
		if (flag)
		{
			bool flag2;
			switch (text)
			{
			case "/":
			case "/index.html":
			case "/app.js":
			case "/style.css":
			case "/api/state":
				flag2 = true;
				break;
			default:
				flag2 = false;
				break;
			}
			flag = flag2 || (text.StartsWith("/api/download/") && Guid.TryParseExact(text.Substring(14), "N", out result));
		}
		bool flag3 = flag;
		if (!flag3)
		{
			bool flag2 = method == "POST";
			if (flag2)
			{
				bool flag4;
				switch (text)
				{
				case "/api/pair":
				case "/api/logout":
				case "/api/upload":
					flag4 = true;
					break;
				default:
					flag4 = false;
					break;
				}
				flag2 = flag4 || (text.StartsWith("/api/received/") && Guid.TryParseExact(text.Substring(14), "N", out result));
			}
			flag3 = flag2;
		}
		return flag3 || GuestAllowed(method, text);
	}

	// 1.2 게스트 링크 (nas/Common/Wire.cs 와 같은 규칙): P = /s/{컴퓨터 ID 32자리 소문자 16진수}/{1회용 토큰}
	// GET P, P/info, P/status, P/file/{0-999} · POST P/decline, P/request, P/upload?i=..&name=..
	private static bool GuestAllowed(string method, string p)
	{
		if (GuestComputer(p) == null)
		{
			return false;
		}
		string rest = p.Substring(36);
		int slash = rest.IndexOf('/');
		string tail = slash < 0 ? "" : rest.Substring(slash);
		if (method == "GET")
		{
			return tail is "" or "/info" or "/status" || (tail.StartsWith("/file/", StringComparison.Ordinal) && tail.Length is > 6 and <= 9 && tail.Substring(6).All(char.IsAsciiDigit) && (tail.Length == 7 || tail[6] != '0'));
		}
		return method == "POST" && tail is "/decline" or "/request" or "/upload";
	}

	public static string? GuestComputer(string path)
	{
		string p = path.Split('?')[0];
		if (p.Length < 58 || !p.StartsWith("/s/", StringComparison.Ordinal) || p[35] != '/')
		{
			return null;
		}
		string cid = p.Substring(3, 32);
		if (!cid.All((char c) => c is >= '0' and <= '9' or >= 'a' and <= 'f'))
		{
			return null;
		}
		string rest = p.Substring(36);
		int slash = rest.IndexOf('/');
		string token = slash < 0 ? rest : rest.Substring(0, slash);
		return token.Length is >= 22 and <= 64 && token.All((char c) => char.IsAsciiLetterOrDigit(c) || c == '-' || c == '_') ? cid : null;
	}

	public static bool LargeBody(string path)
	{
		string p = path.Split('?')[0];
		return p == "/api/upload" || (GuestComputer(p) != null && p.EndsWith("/upload", StringComparison.Ordinal) && p.Count((char c) => c == '/') == 4);
	}

	public static Task SendJson<T>(WebSocket ws, T value, CancellationToken ct)
	{
		return ws.SendAsync(JsonSerializer.SerializeToUtf8Bytes(value), WebSocketMessageType.Text, endOfMessage: true, ct);
	}

	public static async Task<T> ReadJson<T>(WebSocket ws, CancellationToken ct)
	{
		using MemoryStream m = new MemoryStream();
		byte[] buffer = new byte[4096];
		WebSocketReceiveResult webSocketReceiveResult;
		do
		{
			webSocketReceiveResult = await ws.ReceiveAsync(buffer, ct);
			if (webSocketReceiveResult.MessageType != WebSocketMessageType.Text || m.Length + webSocketReceiveResult.Count > 32768)
			{
				throw new IOException("Invalid relay message");
			}
			m.Write(buffer, 0, webSocketReceiveResult.Count);
		}
		while (!webSocketReceiveResult.EndOfMessage);
		T val = JsonSerializer.Deserialize<T>(m.ToArray());
		if (val == null)
		{
			throw new IOException("Missing relay message");
		}
		return val;
	}

	public static async Task SendBody(WebSocket ws, Stream input, long length, CancellationToken ct)
	{
		byte[] buffer = new byte[65536];
		long left = length;
		while (left > 0)
		{
			int n = await input.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, left)), ct);
			if (n == 0)
			{
				throw new IOException("Incomplete body");
			}
			await ws.SendAsync(buffer.AsMemory(0, n), WebSocketMessageType.Binary, endOfMessage: true, ct);
			left -= n;
		}
	}

	public static async Task ReceiveBody(WebSocket ws, Stream output, long length, CancellationToken ct)
	{
		byte[] buffer = new byte[65536];
		long left = length;
		while (left > 0)
		{
			WebSocketReceiveResult r = await ws.ReceiveAsync(buffer, ct);
			if (r.MessageType != WebSocketMessageType.Binary || r.Count == 0 || r.Count > left)
			{
				throw new IOException("Invalid relay body");
			}
			await output.WriteAsync(buffer.AsMemory(0, r.Count), ct);
			left -= r.Count;
		}
	}
}
