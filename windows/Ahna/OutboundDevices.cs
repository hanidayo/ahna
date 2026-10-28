using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Ahna;

// 이 PC가 다른 기기(서버 주소 + 상대 기기의 6자리 코드)에 연결해 주고받는 부분입니다.
// 예전 DirectConnectionForm의 화면 없는 동작을 그대로 옮겼고, 앱이 켜져 있는 동안 늘 백그라운드에서 받습니다.
// 연결 정보는 예전과 같은 파일(outbound-profiles.bin, outbound-received.json)에 저장되어 기존 연결이 그대로 유지됩니다.
internal sealed class OutboundDevices : TransferServer.IExternalDevices, IDisposable
{
	private sealed record Profile(string Address, string ComputerId, string Token, string Name);

	private sealed class Live
	{
		public DateTimeOffset LastOk = DateTimeOffset.MinValue;

		public string? Error;
	}

	/// <summary>상대 기기가 이 PC의 연결을 해제했을 때(401). 상태 확인에서 따로 처리합니다.</summary>
	private sealed class RevokedException : ArgumentException
	{
		public RevokedException()
			: base(RevokedMessage)
		{
		}
	}

	internal const string RevokedMessage = "상대 기기에서 연결을 해제했습니다 · 다시 추가하세요";

	private sealed record Progress(string DeviceId, string DeviceName, int Index, int Count, string FileName, long Sent, long Total);

	private sealed class ProgressContent : HttpContent
	{
		private readonly string path;

		private readonly long size;

		private readonly Action<long> report;

		private readonly CancellationToken token;

		public ProgressContent(string path, long size, Action<long> report, CancellationToken token)
		{
			this.path = path;
			this.size = size;
			this.report = report;
			this.token = token;
		}

		protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context)
		{
			await using FileStream input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, useAsync: true);
			byte[] buffer = new byte[65536];
			long sent = 0L;
			int read;
			while ((read = await input.ReadAsync(buffer, token)) > 0)
			{
				sent += read;
				if (sent > size)
				{
					throw new IOException("보내는 중에 파일이 바뀌었습니다.");
				}
				await stream.WriteAsync(buffer.AsMemory(0, read), token);
				report(sent);
			}
			if (sent != size)
			{
				throw new IOException("보내는 중에 파일이 바뀌었습니다.");
			}
		}

		protected override bool TryComputeLength(out long length)
		{
			length = size;
			return true;
		}
	}

	private const long MaxFile = 4294967296L;

	private const int MaxClipboardBytes = 65536;

	private readonly TransferServer server;

	private readonly string configPath;

	private readonly string receivedPath;

	private readonly HttpClient http = new HttpClient(new SocketsHttpHandler
	{
		UseCookies = false,
		AllowAutoRedirect = false
	})
	{
		Timeout = TimeSpan.FromMinutes(45L)
	};

	private readonly CancellationTokenSource stop = new CancellationTokenSource();

	private readonly object gate = new object();

	private readonly List<Profile> profiles = new List<Profile>();

	private readonly HashSet<string> received;

	private readonly HashSet<string> acknowledged = new HashSet<string>();

	private readonly Dictionary<string, Live> live = new Dictionary<string, Live>();

	private readonly SemaphoreSlim pollGate = new SemaphoreSlim(1, 1);

	private Task? loop;

	private volatile Progress? progress;

	private CancellationTokenSource? sendCancel;

	private int sending;

	private int resultId;

	private string? resultText;

	private bool resultError;

	private int disposed;

	public string? LoadError { get; private set; }

	/// <summary>파일 선택 창(트레이의 UI 스레드에서 실행). 취소하면 null.</summary>
	public Func<Task<string[]?>>? PickFiles { get; set; }

	/// <summary>보내기가 끝났을 때 알림 문구.</summary>
	public Action<string>? Finished { get; set; }

	public OutboundDevices(TransferServer server, string directory)
	{
		this.server = server;
		Directory.CreateDirectory(directory);
		configPath = Path.Combine(directory, "outbound-profiles.bin");
		receivedPath = Path.Combine(directory, "outbound-received.json");
		try
		{
			received = File.Exists(receivedPath) ? (JsonSerializer.Deserialize<HashSet<string>>(File.ReadAllText(receivedPath), Util.Json) ?? new HashSet<string>()) : new HashSet<string>();
		}
		catch
		{
			received = new HashSet<string>();
		}
		if (File.Exists(configPath))
		{
			try
			{
				profiles.AddRange(JsonSerializer.Deserialize<Profile[]>(RemoteKey.Unprotect(File.ReadAllText(configPath)), Util.Json) ?? Array.Empty<Profile>());
			}
			catch
			{
				LoadError = "저장한 기기 연결을 읽지 못했습니다. 기기를 다시 추가하세요.";
			}
		}
		// 상대 기기가 이 PC의 연결 코드로 연결하면서 자기 쪽 연결도 넘겨주면, 이 PC에서도 그 기기를 추가한 것과 같게 됩니다.
		server.ReverseReceived = AcceptReverse;
	}

	/// <summary>
	/// 상대 기기가 이 PC와 연결하면서 넘겨준 그 기기 쪽 연결(주소, 수신 ID, 인증 토큰, 이름)을 추가한 기기로 저장합니다.
	/// 보통 연결 코드로 추가했을 때와 같은 모양이며, 같은 기기(수신 ID)가 이미 있으면 새 연결로 바꿉니다.
	/// </summary>
	private bool AcceptReverse(TransferServer.ReverseCredential credential)
	{
		if (Volatile.Read(ref disposed) != 0)
		{
			return false;
		}
		Profile p = new Profile(credential.Address, credential.ComputerId, credential.Token, credential.Name);
		lock (gate)
		{
			profiles.RemoveAll((Profile x) => string.Equals(x.ComputerId, credential.ComputerId, StringComparison.OrdinalIgnoreCase));
			profiles.Add(p);
			live.Remove(Id(p));
		}
		Save();
		return true;
	}

	public void Start()
	{
		loop ??= Task.Run(() => RunAsync(stop.Token));
	}

	internal static Uri Endpoint(string value, string path)
	{
		if (!Uri.TryCreate(value.Trim(), UriKind.Absolute, out Uri? result) || result.UserInfo.Length != 0 || result.Query.Length != 0 || result.Fragment.Length != 0 || result.AbsolutePath != "/")
		{
			throw new ArgumentException("상대 주소만 입력하세요. 예: https://이름.synology.me");
		}
		if (result.Scheme != "https")
		{
			throw new ArgumentException("서버 HTTPS 주소가 필요합니다.");
		}
		return new Uri(result, path);
	}

	private static string Id(Profile p)
	{
		if (Guid.TryParseExact(p.ComputerId, "N", out Guid computer))
		{
			return "out-" + computer.ToString("N");
		}
		return "out-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(p.ComputerId + "|" + p.Address))).Substring(0, 32).ToLowerInvariant();
	}

	private Profile[] Profiles()
	{
		lock (gate)
		{
			return profiles.ToArray();
		}
	}

	private Profile Find(string id)
	{
		return Profiles().FirstOrDefault((Profile p) => Id(p) == id) ?? throw new ArgumentException("연결된 기기를 찾을 수 없습니다. 옵션에서 다시 추가하세요.");
	}

	public bool Owns(string? id)
	{
		return id != null && id.StartsWith("out-", StringComparison.Ordinal) && Profiles().Any((Profile p) => Id(p) == id);
	}

	/// <summary>
	/// 보내기 창(탐색기 우클릭 등)의 받을 기기 목록. 이 PC가 추가한 기기와 이 PC에 연결한 기기(inbound)를
	/// 기기마다 한 줄로 합칩니다. 둘 다 있으면 추가한 연결로 보내고, 그쪽이 오프라인이고 상대가 이 PC에서
	/// 받는 중이면 이 PC의 전송 대기열로 보냅니다. 추가하지 않은 기기는 지금 받을 수 있을 때만 보입니다.
	/// </summary>
	public (string Id, string Name)[] Targets(TransferServer.PeerInfo[] inbound)
	{
		DateTimeOffset now = DateTimeOffset.UtcNow;
		HashSet<string> claimed = new HashSet<string>();
		List<(string Id, string Name)> result = new List<(string Id, string Name)>();
		foreach (Profile p in Profiles())
		{
			string id = Id(p);
			TransferServer.PeerInfo[] same = inbound.Where((TransferServer.PeerInfo x) => SameDevice(x, p.ComputerId, p.Name)).ToArray();
			foreach (TransferServer.PeerInfo x in same)
			{
				claimed.Add(x.Id);
			}
			bool online = IsOnline(id, now);
			TransferServer.PeerInfo? receiving = same.FirstOrDefault((TransferServer.PeerInfo x) => x.Online);
			if (!online && receiving != null)
			{
				result.Add((receiving.Id, p.Name));
			}
			else
			{
				result.Add((id, p.Name + (online ? "" : " (오프라인)")));
			}
		}
		foreach (IGrouping<string, TransferServer.PeerInfo> group in inbound.Where((TransferServer.PeerInfo x) => x.Online && !claimed.Contains(x.Id)).GroupBy((TransferServer.PeerInfo x) => (x.ComputerId.Length > 0) ? ("c:" + x.ComputerId) : ("n:" + x.Name.Trim())))
		{
			TransferServer.PeerInfo first = group.First();
			result.Add((first.Id, first.Name));
		}
		return result.ToArray();
	}

	/// <summary>
	/// 같은 기기인지: 상대가 자기 수신 ID를 알려 줬으면 그 ID로, 예전(1.0.x) 앱이라 ID가 없으면 이름(앞뒤 공백 제외)으로 비교합니다.
	/// </summary>
	internal static bool SameDevice(TransferServer.PeerInfo peer, string computerId, string name)
	{
		if (peer.ComputerId.Length > 0)
		{
			return computerId.Length > 0 && string.Equals(peer.ComputerId, computerId, StringComparison.OrdinalIgnoreCase);
		}
		return peer.Name.Trim() == name.Trim();
	}

	private bool IsOnline(string id, DateTimeOffset now)
	{
		lock (gate)
		{
			return live.TryGetValue(id, out Live? l) && l.Error == null && now - l.LastOk < TimeSpan.FromSeconds(20L);
		}
	}

	private void SetLive(Profile p, string? error)
	{
		lock (gate)
		{
			string id = Id(p);
			if (!live.TryGetValue(id, out Live? l))
			{
				l = new Live();
				live[id] = l;
			}
			l.Error = error;
			if (error == null)
			{
				l.LastOk = DateTimeOffset.UtcNow;
			}
		}
	}

	public object Snapshot()
	{
		DateTimeOffset now = DateTimeOffset.UtcNow;
		var devices = Profiles().Select((Profile p) =>
		{
			string id = Id(p);
			string? error;
			lock (gate)
			{
				error = live.TryGetValue(id, out Live? l) ? l.Error : null;
			}
			return new
			{
				id = id,
				name = p.Name,
				computerID = p.ComputerId,
				address = p.Address,
				online = IsOnline(id, now),
				error = error
			};
		}).ToArray();
		Progress? current = progress;
		int currentResultId;
		string? currentResult;
		bool currentError;
		lock (gate)
		{
			currentResultId = resultId;
			currentResult = resultText;
			currentError = resultError;
		}
		return new
		{
			devices = devices,
			loadError = LoadError,
			sending = (current == null) ? null : new
			{
				deviceId = current.DeviceId,
				deviceName = current.DeviceName,
				index = current.Index,
				count = current.Count,
				name = current.FileName,
				sent = current.Sent,
				total = current.Total
			},
			result = (currentResult == null) ? null : new
			{
				id = currentResultId,
				text = currentResult,
				error = currentError
			}
		};
	}

	private void Save()
	{
		lock (gate)
		{
			string temporary = configPath + ".tmp";
			File.WriteAllText(temporary, RemoteKey.Protect(JsonSerializer.Serialize(profiles, Util.Json)));
			File.Move(temporary, configPath, overwrite: true);
		}
	}

	private void MarkReceived(string key)
	{
		lock (gate)
		{
			received.Add(key);
			Util.SaveJson(receivedPath, received);
		}
	}

	private bool WasReceived(string key)
	{
		lock (gate)
		{
			return received.Contains(key);
		}
	}

	private static string Friendly(Exception ex)
	{
		if (ex is ArgumentException || ex is IOException || ex is InvalidDataException)
		{
			return ex.Message;
		}
		return "상대 기기에 연결하지 못했습니다. 서버 주소와 상대 기기의 아나를 확인하세요.";
	}

	private async Task<HttpResponseMessage> Request(Profile p, HttpMethod method, string path, HttpContent? content = null, CancellationToken? token = null)
	{
		using HttpRequestMessage request = new HttpRequestMessage(method, Endpoint(p.Address, path))
		{
			Content = content
		};
		if (p.Token.Length > 0)
		{
			request.Headers.Add("Cookie", "ahna=" + p.Token);
		}
		if (p.ComputerId.Length > 0)
		{
			request.Headers.Add("X-Ahna-Computer", p.ComputerId);
		}
		CancellationToken cancel = token ?? stop.Token;
		HttpResponseMessage response;
		try
		{
			response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancel);
		}
		catch (HttpRequestException)
		{
			throw new IOException("상대 기기에 연결하지 못했습니다. 서버 주소와 인터넷 연결을 확인하세요.");
		}
		catch (TaskCanceledException) when (!cancel.IsCancellationRequested)
		{
			throw new IOException("상대 기기의 응답이 없습니다. 잠시 후 다시 시도하세요.");
		}
		if (!response.IsSuccessStatusCode)
		{
			HttpStatusCode statusCode = response.StatusCode;
			response.Dispose();
			if (statusCode == HttpStatusCode.Unauthorized && p.Token.Length > 0)
			{
				throw new RevokedException();
			}
			if (statusCode == HttpStatusCode.Unauthorized)
			{
				throw new ArgumentException("연결 코드가 맞지 않습니다. 상대 기기의 연결 코드를 확인하세요.");
			}
			throw new ArgumentException(statusCode switch
			{
				HttpStatusCode.TooManyRequests => "상대 기기가 다른 전송을 처리하는 중입니다. 잠시 후 다시 시도하세요.",
				_ => $"요청 실패 ({(int)statusCode}) · 상대 기기의 아나와 서버 연결을 확인하세요."
			});
		}
		return response;
	}

	// 상태 확인 때 이 PC의 수신 ID도 알려 줍니다. 예전에 연결한 상대도 다시 연결하지 않고 같은 기기로 알아봅니다.
	private string StatePath()
	{
		return "/api/state?receiving=true&computerID=" + Uri.EscapeDataString(server.ComputerId);
	}

	private async Task<JsonDocument> Json(HttpResponseMessage response)
	{
		await using Stream input = await response.Content.ReadAsStreamAsync(stop.Token);
		using MemoryStream output = new MemoryStream();
		byte[] buffer = new byte[8192];
		int read;
		while ((read = await input.ReadAsync(buffer, stop.Token)) > 0)
		{
			if (output.Length + read > 2097152)
			{
				throw new InvalidDataException("응답이 너무 큽니다.");
			}
			output.Write(buffer, 0, read);
		}
		return JsonDocument.Parse(output.ToArray());
	}

	public async Task<object> PairAsync(string address, string pin)
	{
		address = address.Trim().TrimEnd('/');
		if (address.Length == 0)
		{
			address = server.Settings.RemoteUrl.Trim().TrimEnd('/');
		}
		if (address.Length == 0)
		{
			throw new ArgumentException("서버 주소를 입력하세요. 옵션에 서버 주소를 저장해 두면 자동으로 채워집니다.");
		}
		pin = pin.Trim();
		if (pin.Length != 6 || !pin.All(char.IsAsciiDigit))
		{
			throw new ArgumentException("상대 기기의 6자리 연결 코드를 입력하세요.");
		}
		Endpoint(address, "/");
		Profile p = new Profile(address, "", "", address);
		string token;
		string computerId = "";
		// 한 번의 코드 입력으로 양쪽 모두 연결: 이 PC의 수신 쪽에 상대 기기용 연결을 미리 만들어 함께 보냅니다.
		// 상대 앱이 받아 저장했다고 답하면 유지하고, 예전(1.0.x) 앱이거나 실패하면 지웁니다.
		TransferServer.ReverseCredential? offer = server.ReverseOffer();
		bool reverseAccepted = false;
		bool paired = false;
		try
		{
			using (HttpResponseMessage response = await Request(p, HttpMethod.Post, "/api/pair", new StringContent(JsonSerializer.Serialize(new
			{
				pin = pin,
				name = Environment.MachineName,
				native = true,
				canReceive = true,
				// 이 PC의 수신 ID: 상대가 이 PC를 기기 목록에 한 번만 보여 줄 수 있게 합니다(예전 앱은 무시).
				computerID = server.ComputerId,
				reverse = (offer == null) ? null : new
				{
					address = offer.Address,
					computerID = offer.ComputerId,
					token = offer.Token,
					name = offer.Name
				}
			}), Encoding.UTF8, "application/json")))
			{
				string? cookie = response.Headers.TryGetValues("Set-Cookie", out IEnumerable<string>? values) ? values.Select((string v) => v.Split(';')[0]).FirstOrDefault((string v) => v.StartsWith("ahna=", StringComparison.Ordinal))?.Substring(5) : null;
				if (cookie == null || cookie.Length < 32 || cookie.Length > 256 || !cookie.All((char c) => char.IsAsciiLetterOrDigit(c) || c == '-' || c == '_'))
				{
					throw new InvalidDataException("상대 기기의 인증 응답을 읽지 못했습니다.");
				}
				token = cookie;
				string header = response.Headers.TryGetValues("X-Ahna-Computer", out IEnumerable<string>? ids) ? (ids.FirstOrDefault() ?? "") : "";
				computerId = Guid.TryParseExact(header, "N", out _) ? header : "";
				if (offer != null)
				{
					try
					{
						using JsonDocument answer = await Json(response);
						reverseAccepted = answer.RootElement.ValueKind == JsonValueKind.Object && answer.RootElement.TryGetProperty("reverse", out JsonElement accepted) && accepted.ValueKind == JsonValueKind.True;
					}
					catch (Exception ex) when (ex is JsonException || ex is InvalidDataException || ex is IOException || ex is HttpRequestException)
					{
						reverseAccepted = false;
					}
				}
			}
			p = p with
			{
				Token = token,
				ComputerId = computerId
			};
			using (HttpResponseMessage stateResponse = await Request(p, HttpMethod.Get, StatePath()))
			{
				using JsonDocument document = await Json(stateResponse);
				string? host = document.RootElement.TryGetProperty("hostName", out JsonElement value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
				p = p with
				{
					Name = string.IsNullOrWhiteSpace(host) ? "기기" : new string(host.Where((char c) => !char.IsControl(c)).Take(40).ToArray())
				};
			}
			lock (gate)
			{
				profiles.RemoveAll((Profile x) => (computerId.Length > 0) ? (x.ComputerId == computerId) : (x.Address == p.Address && x.ComputerId.Length == 0));
				profiles.Add(p);
			}
			Save();
			SetLive(p, null);
			paired = true;
		}
		finally
		{
			if (offer != null)
			{
				server.CompleteReverse(offer.Token, paired && reverseAccepted, p.Name, computerId);
			}
		}
		return new
		{
			id = Id(p),
			name = p.Name
		};
	}

	public async Task RemoveAsync(string id)
	{
		Profile p = Find(id);
		try
		{
			using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
			timeout.CancelAfter(TimeSpan.FromSeconds(10L));
			using (await Request(p, HttpMethod.Post, "/api/logout", new ByteArrayContent(Array.Empty<byte>()), timeout.Token))
			{
			}
		}
		catch
		{
			// 상대 기기가 꺼져 있어도 이 PC의 연결은 지웁니다.
		}
		lock (gate)
		{
			profiles.RemoveAll((Profile x) => Id(x) == id);
			live.Remove(id);
		}
		Save();
	}

	public async Task SendTextAsync(string id, string text)
	{
		Profile p = Find(id);
		if (text.Length == 0 || text.Contains('\0') || Encoding.UTF8.GetByteCount(text) > MaxClipboardBytes)
		{
			throw new ArgumentException("보낼 글자는 최대 64 KB입니다.");
		}
		using (await Request(p, HttpMethod.Post, "/api/upload?kind=clipboard&batch=" + Guid.NewGuid(), new StringContent(text, Encoding.UTF8, "text/plain")))
		{
		}
		server.RecordExternal("send", "클립보드 텍스트", Encoding.UTF8.GetByteCount(text), Id(p), p.Name, "텍스트 전송 완료");
	}

	public async Task<int> PickAndSendFilesAsync(string id)
	{
		Find(id);
		if (Volatile.Read(ref sending) != 0)
		{
			throw new ArgumentException("다른 파일을 보내는 중입니다. 끝난 뒤 다시 시도하세요.");
		}
		Func<Task<string[]?>> picker = PickFiles ?? throw new InvalidOperationException("이 컴퓨터에서는 파일 선택 창을 열 수 없습니다.");
		string[]? paths = await picker();
		if (paths == null || paths.Length == 0)
		{
			return 0;
		}
		StartSend(id, paths);
		return paths.Length;
	}

	/// <summary>파일 보내기를 시작합니다(백그라운드). 진행 상황은 Snapshot().sending으로 보입니다.</summary>
	public void StartSend(string id, string[] paths)
	{
		Profile p = Find(id);
		string[] files = paths.Select((string path) => Path.GetFullPath(path)).ToArray();
		foreach (string file in files)
		{
			Util.NoLinks(file);
			if (Directory.Exists(file))
			{
				throw new ArgumentException("이 기기에는 파일만 보낼 수 있습니다. 폴더는 ZIP으로 압축해 보내세요.");
			}
			if (!File.Exists(file))
			{
				throw new ArgumentException("파일을 찾을 수 없습니다.");
			}
			if (new FileInfo(file).Length > MaxFile)
			{
				throw new ArgumentException("파일 한 개는 최대 4 GiB입니다.");
			}
		}
		if (Interlocked.Exchange(ref sending, 1) != 0)
		{
			throw new ArgumentException("다른 파일을 보내는 중입니다. 끝난 뒤 다시 시도하세요.");
		}
		CancellationTokenSource cancel = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
		sendCancel = cancel;
		progress = new Progress(Id(p), p.Name, 1, files.Length, Path.GetFileName(files[0]), 0L, 0L);
		_ = Task.Run(() => SendFilesAsync(p, files, cancel));
	}

	public void CancelSend()
	{
		try
		{
			sendCancel?.Cancel();
		}
		catch (ObjectDisposedException)
		{
		}
	}

	private async Task SendFilesAsync(Profile p, string[] files, CancellationTokenSource cancel)
	{
		string deviceId = Id(p);
		int done = 0;
		string text;
		bool failed = false;
		try
		{
			string batch = Guid.NewGuid().ToString();
			for (int i = 0; i < files.Length; i++)
			{
				string file = files[i];
				string name = Path.GetFileName(file).Normalize(NormalizationForm.FormC);
				long size = new FileInfo(file).Length;
				int index = i + 1;
				progress = new Progress(deviceId, p.Name, index, files.Length, name, 0L, size);
				ProgressContent content = new ProgressContent(file, size, (long sent) =>
				{
					progress = new Progress(deviceId, p.Name, index, files.Length, name, sent, size);
				}, cancel.Token);
				content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
				using (await Request(p, HttpMethod.Post, "/api/upload?batch=" + batch + "&path=" + Uri.EscapeDataString(name), content, cancel.Token))
				{
				}
				server.RecordExternal("send", name, size, deviceId, p.Name, "상대 저장 완료");
				done++;
			}
			text = $"{p.Name}에 {done}개 파일을 보냈습니다.";
		}
		catch (OperationCanceledException)
		{
			failed = true;
			text = $"전송을 중단했습니다. ({done}/{files.Length}개 완료)";
		}
		catch (Exception ex)
		{
			failed = true;
			text = $"{Friendly(ex)} ({done}/{files.Length}개 완료)";
			try
			{
				server.RecordExternal("send", Path.GetFileName(files[done]), new FileInfo(files[done]).Length, deviceId, p.Name, "실패");
			}
			catch
			{
			}
		}
		finally
		{
			progress = null;
			sendCancel = null;
			cancel.Dispose();
			Volatile.Write(ref sending, 0);
		}
		lock (gate)
		{
			resultId++;
			resultText = text;
			resultError = failed;
		}
		try
		{
			Finished?.Invoke(text);
		}
		catch
		{
		}
	}

	private async Task RunAsync(CancellationToken token)
	{
		using PeriodicTimer timer = new PeriodicTimer(TimeSpan.FromSeconds(3L));
		try
		{
			do
			{
				await PollAllAsync();
			}
			while (await timer.WaitForNextTickAsync(token));
		}
		catch (OperationCanceledException)
		{
		}
	}

	private async Task PollAllAsync()
	{
		if (!await pollGate.WaitAsync(0))
		{
			return;
		}
		try
		{
			foreach (Profile p in Profiles())
			{
				if (stop.IsCancellationRequested)
				{
					break;
				}
				try
				{
					await PollAsync(p);
					SetLive(p, null);
				}
				catch (OperationCanceledException) when (stop.IsCancellationRequested)
				{
					break;
				}
				catch (RevokedException)
				{
					Revoked(p);
				}
				catch (Exception ex)
				{
					SetLive(p, Friendly(ex));
				}
			}
		}
		finally
		{
			pollGate.Release();
		}
	}

	/// <summary>
	/// 상대 기기가 이 PC의 연결을 해제한 경우(401). 그 기기가 이 PC에 연결한 쪽(inbound)이 남아 있으면 죽은 연결만 조용히 지우고
	/// 그쪽으로 주고받습니다. 없으면 오프라인으로 두고 “다시 추가하세요” 한 줄만 보여 줍니다.
	/// </summary>
	private void Revoked(Profile p)
	{
		string id = Id(p);
		if (server.Peers().Any((TransferServer.PeerInfo x) => SameDevice(x, p.ComputerId, p.Name)))
		{
			lock (gate)
			{
				profiles.RemoveAll((Profile x) => Id(x) == id && x.Token == p.Token);
				live.Remove(id);
			}
			Save();
		}
		else
		{
			SetLive(p, RevokedMessage);
		}
	}

	private async Task PollAsync(Profile p)
	{
		string deviceId = Id(p);
		using HttpResponseMessage response = await Request(p, HttpMethod.Get, StatePath());
		using JsonDocument state = await Json(response);
		SetLive(p, null);
		JsonElement root = state.RootElement;
		string session = root.TryGetProperty("id", out JsonElement sessionValue) ? (sessionValue.GetString() ?? "") : "";
		if (root.TryGetProperty("items", out JsonElement items) && items.ValueKind == JsonValueKind.Array)
		{
			foreach (JsonElement item in items.EnumerateArray())
			{
				string id = item.GetProperty("id").GetString() ?? "";
				string name = item.GetProperty("name").GetString() ?? "";
				long bytes = item.GetProperty("bytes").GetInt64();
				if (!Guid.TryParseExact(id, "N", out _) || bytes < 0 || bytes > MaxFile || name.Contains('/') || name.Contains('\\'))
				{
					throw new InvalidDataException("올바르지 않은 파일 정보입니다.");
				}
				name = Util.SafeRelative(name);
				string key = p.ComputerId + "|" + p.Address + "|" + session + "|" + id;
				if (!WasReceived(key))
				{
					string saved = await DownloadAsync(p, id, name, bytes);
					MarkReceived(key);
					server.RecordExternal("receive", saved, bytes, deviceId, p.Name, "저장 완료", notify: true);
				}
				bool acknowledge;
				lock (gate)
				{
					acknowledge = acknowledged.Add(key);
				}
				if (acknowledge)
				{
					try
					{
						using (await Request(p, HttpMethod.Post, "/api/received/" + id, new StringContent("{\"destination\":\"files\"}", Encoding.UTF8, "application/json")))
						{
						}
					}
					catch
					{
						lock (gate)
						{
							acknowledged.Remove(key);
						}
						throw;
					}
				}
			}
		}
		if (root.TryGetProperty("clipboard", out JsonElement clipboard) && clipboard.ValueKind == JsonValueKind.Array)
		{
			foreach (JsonElement item in clipboard.EnumerateArray())
			{
				string id = item.GetProperty("id").GetString() ?? "";
				if (!Guid.TryParseExact(id, "N", out _))
				{
					continue;
				}
				string key = "clip|" + p.ComputerId + "|" + p.Address + "|" + session + "|" + id;
				if (WasReceived(key))
				{
					continue;
				}
				int expected = item.GetProperty("bytes").GetInt32();
				if (expected < 1 || expected > MaxClipboardBytes)
				{
					MarkReceived(key);
					continue;
				}
				using HttpResponseMessage download = await Request(p, HttpMethod.Get, "/api/download/" + id + "?kind=clipboard");
				await using Stream input = await download.Content.ReadAsStreamAsync(stop.Token);
				byte[] buffer = new byte[expected + 1];
				int count = await input.ReadAtLeastAsync(buffer, expected, throwOnEndOfStream: false, stop.Token);
				if (count != expected || await input.ReadAsync(new byte[1], stop.Token) != 0)
				{
					throw new InvalidDataException("받은 글자의 크기가 다릅니다.");
				}
				string text = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true).GetString(buffer, 0, count);
				MarkReceived(key);
				if (!text.Contains('\0'))
				{
					server.AddExternalClipboard(text, deviceId, p.Name);
				}
			}
		}
	}

	private async Task<string> DownloadAsync(Profile p, string id, string name, long bytes)
	{
		string folder = Path.GetFullPath(server.Settings.SavePath);
		Util.NoLinks(folder);
		Directory.CreateDirectory(folder);
		string temporary = Path.Combine(folder, ".ahna-" + Guid.NewGuid().ToString("N") + ".part");
		try
		{
			using (HttpResponseMessage download = await Request(p, HttpMethod.Get, "/api/download/" + id))
			{
				if (download.Content.Headers.ContentLength != bytes)
				{
					throw new IOException("파일 크기가 다릅니다.");
				}
				await using FileStream output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, useAsync: true);
				await using Stream input = await download.Content.ReadAsStreamAsync(stop.Token);
				byte[] buffer = new byte[65536];
				long total = 0L;
				int read;
				while ((read = await input.ReadAsync(buffer, stop.Token)) > 0)
				{
					total += read;
					if (total > bytes)
					{
						throw new IOException("파일 크기가 다릅니다.");
					}
					await output.WriteAsync(buffer.AsMemory(0, read), stop.Token);
				}
				if (total != bytes)
				{
					throw new IOException("파일 받기가 중단되었습니다.");
				}
			}
			string destination = Path.Combine(folder, name);
			for (int i = 1; ; i++)
			{
				try
				{
					Util.NoLinks(destination);
					File.Move(temporary, destination);
					break;
				}
				catch (IOException) when (File.Exists(destination))
				{
					destination = Path.Combine(folder, Path.GetFileNameWithoutExtension(name) + $" ({i})" + Path.GetExtension(name));
				}
			}
			return Path.GetFileName(destination);
		}
		finally
		{
			if (File.Exists(temporary))
			{
				try
				{
					File.Delete(temporary);
				}
				catch
				{
				}
			}
		}
	}

	public void Dispose()
	{
		if (Interlocked.Exchange(ref disposed, 1) != 0)
		{
			return;
		}
		stop.Cancel();
		try
		{
			loop?.Wait(TimeSpan.FromSeconds(2L));
		}
		catch
		{
		}
		http.Dispose();
	}
}
