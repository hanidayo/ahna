using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Ahna.Remote;

public sealed class RemoteBridge : IAsyncDisposable
{
	private readonly Uri local;

	private readonly string cache;

	private readonly Func<BridgeConfig?> configuration;

	private readonly bool testHttp;

	private readonly string computerId;

	private readonly Func<string>? pairingPin;

	private readonly CancellationTokenSource stop = new CancellationTokenSource();

	private readonly SemaphoreSlim uploads = new SemaphoreSlim(2, 2);

	private readonly HttpClient http = new HttpClient(new SocketsHttpHandler
	{
		UseCookies = false,
		AllowAutoRedirect = false
	})
	{
		Timeout = TimeSpan.FromMinutes(45L)
	};

	private readonly Task supervisor;

	private int disposed;

	private CancellationTokenSource? connectionStop;

	private volatile string status = "서버 연결 꺼짐";

	public string Status => status;

	public string? LastError { get; private set; }

	public RemoteBridge(Uri local, string cache, Func<BridgeConfig?> configuration, bool testHttp = false, string? computerId = null, Func<string>? pairingPin = null)
	{
		if (!local.IsLoopback || local.Scheme != "http")
		{
			throw new ArgumentException("Local endpoint must be loopback HTTP.");
		}
		this.local = local;
		this.cache = cache;
		this.configuration = configuration;
		this.testHttp = testHttp;
		string text = computerId;
		Guid result;
		if (text == null)
		{
			result = Guid.NewGuid();
			text = result.ToString("N");
		}
		this.computerId = text;
		this.pairingPin = pairingPin;
		if (Directory.Exists(cache))
		{
			NoLinks(cache);
			foreach (string item in Directory.EnumerateFiles(cache, "*.part"))
			{
				if (Guid.TryParseExact(Path.GetFileNameWithoutExtension(item), "N", out result) && File.GetLastWriteTimeUtc(item) < DateTime.UtcNow.AddHours(-48.0))
				{
					try
					{
						NoLinks(item);
						File.Delete(item);
					}
					catch
					{
					}
				}
			}
		}
		supervisor = Task.Run((Func<Task?>)Supervise);
	}

	public static Uri Validate(BridgeConfig config, bool testHttp = false)
	{
		if (!Uri.TryCreate(config.Url.Trim(), UriKind.Absolute, out Uri result) || (result.Scheme != "https" && (!testHttp || !(result.Scheme == "http") || !result.IsLoopback)) || result.AbsolutePath != "/" || result.Query.Length > 0 || result.Fragment.Length > 0 || result.UserInfo.Length > 0)
		{
			throw new ArgumentException("서버 주소는 경로 없는 HTTPS 주소로 입력하세요. 예: https://ahna.example.synology.me");
		}
		if (!Brand.IsMemberToken(config.Key) && (config.Key.Length < 64 || !config.Key.All(Uri.IsHexDigit)))
		{
			throw new ArgumentException("서버 연결 키는 64자리 이상의 임의의 16진수여야 합니다.");
		}
		return result;
	}

	public void Reload()
	{
		try
		{
			connectionStop?.Cancel();
		}
		catch (ObjectDisposedException)
		{
		}
	}

	private async Task Supervise()
	{
		while (!stop.IsCancellationRequested)
		{
			try
			{
				BridgeConfig bridgeConfig = configuration();
				if ((object)bridgeConfig == null)
				{
					status = "서버 연결 꺼짐";
					await Task.Delay(1000, stop.Token);
					continue;
				}
				Uri endpoint = Validate(bridgeConfig, testHttp);
				using CancellationTokenSource linked = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
				connectionStop = linked;
				status = "서버에 연결 중…";
				await Connect(endpoint, bridgeConfig.Key, linked.Token);
			}
			catch (OperationCanceledException)
			{
			}
			catch (Exception ex2)
			{
				LastError = ex2.Message;
				status = "서버 재연결 대기 · 주소·연결 키·인증서를 확인하세요";
				try
				{
					await Task.Delay(4000, stop.Token);
				}
				catch (OperationCanceledException)
				{
				}
			}
			finally
			{
				connectionStop = null;
			}
		}
	}

	private static Uri SocketUri(Uri origin, string path)
	{
		return new UriBuilder(new Uri(origin, path))
		{
			Scheme = ((origin.Scheme == "https") ? "wss" : "ws")
		}.Uri;
	}

	private async Task Connect(Uri endpoint, string key, CancellationToken ct)
	{
		CancellationTokenSource linked = CancellationTokenSource.CreateLinkedTokenSource(ct);
		try
		{
			ClientWebSocket control = new ClientWebSocket();
			try
			{
				control.Options.SetRequestHeader("Authorization", "Bearer " + key);
				control.Options.KeepAliveInterval = TimeSpan.FromSeconds(15L);
				control.Options.SetRequestHeader("X-Ahna-Computer", computerId);
				if (pairingPin != null)
				{
					control.Options.SetRequestHeader("X-Ahna-Pin-Hash", Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(pairingPin()))));
				}
				await control.ConnectAsync(SocketUri(endpoint, "/_bridge/control"), linked.Token);
				status = "서버 연결됨 · 원격 전송 가능";
				ConcurrentDictionary<int, Task> jobs = new ConcurrentDictionary<int, Task>();
				int sequence = 0;
				Task ping = Task.Run(async () =>
				{
					_ = 1;
					try
					{
						while (!linked.IsCancellationRequested)
						{
							await Wire.SendJson(control, new
							{
								type = "ping"
							}, linked.Token);
							await Task.Delay(15000, linked.Token);
						}
					}
					catch
					{
						linked.Cancel();
					}
				}, linked.Token);
				try
				{
					while (!linked.IsCancellationRequested)
					{
						string valueOrDefault = (await Wire.ReadJson<Dictionary<string, string>>(control, linked.Token)).GetValueOrDefault("id");
						if (!Guid.TryParseExact(valueOrDefault, "N", out var _) || jobs.Count >= 24)
						{
							throw new IOException("Invalid relay request");
						}
						int jobId = Interlocked.Increment(ref sequence);
						jobs[jobId] = Handle(endpoint, key, valueOrDefault, linked.Token);
						jobs[jobId].ContinueWith((Task completed) =>
						{
							jobs.TryRemove(jobId, out Task _);
						}, TaskScheduler.Default);
					}
				}
				finally
				{
					linked.Cancel();
					control.Abort();
					try
					{
						await ping;
					}
					catch
					{
					}
					try
					{
						await Task.WhenAll(jobs.Values);
					}
					catch
					{
					}
				}
			}
			finally
			{
				if (control != null)
				{
					((IDisposable)control).Dispose();
				}
			}
		}
		finally
		{
			if (linked != null)
			{
				((IDisposable)linked).Dispose();
			}
		}
	}

	private async Task Handle(Uri endpoint, string key, string id, CancellationToken ct)
	{
		using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
		timeout.CancelAfter(TimeSpan.FromMinutes(45L));
		ct = timeout.Token;
		using ClientWebSocket ws = new ClientWebSocket();
		ws.Options.SetRequestHeader("Authorization", "Bearer " + key);
		string temporary = null;
		bool held = false;
		try
		{
			int num = 0;
			try
			{
				await ws.ConnectAsync(SocketUri(endpoint, "/_bridge/data/" + id), ct);
				RequestHead head = await Wire.ReadJson<RequestHead>(ws, ct);
				if (!Wire.Allowed(head.Method, head.Path) || head.Length < 0 || head.Length > 4294967296L || (!Wire.LargeBody(head.Path) && head.Length > 16384))
				{
					await Reject(ws, 400, ct);
					return;
				}
				if (head.Path.StartsWith("/api/") && head.Path.Split('?')[0] != "/api/pair")
				{
					using HttpRequestMessage probe = new HttpRequestMessage(HttpMethod.Get, new Uri(local, "/api/state?receiving=false"));
					probe.Headers.TryAddWithoutValidation("Cookie", head.Cookie);
					probe.Headers.TryAddWithoutValidation("X-Ahna-Remote", "1");
					using HttpResponseMessage auth = await http.SendAsync(probe, ct);
					if (!auth.IsSuccessStatusCode)
					{
						await Reject(ws, (int)auth.StatusCode, ct);
						return;
					}
					using JsonDocument state = JsonDocument.Parse(await auth.Content.ReadAsStringAsync(ct));
					if (state.RootElement.GetProperty("owner").GetBoolean())
					{
						await Reject(ws, 403, ct);
						return;
					}
				}
				if (!(head.Method == "POST"))
				{
					await Wire.SendJson(ws, new ResponseHead(100), ct);
				}
				else
				{
					held = await uploads.WaitAsync(0, ct);
					if (!held)
					{
						await Reject(ws, 429, ct);
						return;
					}
					NoLinks(cache);
					Directory.CreateDirectory(cache);
					NoLinks(cache);
					temporary = Path.Combine(cache, Guid.NewGuid().ToString("N") + ".part");
					await Wire.SendJson(ws, new ResponseHead(100), ct);
					await using FileStream file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, useAsync: true);
					await Wire.ReceiveBody(ws, file, head.Length, ct);
				}
				using HttpRequestMessage request = new HttpRequestMessage(new HttpMethod(head.Method), new Uri(local, head.Path));
				request.Headers.TryAddWithoutValidation("Cookie", head.Cookie);
				request.Headers.TryAddWithoutValidation("X-Ahna-Remote", "1");
				if (temporary != null)
				{
					request.Content = new StreamContent(new FileStream(temporary, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, useAsync: true));
					request.Content.Headers.ContentLength = head.Length;
					request.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(head.ContentType ?? "application/octet-stream");
				}
				using HttpResponseMessage response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
				if (held)
				{
					request.Content?.Dispose();
					if (temporary != null)
					{
						File.Delete(temporary);
						temporary = null;
					}
					uploads.Release();
					held = false;
				}
				Dictionary<string, string[]> headers = response.Headers.Concat(response.Content.Headers).ToDictionary((KeyValuePair<string, IEnumerable<string>> h) => h.Key, (KeyValuePair<string, IEnumerable<string>> h) => h.Value.ToArray(), StringComparer.OrdinalIgnoreCase);
				long? contentLength = response.Content.Headers.ContentLength;
				long length = default;
				int num2;
				if (contentLength.HasValue)
				{
					length = contentLength.GetValueOrDefault();
					num2 = 1;
				}
				else
				{
					num2 = 0;
				}
				bool flag = num2 == 0;
				if (!flag)
				{
					string path = head.Path;
					bool flag2 = ((path == "/" || path == "/index.html") ? true : false);
					flag = flag2;
				}
				if (flag)
				{
					await using Stream input = await response.Content.ReadAsStreamAsync(ct);
					using MemoryStream memory = new MemoryStream();
					byte[] buffer = new byte[65536];
					int num3;
					while ((num3 = await input.ReadAsync(buffer, ct)) > 0)
					{
						if (memory.Length + num3 > 2097152)
						{
							throw new IOException("Unbounded response");
						}
						memory.Write(buffer, 0, num3);
					}
					byte[] bytes = memory.ToArray();
					string path = head.Path;
					if ((path == "/" || path == "/index.html") ? true : false)
					{
						bytes = Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(bytes).Replace("같은 네트워크에서", "서버로 원격 연결").Replace("클라우드 없이, 내 네트워크 안에서 전송하세요.", "집 서버를 통해 다른 네트워크에서도 전송하세요.")
							.Replace("HTTP 로컬 전송 · 신뢰하는 개인 Wi-Fi에서 사용하세요.", "HTTPS 서버 중계 · Windows 앱이 켜져 있어야 합니다."));
					}
					await Wire.SendJson(ws, new ResponseHead((int)response.StatusCode, bytes.LongLength, headers), ct);
					await Wire.SendBody(ws, new MemoryStream(bytes), bytes.LongLength, ct);
				}
				else
				{
					await Wire.SendJson(ws, new ResponseHead((int)response.StatusCode, length, headers), ct);
					await using Stream input = await response.Content.ReadAsStreamAsync(ct);
					await Wire.SendBody(ws, input, length, ct);
				}
				await Receipt(ws, ct);
				await ws.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "done", ct);
			}
			catch (OperationCanceledException)
			{
			}
			catch
			{
				num = 1;
			}
			if (num == 1 && ws.State == WebSocketState.Open)
			{
				try
				{
					await Reject(ws, 502, ct);
					await ws.CloseOutputAsync(WebSocketCloseStatus.InternalServerError, "failed", ct);
					return;
				}
				catch
				{
					return;
				}
			}
		}
		finally
		{
			if (temporary != null)
			{
				try
				{
					File.Delete(temporary);
				}
				catch
				{
				}
			}
			if (held)
			{
				uploads.Release();
			}
		}
	}

	private static async Task Reject(WebSocket ws, int status, CancellationToken ct)
	{
		await Wire.SendJson(ws, new ResponseHead(status, 0L), ct);
		await Receipt(ws, ct);
	}

	private static async Task Receipt(WebSocket ws, CancellationToken ct)
	{
		if (!(await Wire.ReadJson<Dictionary<string, bool>>(ws, ct)).GetValueOrDefault("received"))
		{
			throw new IOException("Relay did not acknowledge response");
		}
	}

	private static void NoLinks(string path)
	{
		string text = Path.GetFullPath(path);
		while (!string.IsNullOrEmpty(text))
		{
			if ((Directory.Exists(text) || File.Exists(text)) && File.GetAttributes(text).HasFlag(FileAttributes.ReparsePoint))
			{
				throw new IOException("Linked cache path");
			}
			text = Path.GetDirectoryName(text);
		}
	}

	public async ValueTask DisposeAsync()
	{
		if (Interlocked.Exchange(ref disposed, 1) == 0)
		{
			stop.Cancel();
			Reload();
			try
			{
				await supervisor;
			}
			catch
			{
			}
			http.Dispose();
			uploads.Dispose();
			stop.Dispose();
		}
	}
}
