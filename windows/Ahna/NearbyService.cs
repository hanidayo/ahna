using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Devices.Radios;
using Windows.Storage.Streams;

namespace Ahna;

/// <summary>근처 기기에서 온 보내기 제안 (상대가 inbox 특성에 쓴 offer).</summary>
internal sealed record NearbyOffer(string Name, string Platform, string Code, int Count, long Bytes, string Summary, string Url, string? Proximity);

/// <summary>
/// 1.2 근처 기기 (Bluetooth LE). 공통 규약: 서비스 A4A10001-…, card(읽기) A4A10002-…, inbox(응답 있는 쓰기, ≤512바이트) A4A10003-….
/// 보내는 쪽: 서비스 UUID로 찾아 card를 읽고(기기별 캐시), RSSI로 거리를 보여 줍니다. 고르면 kind=send 티켓을 만들어 inbox에 offer를 씁니다.
/// 받는 쪽: '10분 동안 모두'인 동안에만 광고하고 GATT 서비스(card, inbox)를 엽니다. offer가 오면 확인 창(TrayContext)을 띄웁니다.
/// 파일 자체는 Bluetooth가 아니라 서버 중계의 1회용 링크(/s/…)로 오갑니다.
/// </summary>
internal sealed class NearbyService : TransferServer.INearbyHost, IDisposable
{
	public static readonly Guid ServiceUuid = new Guid("A4A10001-4B2C-4F6D-9E3A-5C8B2D1F0A61");

	public static readonly Guid CardUuid = new Guid("A4A10002-4B2C-4F6D-9E3A-5C8B2D1F0A61");

	public static readonly Guid InboxUuid = new Guid("A4A10003-4B2C-4F6D-9E3A-5C8B2D1F0A61");

	public const int MaxOfferBytes = 512;

	public static readonly TimeSpan EveryoneDuration = TimeSpan.FromMinutes(10);

	public static readonly TimeSpan AnswerTimeout = TimeSpan.FromSeconds(30);

	private sealed class Seen
	{
		public double Rssi;

		public DateTimeOffset Last;

		// 목록에 보이는 중인지 · '아주 가까움'인지 (경계에서 깜빡이지 않도록 들어올 때와 나갈 때 기준이 다름)
		public bool Shown;

		public bool Near;
	}

	private sealed record Card(string Name, string Platform, DateTimeOffset Read);

	/// <summary>근처 기기로 보내는 중인 한 건 (웹 화면의 보내기 카드 상태).</summary>
	private sealed class Outgoing
	{
		public required string Id { get; init; }

		public required ulong Address { get; init; }

		public required string DeviceName { get; init; }

		public required string Platform { get; init; }

		public required string Code { get; init; }

		public readonly CancellationTokenSource Cancel = new CancellationTokenSource();

		public volatile string State = "connecting";

		public volatile string Message = "";

		public TransferServer.GuestTicket? Ticket;

		public int Count;

		public long Bytes;

		public string Summary = "";

		public DateTimeOffset Waiting = DateTimeOffset.MaxValue;

		public DateTimeOffset Ended = DateTimeOffset.MaxValue;

		public bool Finished => State is "done" or "declined" or "failed";
	}

	private readonly TransferServer server;

	private readonly string settingsPath;

	private readonly object gate = new object();

	private readonly CancellationTokenSource stop = new CancellationTokenSource();

	private readonly SemaphoreSlim gattGate = new SemaphoreSlim(1, 1);

	private readonly HttpClient http = new HttpClient(new SocketsHttpHandler
	{
		UseCookies = false,
		AllowAutoRedirect = false
	})
	{
		Timeout = TimeSpan.FromMinutes(45L)
	};

	private readonly Dictionary<ulong, Seen> seen = new Dictionary<ulong, Seen>();

	private readonly Dictionary<ulong, Card> cards = new Dictionary<ulong, Card>();

	private readonly Dictionary<ulong, DateTimeOffset> cardRetry = new Dictionary<ulong, DateTimeOffset>();

	private readonly Dictionary<string, byte[]> partialWrites = new Dictionary<string, byte[]>(StringComparer.Ordinal);

	private Task? loop;

	private BluetoothAdapter? adapter;

	private Radio? radio;

	// "checking" | "on" | "off" | "none" | "denied"
	private volatile string bluetooth = "checking";

	private volatile bool canReceive;

	private string mode = "registered";

	private DateTimeOffset everyoneUntil = DateTimeOffset.MinValue;

	private BluetoothLEAdvertisementWatcher? watcher;

	private DateTimeOffset lastInterest = DateTimeOffset.MinValue;

	private GattServiceProvider? provider;

	private bool advertising;

	private Outgoing? outgoing;

	private NearbyOffer? pendingOffer;

	private int receiving;

	private int disposed;

	/// <summary>보낼 파일 고르기 (트레이 UI 스레드의 파일 선택 창).</summary>
	public Func<Task<string[]?>>? PickFiles { get; set; }

	/// <summary>등록된 기기 이름 (근처 목록에서 같은 이름은 숨깁니다).</summary>
	public Func<IEnumerable<string>>? RegisteredNames { get; set; }

	/// <summary>근처 기기에서 보내기 제안이 왔을 때 (확인 창 · 트레이 알림). 백그라운드 스레드에서 불립니다.</summary>
	public Action<NearbyOffer>? OfferReceived { get; set; }

	/// <summary>트레이 알림 (제목, 내용).</summary>
	public Action<string, string>? Notify { get; set; }

	/// <summary>웹 화면의 [QR] 버튼.</summary>
	public Action? OpenQrRequested { get; set; }

	public NearbyService(TransferServer server, string data)
	{
		this.server = server;
		settingsPath = Path.Combine(data, "nearby.json");
		try
		{
			if (File.Exists(settingsPath))
			{
				using JsonDocument document = JsonDocument.Parse(File.ReadAllText(settingsPath));
				if (document.RootElement.TryGetProperty("mode", out JsonElement saved) && saved.GetString() is "off" or "registered")
				{
					mode = saved.GetString()!;
				}
			}
		}
		catch
		{
		}
	}

	public void Start()
	{
		loop ??= Task.Run(() => RunAsync());
	}

	public bool BluetoothOn => bluetooth == "on";

	public string BluetoothState => bluetooth;

	public bool CanReceive => canReceive;

	public string Mode
	{
		get
		{
			lock (gate)
			{
				return mode;
			}
		}
	}

	// ---- 웹 화면 (TransferServer.INearbyHost) --------------------------------------------------------

	/// <summary>보내기 창이 열려 있는 동안 근처 기기를 계속 찾습니다.</summary>
	public void KeepScanning()
	{
		lock (gate)
		{
			lastInterest = DateTimeOffset.UtcNow;
		}
	}

	public object Snapshot()
	{
		DateTimeOffset now = DateTimeOffset.UtcNow;
		lock (gate)
		{
			lastInterest = now;
		}
		Outgoing? send;
		string currentMode;
		DateTimeOffset until;
		lock (gate)
		{
			send = outgoing;
			currentMode = mode;
			until = everyoneUntil;
		}
		return new
		{
			available = true,
			bluetooth,
			canReceive,
			mode = currentMode,
			remaining = currentMode == "everyone" ? (int?)Math.Max(0, (int)Math.Ceiling((until - now).TotalSeconds)) : null,
			name = server.GuestOwnerName,
			nas = server.GuestOrigin != null,
			devices = Devices().Select(d => new { id = d.Id, name = d.Name, platform = d.Platform, proximity = d.Proximity, near = d.Near }).ToArray(),
			send = send == null ? null : SendSnapshot(send, now)
		};
	}

	private static object SendSnapshot(Outgoing send, DateTimeOffset now)
	{
		TransferServer.GuestTicket? ticket = send.Ticket;
		long total = ticket?.Total ?? send.Bytes;
		long sent = ticket?.Transferred ?? 0;
		return new
		{
			id = send.Id,
			device = send.DeviceName,
			platform = send.Platform,
			state = send.State,
			code = send.Code,
			count = send.Count,
			bytes = send.Bytes,
			summary = send.Summary,
			percent = total > 0 ? (int)Math.Min(100L, sent * 100 / total) : 0,
			remaining = send.State == "waiting" ? Math.Max(0, (int)Math.Ceiling((send.Waiting + AnswerTimeout - now).TotalSeconds)) : 0,
			message = send.Message
		};
	}

	public void SetMode(string value)
	{
		if (value is not ("off" or "registered" or "everyone"))
		{
			throw new ArgumentException("올바르지 않은 설정입니다.");
		}
		if (value == "everyone")
		{
			if (bluetooth != "on")
			{
				throw new InvalidOperationException(bluetooth == "off" ? "Bluetooth가 꺼져 있습니다. Windows 설정에서 Bluetooth를 켜 주세요." : "이 PC에서는 Bluetooth를 쓸 수 없습니다.");
			}
			if (!canReceive)
			{
				throw new InvalidOperationException("이 PC의 Bluetooth는 받기를 지원하지 않습니다. 근처 기기로 보내기만 할 수 있습니다.");
			}
		}
		lock (gate)
		{
			mode = value;
			everyoneUntil = value == "everyone" ? DateTimeOffset.UtcNow + EveryoneDuration : DateTimeOffset.MinValue;
		}
		if (value != "everyone")
		{
			SaveMode(value);
		}
		_ = Task.Run(() => UpdatePeripheralAsync());
	}

	private void SaveMode(string value)
	{
		try
		{
			Util.SaveJson(settingsPath, new { mode = value });
		}
		catch
		{
		}
	}

	public async Task<int> PickAndSendAsync(string id)
	{
		Find(id);
		if (server.GuestOrigin == null)
		{
			throw new InvalidOperationException(TransferServer.NasRequired);
		}
		ThrowIfSending();
		Func<Task<string[]?>>? pick = PickFiles;
		if (pick == null)
		{
			throw new InvalidOperationException("이 실행에서는 파일 선택 창을 열 수 없습니다.");
		}
		string[]? paths = await pick();
		if (paths == null || paths.Length == 0)
		{
			return 0;
		}
		StartSend(id, paths);
		return paths.Length;
	}

	public void CancelSend()
	{
		Outgoing? send;
		lock (gate)
		{
			send = outgoing;
			if (send != null && send.Finished)
			{
				// 끝난 결과(보냈습니다 / 받지 않았습니다)를 닫습니다.
				outgoing = null;
				return;
			}
		}
		if (send == null)
		{
			return;
		}
		try
		{
			send.Cancel.Cancel();
		}
		catch (ObjectDisposedException)
		{
		}
	}

	public void OpenQr()
	{
		OpenQrRequested?.Invoke();
	}

	// ---- 근처 기기 목록 -------------------------------------------------------------------------

	internal sealed record NearbyDevice(string Id, string Name, string Platform, string Proximity, bool Near);

	public NearbyDevice[] Devices()
	{
		DateTimeOffset now = DateTimeOffset.UtcNow;
		HashSet<string> registered;
		try
		{
			registered = new HashSet<string>((RegisteredNames?.Invoke() ?? Array.Empty<string>()).Select((string n) => UiTheme.DisplayName(n).Trim()), StringComparer.Ordinal);
		}
		catch
		{
			registered = new HashSet<string>(StringComparer.Ordinal);
		}
		List<NearbyDevice> list = new List<NearbyDevice>();
		// 같은 기기가 Bluetooth 주소를 바꾸며 광고하면 두 번 보일 수 있어, 이름·기기 종류가 같으면 가장 최근 것 하나만 둡니다.
		Dictionary<string, (NearbyDevice Device, DateTimeOffset Last)> byName = new Dictionary<string, (NearbyDevice, DateTimeOffset)>(StringComparer.Ordinal);
		lock (gate)
		{
			if (bluetooth != "on")
			{
				return Array.Empty<NearbyDevice>();
			}
			foreach (KeyValuePair<ulong, Seen> item in seen)
			{
				// Bluetooth 신호는 몇 dB씩 출렁입니다. 처음에는 -78 이상 · 최근 10초 안에 보여야 목록에 넣고,
				// 한 번 보인 기기는 -88 아래로 떨어지거나 25초 동안 신호가 없을 때만 뺍니다.
				Seen s = item.Value;
				TimeSpan age = now - s.Last;
				bool keep = s.Shown ? (age < TimeSpan.FromSeconds(8) && s.Rssi >= -88) : (age < TimeSpan.FromSeconds(10) && s.Rssi >= -78);
				s.Shown = keep;
				s.Near = keep && (s.Near ? s.Rssi >= -66 : s.Rssi >= -60);
				if (!keep || !cards.TryGetValue(item.Key, out Card? card))
				{
					continue;
				}
				if (registered.Contains(card.Name.Trim()))
				{
					continue;
				}
				bool near = s.Near;
				NearbyDevice device = new NearbyDevice(item.Key.ToString("x12", CultureInfo.InvariantCulture), card.Name, card.Platform, near ? "아주 가까움" : "가까움", near);
				string key = card.Name.Trim() + "|" + card.Platform;
				if (!byName.TryGetValue(key, out var existing) || existing.Last < s.Last)
				{
					byName[key] = (device, s.Last);
				}
			}
		}
		list.AddRange(byName.Values.Select(x => x.Device));
		return list.OrderByDescending((NearbyDevice d) => d.Near).ThenBy((NearbyDevice d) => d.Name, StringComparer.CurrentCulture).ToArray();
	}

	/// <summary>id(주소 12자리 16진수)가 지금 근처 목록에 있는지.</summary>
	public bool Knows(string id)
	{
		try
		{
			Find(id);
			return true;
		}
		catch (ArgumentException)
		{
			return false;
		}
	}

	private (ulong Address, Card Card) Find(string id)
	{
		if (id.Length is < 1 or > 16 || !ulong.TryParse(id, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out ulong address))
		{
			throw new ArgumentException("근처 기기를 찾을 수 없습니다. 목록에서 다시 골라 주세요.");
		}
		lock (gate)
		{
			if (cards.TryGetValue(address, out Card? card) && seen.TryGetValue(address, out Seen? s) && DateTimeOffset.UtcNow - s.Last < TimeSpan.FromSeconds(30))
			{
				return (address, card);
			}
		}
		throw new ArgumentException("근처 기기를 찾을 수 없습니다. 상대 기기 가까이에서 다시 골라 주세요.");
	}

	// ---- 배경 작업: Bluetooth 상태 · 스캔 · card 읽기 · 받기 광고 --------------------------------------

	private async Task RunAsync()
	{
		DateTimeOffset nextAdapterCheck = DateTimeOffset.MinValue;
		while (!stop.IsCancellationRequested)
		{
			try
			{
				DateTimeOffset now = DateTimeOffset.UtcNow;
				if (now >= nextAdapterCheck)
				{
					await CheckAdapterAsync();
					nextAdapterCheck = now + TimeSpan.FromSeconds(bluetooth is "none" or "checking" ? 15 : 60);
				}
				bool expired = false;
				lock (gate)
				{
					if (mode == "everyone" && now >= everyoneUntil)
					{
						mode = "registered";
						expired = true;
					}
					foreach (ulong old in seen.Where((KeyValuePair<ulong, Seen> s) => now - s.Value.Last > TimeSpan.FromSeconds(30)).Select((KeyValuePair<ulong, Seen> s) => s.Key).ToArray())
					{
						seen.Remove(old);
					}
					foreach (ulong old in cards.Where((KeyValuePair<ulong, Card> c) => now - c.Value.Read > TimeSpan.FromMinutes(30)).Select((KeyValuePair<ulong, Card> c) => c.Key).ToArray())
					{
						cards.Remove(old);
					}
				}
				if (expired)
				{
					SaveMode("registered");
				}
				UpdateWatcher(now);
				await UpdatePeripheralAsync();
				await ReadCardsAsync();
				await Task.Delay(1000, stop.Token);
			}
			catch (OperationCanceledException)
			{
				break;
			}
			catch
			{
				try
				{
					await Task.Delay(3000, stop.Token);
				}
				catch (OperationCanceledException)
				{
					break;
				}
			}
		}
	}

	private async Task CheckAdapterAsync()
	{
		try
		{
			BluetoothAdapter? found = await BluetoothAdapter.GetDefaultAsync().AsTask(stop.Token);
			if (found == null || !found.IsLowEnergySupported)
			{
				adapter = null;
				SetRadio(null);
				bluetooth = "none";
				canReceive = false;
				return;
			}
			adapter = found;
			canReceive = found.IsPeripheralRoleSupported;
			if (radio == null)
			{
				Radio? r = null;
				try
				{
					r = await found.GetRadioAsync().AsTask(stop.Token);
				}
				catch (OperationCanceledException)
				{
					throw;
				}
				catch
				{
				}
				SetRadio(r);
			}
			RadioChanged();
		}
		catch (OperationCanceledException)
		{
			throw;
		}
		catch
		{
			bluetooth = "none";
			canReceive = false;
		}
	}

	private void SetRadio(Radio? value)
	{
		if (ReferenceEquals(radio, value))
		{
			return;
		}
		if (radio != null)
		{
			radio.StateChanged -= OnRadioStateChanged;
		}
		radio = value;
		if (radio != null)
		{
			radio.StateChanged += OnRadioStateChanged;
		}
	}

	private void OnRadioStateChanged(Radio sender, object args)
	{
		RadioChanged();
	}

	private void RadioChanged()
	{
		if (adapter == null)
		{
			return;
		}
		// 라디오 정보를 못 읽으면(권한 등) 켜진 것으로 보고, 스캔이 실패하면 그때 'denied'로 바꿉니다.
		bool on = radio == null || radio.State == RadioState.On;
		if (bluetooth == "denied" && on)
		{
			return;
		}
		bluetooth = on ? "on" : "off";
		if (!on)
		{
			lock (gate)
			{
				seen.Clear();
			}
		}
	}

	private void UpdateWatcher(DateTimeOffset now)
	{
		bool wanted;
		lock (gate)
		{
			// 웹 화면 · QR 창 · 보내기 창이 근처 목록을 보고 있을 때만 스캔합니다 (배터리).
			wanted = bluetooth == "on" && (now - lastInterest < TimeSpan.FromSeconds(20) || outgoing is { Finished: false });
		}
		if (wanted && (watcher == null || watcher.Status is BluetoothLEAdvertisementWatcherStatus.Stopped or BluetoothLEAdvertisementWatcherStatus.Aborted))
		{
			StopWatcher();
			BluetoothLEAdvertisementWatcher w = new BluetoothLEAdvertisementWatcher
			{
				ScanningMode = BluetoothLEScanningMode.Active
			};
			w.Received += OnAdvertisement;
			w.Stopped += OnWatcherStopped;
			watcher = w;
			try
			{
				w.Start();
			}
			catch
			{
				StopWatcher();
			}
		}
		else if (!wanted && watcher != null)
		{
			StopWatcher();
		}
	}

	private void StopWatcher()
	{
		BluetoothLEAdvertisementWatcher? w = watcher;
		watcher = null;
		if (w == null)
		{
			return;
		}
		w.Received -= OnAdvertisement;
		w.Stopped -= OnWatcherStopped;
		try
		{
			if (w.Status == BluetoothLEAdvertisementWatcherStatus.Started)
			{
				w.Stop();
			}
		}
		catch
		{
		}
	}

	private void OnWatcherStopped(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementWatcherStoppedEventArgs args)
	{
		if (args.Error is BluetoothError.DisabledByPolicy or BluetoothError.DisabledByUser or BluetoothError.ConsentRequired)
		{
			bluetooth = "denied";
		}
		else if (args.Error == BluetoothError.RadioNotAvailable)
		{
			bluetooth = "off";
		}
	}

	private void OnAdvertisement(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementReceivedEventArgs args)
	{
		// 수동 필터: 광고와 스캔 응답 중 어느 쪽에 서비스 UUID가 있어도 같은 주소로 합칩니다.
		bool ours;
		try
		{
			ours = args.Advertisement.ServiceUuids.Contains(ServiceUuid);
		}
		catch
		{
			ours = false;
		}
		ulong address = args.BluetoothAddress;
		short rssi = args.RawSignalStrengthInDBm;
		if (rssi <= -127 || rssi >= 20)
		{
			return;
		}
		lock (gate)
		{
			if (!ours && !seen.ContainsKey(address))
			{
				return;
			}
			if (!seen.TryGetValue(address, out Seen? s))
			{
				seen[address] = new Seen
				{
					Rssi = rssi,
					Last = DateTimeOffset.UtcNow
				};
			}
			else
			{
				s.Rssi = s.Rssi * 0.75 + rssi * 0.25;
				s.Last = DateTimeOffset.UtcNow;
			}
		}
	}

	private async Task ReadCardsAsync()
	{
		ulong[] wanted;
		DateTimeOffset now = DateTimeOffset.UtcNow;
		lock (gate)
		{
			wanted = seen.Where((KeyValuePair<ulong, Seen> s) => now - s.Value.Last < TimeSpan.FromSeconds(10) && s.Value.Rssi >= -82 && (!cards.TryGetValue(s.Key, out Card? known) || now - known.Read > TimeSpan.FromSeconds(30)) && (!cardRetry.TryGetValue(s.Key, out DateTimeOffset retry) || now >= retry)).OrderByDescending((KeyValuePair<ulong, Seen> s) => s.Value.Rssi).Select((KeyValuePair<ulong, Seen> s) => s.Key).Take(2).ToArray();
		}
		foreach (ulong address in wanted)
		{
			Card? card = null;
			try
			{
				card = await ReadCardAsync(address);
			}
			catch (OperationCanceledException) when (stop.IsCancellationRequested)
			{
				throw;
			}
			catch
			{
			}
			lock (gate)
			{
				if (card != null)
				{
					cards[address] = card;
					cardRetry.Remove(address);
				}
				else
				{
					cardRetry[address] = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(20);
				}
			}
		}
	}

	private async Task<Card?> ReadCardAsync(ulong address)
	{
		using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
		timeout.CancelAfter(TimeSpan.FromSeconds(12));
		await gattGate.WaitAsync(timeout.Token);
		try
		{
			using BluetoothLEDevice? device = await BluetoothLEDevice.FromBluetoothAddressAsync(address).AsTask(timeout.Token);
			if (device == null)
			{
				return null;
			}
			GattDeviceServicesResult services = await device.GetGattServicesForUuidAsync(ServiceUuid, BluetoothCacheMode.Uncached).AsTask(timeout.Token);
			try
			{
				if (services.Status != GattCommunicationStatus.Success || services.Services.Count == 0)
				{
					return null;
				}
				GattCharacteristicsResult characteristics = await services.Services[0].GetCharacteristicsForUuidAsync(CardUuid, BluetoothCacheMode.Uncached).AsTask(timeout.Token);
				if (characteristics.Status != GattCommunicationStatus.Success || characteristics.Characteristics.Count == 0)
				{
					return null;
				}
				GattReadResult read = await characteristics.Characteristics[0].ReadValueAsync(BluetoothCacheMode.Uncached).AsTask(timeout.Token);
				if (read.Status != GattCommunicationStatus.Success || read.Value == null)
				{
					return null;
				}
				byte[] value = FromBuffer(read.Value);
				if (value.Length == 0 || value.Length > 1024)
				{
					return null;
				}
				using JsonDocument document = JsonDocument.Parse(value);
				JsonElement root = document.RootElement;
				if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("name", out JsonElement name) || name.ValueKind != JsonValueKind.String)
				{
					return null;
				}
				string platform = root.TryGetProperty("platform", out JsonElement p) && p.ValueKind == JsonValueKind.String ? CleanPlatform(p.GetString()) : "";
				string text = CleanName(name.GetString(), "");
				return text.Length == 0 ? null : new Card(text, platform, DateTimeOffset.UtcNow);
			}
			finally
			{
				DisposeAll(services);
			}
		}
		finally
		{
			gattGate.Release();
		}
	}

	// ---- 받기: GATT 서버 (card 읽기 · inbox 쓰기) ------------------------------------------------------

	private async Task UpdatePeripheralAsync()
	{
		bool wanted;
		lock (gate)
		{
			wanted = mode == "everyone" && bluetooth == "on" && canReceive && Volatile.Read(ref disposed) == 0;
		}
		try
		{
			if (wanted && !advertising)
			{
				GattServiceProvider? p = provider ?? await CreateProviderAsync();
				if (p == null)
				{
					return;
				}
				provider = p;
				p.StartAdvertising(new GattServiceProviderAdvertisingParameters
				{
					IsConnectable = true,
					IsDiscoverable = true
				});
				advertising = true;
			}
			else if (!wanted && advertising)
			{
				advertising = false;
				provider?.StopAdvertising();
				lock (gate)
				{
					partialWrites.Clear();
				}
			}
		}
		catch
		{
			advertising = false;
		}
	}

	private async Task<GattServiceProvider?> CreateProviderAsync()
	{
		GattServiceProviderResult result = await GattServiceProvider.CreateAsync(ServiceUuid).AsTask(stop.Token);
		if (result.Error != BluetoothError.Success || result.ServiceProvider == null)
		{
			if (result.Error is BluetoothError.NotSupported)
			{
				canReceive = false;
			}
			return null;
		}
		GattServiceProvider p = result.ServiceProvider;
		GattLocalCharacteristicResult card = await p.Service.CreateCharacteristicAsync(CardUuid, new GattLocalCharacteristicParameters
		{
			CharacteristicProperties = GattCharacteristicProperties.Read,
			ReadProtectionLevel = GattProtectionLevel.Plain,
			UserDescription = "아나 card"
		}).AsTask(stop.Token);
		if (card.Error != BluetoothError.Success || card.Characteristic == null)
		{
			return null;
		}
		card.Characteristic.ReadRequested += OnCardRead;
		GattLocalCharacteristicResult inbox = await p.Service.CreateCharacteristicAsync(InboxUuid, new GattLocalCharacteristicParameters
		{
			CharacteristicProperties = GattCharacteristicProperties.Write,
			WriteProtectionLevel = GattProtectionLevel.Plain,
			UserDescription = "아나 inbox"
		}).AsTask(stop.Token);
		if (inbox.Error != BluetoothError.Success || inbox.Characteristic == null)
		{
			return null;
		}
		inbox.Characteristic.WriteRequested += OnInboxWrite;
		return p;
	}

	private byte[] CardBytes()
	{
		return JsonSerializer.SerializeToUtf8Bytes(new
		{
			v = 1,
			name = CleanName(server.GuestOwnerName, "Windows PC"),
			platform = "Windows"
		});
	}

	private async void OnCardRead(GattLocalCharacteristic sender, GattReadRequestedEventArgs args)
	{
		Windows.Foundation.Deferral deferral = args.GetDeferral();
		try
		{
			GattReadRequest? request = await args.GetRequestAsync();
			if (request == null)
			{
				return;
			}
			byte[] value = CardBytes();
			if (request.Offset > value.Length)
			{
				request.RespondWithProtocolError(GattProtocolError.InvalidOffset);
				return;
			}
			request.RespondWithValue(ToBuffer(value.AsSpan((int)request.Offset).ToArray()));
		}
		catch
		{
		}
		finally
		{
			deferral.Complete();
		}
	}

	private async void OnInboxWrite(GattLocalCharacteristic sender, GattWriteRequestedEventArgs args)
	{
		Windows.Foundation.Deferral deferral = args.GetDeferral();
		try
		{
			GattWriteRequest? request = await args.GetRequestAsync();
			if (request == null)
			{
				return;
			}
			bool respond = request.Option == GattWriteOption.WriteWithResponse;
			string key = args.Session?.DeviceId?.Id ?? "";
			byte[] chunk = request.Value == null ? Array.Empty<byte>() : FromBuffer(request.Value);
			byte[]? complete = null;
			byte? error = null;
			lock (gate)
			{
				if (mode != "everyone")
				{
					error = GattProtocolError.WriteNotPermitted;
				}
				else
				{
					// 긴 쓰기: 조각이 offset 순서대로 오면 이어 붙이고, 완전한 JSON이 되면 처리합니다.
					byte[] old = request.Offset == 0 ? Array.Empty<byte>() : partialWrites.GetValueOrDefault(key) ?? Array.Empty<byte>();
					if (request.Offset != old.Length)
					{
						error = GattProtocolError.InvalidOffset;
					}
					else if (old.Length + chunk.Length > MaxOfferBytes)
					{
						partialWrites.Remove(key);
						error = GattProtocolError.InvalidAttributeValueLength;
					}
					else
					{
						byte[] merged = old.Concat(chunk).ToArray();
						if (IsCompleteJson(merged))
						{
							complete = merged;
							partialWrites.Remove(key);
						}
						else
						{
							partialWrites[key] = merged;
						}
					}
				}
			}
			if (error is byte code)
			{
				if (respond)
				{
					request.RespondWithProtocolError(code);
				}
				return;
			}
			if (respond)
			{
				request.Respond();
			}
			if (complete != null)
			{
				HandleOffer(complete, key);
			}
		}
		catch
		{
		}
		finally
		{
			deferral.Complete();
		}
	}

	private static bool IsCompleteJson(byte[] value)
	{
		try
		{
			using JsonDocument document = JsonDocument.Parse(value);
			return document.RootElement.ValueKind == JsonValueKind.Object;
		}
		catch (JsonException)
		{
			return false;
		}
	}

	private void HandleOffer(byte[] value, string deviceKey)
	{
		NearbyOffer? offer = ParseOffer(value, ProximityOf(deviceKey));
		if (offer == null)
		{
			return;
		}
		lock (gate)
		{
			// 확인 창은 한 번에 하나만. 받는 중이거나 이미 창이 떠 있으면 새 제안은 무시합니다(상대는 30초 뒤 '받지 않았습니다').
			if (pendingOffer != null || Volatile.Read(ref receiving) != 0)
			{
				return;
			}
			pendingOffer = offer;
		}
		try
		{
			OfferReceived?.Invoke(offer);
		}
		catch
		{
			lock (gate)
			{
				pendingOffer = null;
			}
		}
	}

	// GattSession.DeviceId.Id 예: "BluetoothLE#BluetoothLEaa:bb:cc:dd:ee:ff-11:22:33:44:55:66" (끝이 상대 주소)
	private string? ProximityOf(string deviceKey)
	{
		if (deviceKey.Length < 17)
		{
			return null;
		}
		string mac = deviceKey.Substring(deviceKey.Length - 17).Replace(":", "");
		if (!ulong.TryParse(mac, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out ulong address))
		{
			return null;
		}
		lock (gate)
		{
			if (seen.TryGetValue(address, out Seen? s) && DateTimeOffset.UtcNow - s.Last < TimeSpan.FromSeconds(30))
			{
				return s.Near ? "아주 가까움" : "가까움";
			}
		}
		return null;
	}

	internal static NearbyOffer? ParseOffer(byte[] value, string? proximity)
	{
		try
		{
			using JsonDocument document = JsonDocument.Parse(value);
			JsonElement root = document.RootElement;
			if (root.ValueKind != JsonValueKind.Object || Str(root, "t") != "offer" || !root.TryGetProperty("v", out JsonElement v) || v.ValueKind != JsonValueKind.Number || v.GetInt32() != 1)
			{
				return null;
			}
			string code = Str(root, "code") ?? "";
			if (code.Length != 2 || !code.All(char.IsAsciiDigit))
			{
				return null;
			}
			int count = root.TryGetProperty("count", out JsonElement c) && c.ValueKind == JsonValueKind.Number && c.TryGetInt32(out int n) ? n : 0;
			long bytes = root.TryGetProperty("bytes", out JsonElement b) && b.ValueKind == JsonValueKind.Number && b.TryGetInt64(out long l) ? l : -1;
			if (count is < 1 or > 1000 || bytes < 0)
			{
				return null;
			}
			string? url = GuestUrl(Str(root, "url"));
			if (url == null)
			{
				return null;
			}
			string name = CleanName(Str(root, "name"), "근처 기기");
			string summary = CleanName(Str(root, "summary"), $"파일 {count}개");
			return new NearbyOffer(name, CleanPlatform(Str(root, "platform")), code, count, bytes, summary.Length > 60 ? summary.Substring(0, 60) : summary, url, proximity);
		}
		catch
		{
			return null;
		}
	}

	private static string? Str(JsonElement root, string name)
	{
		return root.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
	}

	/// <summary>https://호스트/s/{32자리 소문자 16진수}/{토큰} 만 받습니다 (경로 뒤 · 질의 · 사용자 정보 없음).</summary>
	internal static string? GuestUrl(string? value)
	{
		if (value == null || value.Length > 400 || !Uri.TryCreate(value, UriKind.Absolute, out Uri? uri) || uri.Scheme != "https" || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0)
		{
			return null;
		}
		string path = uri.AbsolutePath;
		string[] parts = path.Split('/');
		if (parts.Length != 4 || parts[0].Length != 0 || parts[1] != "s" || parts[2].Length != 32 || !parts[2].All((char ch) => ch is >= '0' and <= '9' or >= 'a' and <= 'f') || parts[3].Length is < 22 or > 64 || !parts[3].All((char ch) => char.IsAsciiLetterOrDigit(ch) || ch == '-' || ch == '_'))
		{
			return null;
		}
		return uri.GetLeftPart(UriPartial.Authority) + path;
	}

	internal static string CleanName(string? value, string fallback)
	{
		string text = new string((value ?? "").Where((char ch) => !char.IsControl(ch)).Take(40).ToArray()).Trim();
		return text.Length == 0 ? fallback : text;
	}

	private static string CleanPlatform(string? value)
	{
		return value is "Windows" or "iPhone" or "iPad" or "Mac" or "Android" ? value : "";
	}

	/// <summary>확인 창의 [받기] / [거절] (또는 30초 자동 거절).</summary>
	public void AnswerOffer(NearbyOffer offer, bool accept)
	{
		lock (gate)
		{
			if (!ReferenceEquals(pendingOffer, offer))
			{
				return;
			}
			pendingOffer = null;
			if (accept)
			{
				Interlocked.Exchange(ref receiving, 1);
			}
		}
		_ = Task.Run(async () =>
		{
			if (!accept)
			{
				try
				{
					using StringContent body = new StringContent("{}", Encoding.UTF8, "application/json");
					using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
					timeout.CancelAfter(TimeSpan.FromSeconds(15));
					using (await http.PostAsync(offer.Url + "/decline", body, timeout.Token))
					{
					}
				}
				catch
				{
				}
				return;
			}
			try
			{
				int count = await ReceiveOfferAsync(offer);
				Notify?.Invoke("아나 · 근처 기기", $"{offer.Name}에서 {count}개 파일을 받았습니다.");
			}
			catch (Exception ex) when (ex is not OperationCanceledException || !stop.IsCancellationRequested)
			{
				Notify?.Invoke("아나 · 근처 기기", $"{offer.Name}에서 받지 못했습니다 · " + Friendly(ex));
			}
			finally
			{
				Interlocked.Exchange(ref receiving, 0);
			}
		});
	}

	private static string Friendly(Exception ex)
	{
		return ex switch
		{
			HttpRequestException => "인터넷 연결을 확인하세요.",
			TaskCanceledException => "응답이 없습니다.",
			IOException or InvalidDataException or ArgumentException => ex.Message,
			_ => "다시 시도하세요."
		};
	}

	private async Task<int> ReceiveOfferAsync(NearbyOffer offer)
	{
		using HttpResponseMessage infoResponse = await http.GetAsync(offer.Url + "/info", stop.Token);
		if (!infoResponse.IsSuccessStatusCode)
		{
			throw new IOException(infoResponse.StatusCode == System.Net.HttpStatusCode.NotFound ? "링크가 만료되었습니다." : $"상대 기기에 연결하지 못했습니다 ({(int)infoResponse.StatusCode}).");
		}
		byte[] raw = await infoResponse.Content.ReadAsByteArrayAsync(stop.Token);
		if (raw.Length > 1 << 20)
		{
			throw new InvalidDataException("올바르지 않은 응답입니다.");
		}
		using JsonDocument info = JsonDocument.Parse(raw);
		JsonElement root = info.RootElement;
		if (Str(root, "kind") != "send" || !root.TryGetProperty("files", out JsonElement files) || files.ValueKind != JsonValueKind.Array)
		{
			throw new InvalidDataException("올바르지 않은 응답입니다.");
		}
		List<(int Index, string Name, long Bytes)> list = new List<(int, string, long)>();
		foreach (JsonElement f in files.EnumerateArray())
		{
			int index = f.GetProperty("i").GetInt32();
			string name = f.GetProperty("name").GetString() ?? "";
			long bytes = f.GetProperty("bytes").GetInt64();
			if (index is < 0 or > 999 || bytes < 0 || bytes > TransferServer.MaxFile)
			{
				throw new InvalidDataException("올바르지 않은 파일 정보입니다.");
			}
			list.Add((index, SafeName(name), bytes));
		}
		if (list.Count == 0 || list.Count > 1000)
		{
			throw new InvalidDataException("받을 파일이 없습니다.");
		}
		string deviceId = "nearby-" + offer.Url.Substring(offer.Url.Length - 12);
		int saved = 0;
		foreach ((int index, string name, long bytes) in list)
		{
			string file = await DownloadAsync(offer.Url + "/file/" + index.ToString(CultureInfo.InvariantCulture), name, bytes);
			server.RecordExternal("receive", file, bytes, deviceId, offer.Name, "저장 완료", notify: true);
			saved++;
		}
		return saved;
	}

	/// <summary>다른 기기의 파일 이름을 Windows에 저장할 수 있게 바꿉니다 (금지 문자는 _, 끝의 점·공백 제거, 예약어 앞에 _).</summary>
	internal static string SafeName(string name)
	{
		string text = new string(name.Normalize(NormalizationForm.FormC).Select((char ch) => ch < ' ' || "<>:\"|?*/\\".Contains(ch) ? '_' : ch).ToArray()).Trim().TrimEnd('.', ' ');
		if (text.Length == 0 || text is "." or "..")
		{
			text = "파일";
		}
		if (text.Length > 180)
		{
			string extension = Path.GetExtension(text);
			extension = extension.Length > 12 ? "" : extension;
			text = text.Substring(0, 180 - extension.Length) + extension;
		}
		try
		{
			return Util.SafeRelative(text);
		}
		catch (ArgumentException)
		{
			return Util.SafeRelative("_" + text.Substring(0, Math.Min(text.Length, 179)));
		}
	}

	private async Task<string> DownloadAsync(string url, string name, long bytes)
	{
		string folder = Path.GetFullPath(server.Settings.SavePath);
		Util.NoLinks(folder);
		Directory.CreateDirectory(folder);
		string temporary = Path.Combine(folder, ".ahna-" + Guid.NewGuid().ToString("N") + ".part");
		try
		{
			using (HttpResponseMessage download = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, stop.Token))
			{
				if (!download.IsSuccessStatusCode)
				{
					throw new IOException(download.StatusCode == System.Net.HttpStatusCode.NotFound ? "링크가 만료되었습니다." : $"파일을 받지 못했습니다 ({(int)download.StatusCode}).");
				}
				if (download.Content.Headers.ContentLength is long length && length != bytes)
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

	// ---- 보내기: 티켓 → offer 쓰기 → 수락 대기 ---------------------------------------------------------

	private void ThrowIfSending()
	{
		lock (gate)
		{
			if (outgoing is { Finished: false })
			{
				throw new InvalidOperationException("근처 기기로 보내는 중입니다. 끝난 뒤 다시 시도하세요.");
			}
		}
	}

	/// <summary>근처 기기(id)에 파일을 보냅니다. cleanup: 끝나면 지울 임시 폴더(웹 화면에 끌어다 놓은 파일).</summary>
	public void StartSend(string id, string[] paths, string? cleanup = null)
	{
		(ulong address, Card card) = Find(id);
		if (server.GuestOrigin == null)
		{
			throw new InvalidOperationException(TransferServer.NasRequired);
		}
		if (paths.Length == 0)
		{
			throw new ArgumentException("보낼 파일을 고르세요.");
		}
		Outgoing send = new Outgoing
		{
			Id = id,
			Address = address,
			DeviceName = card.Name,
			Platform = card.Platform,
			Code = TransferServer.NewGuestCode()
		};
		lock (gate)
		{
			if (outgoing is { Finished: false })
			{
				throw new InvalidOperationException("근처 기기로 보내는 중입니다. 끝난 뒤 다시 시도하세요.");
			}
			outgoing = send;
			lastInterest = DateTimeOffset.UtcNow;
		}
		_ = Task.Run(() => RunSendAsync(send, paths, cleanup));
	}

	private async Task RunSendAsync(Outgoing send, string[] paths, string? cleanup)
	{
		TransferServer.GuestTicket? ticket = null;
		CancellationToken cancel = send.Cancel.Token;
		try
		{
			ticket = await server.CreateSendTicketAsync(paths, send.DeviceName, send.Code);
			send.Ticket = ticket;
			send.Count = ticket.Files.Length;
			send.Bytes = ticket.Total;
			send.Summary = Summary(ticket.Files.Select((TransferServer.GuestFile f) => f.Name).ToArray());
			cancel.ThrowIfCancellationRequested();
			byte[] offer = OfferBytes(server.GuestOwnerName, send.Code, send.Count, send.Bytes, send.Summary, server.GuestUrl(ticket));
			string? failure = await WriteOfferAsync(send.Address, offer, cancel);
			if (failure != null)
			{
				failure = await WriteOfferAsync(send.Address, offer, cancel);
			}
			if (failure != null)
			{
				server.CancelTicket(ticket.Token);
				Finish(send, "failed", failure);
				return;
			}
			send.Waiting = DateTimeOffset.UtcNow;
			send.State = "waiting";
			while (true)
			{
				await Task.Delay(400, cancel);
				string state = ticket.State;
				if (state == "ready")
				{
					// 상대 확인 창은 30초. [받기]를 누른 직후 첫 파일을 요청하기까지 몇 초 여유를 둡니다.
					if (DateTimeOffset.UtcNow - send.Waiting > AnswerTimeout + TimeSpan.FromSeconds(5))
					{
						server.CancelTicket(ticket.Token);
						Finish(send, "declined", "");
						return;
					}
				}
				else if (state == "transferring")
				{
					send.State = "transferring";
				}
				else if (state == "done")
				{
					// 알림은 TransferServer.Delivered(트레이 '파일 전달 완료')가 한 번 띄웁니다.
					Finish(send, "done", "");
					return;
				}
				else if (state == "declined")
				{
					Finish(send, send.State == "transferring" ? "failed" : "declined", send.State == "transferring" ? "상대 기기에서 받기가 중단되었습니다." : "");
					return;
				}
				else
				{
					Finish(send, send.State == "transferring" ? "failed" : "declined", send.State == "transferring" ? "전송 시간이 지나 중단되었습니다." : "");
					return;
				}
			}
		}
		catch (OperationCanceledException)
		{
			if (ticket != null)
			{
				server.CancelTicket(ticket.Token);
			}
			Finish(send, "declined", "보내기를 취소했습니다.");
			// 사용자가 취소했으면 결과 카드 없이 바로 닫습니다.
			lock (gate)
			{
				if (outgoing == send)
				{
					outgoing = null;
				}
			}
		}
		catch (Exception ex)
		{
			if (ticket != null)
			{
				server.CancelTicket(ticket.Token);
			}
			Finish(send, "failed", ex is ArgumentException or InvalidOperationException or IOException ? ex.Message : "보내지 못했습니다. 다시 시도하세요.");
		}
		finally
		{
			if (cleanup != null)
			{
				try
				{
					Directory.Delete(cleanup, recursive: true);
				}
				catch
				{
				}
			}
		}
	}

	private void Finish(Outgoing send, string state, string message)
	{
		send.Message = message;
		send.Ended = DateTimeOffset.UtcNow;
		send.State = state;
		// 결과는 잠깐 보여 주고 사라집니다 (거절·실패는 [닫기]를 누를 때까지 조금 더).
		TimeSpan keep = state == "done" ? TimeSpan.FromSeconds(8) : TimeSpan.FromSeconds(60);
		_ = Task.Run(async () =>
		{
			try
			{
				await Task.Delay(keep, stop.Token);
			}
			catch (OperationCanceledException)
			{
				return;
			}
			lock (gate)
			{
				if (outgoing == send)
				{
					outgoing = null;
				}
			}
		});
	}

	/// <summary>"사진 2장" / "파일 3개" / "회의자료.pdf"</summary>
	internal static string Summary(string[] names)
	{
		if (names.Length == 1)
		{
			return names[0].Length > 40 ? names[0].Substring(0, 39) + "…" : names[0];
		}
		string[] photo = { ".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".webp", ".bmp" };
		string[] video = { ".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm" };
		bool Is(string name, string[] list) => list.Contains(Path.GetExtension(name).ToLowerInvariant());
		if (names.All((string n) => Is(n, photo)))
		{
			return $"사진 {names.Length}장";
		}
		if (names.All((string n) => Is(n, video)))
		{
			return $"동영상 {names.Length}개";
		}
		return $"파일 {names.Length}개";
	}

	internal static byte[] OfferBytes(string ownerName, string code, int count, long bytes, string summary, string url)
	{
		string name = CleanName(ownerName, "Windows PC");
		for (int attempt = 0; attempt < 4; attempt++)
		{
			byte[] value = JsonSerializer.SerializeToUtf8Bytes(new
			{
				v = 1,
				t = "offer",
				name,
				platform = "Windows",
				code,
				count,
				bytes,
				summary,
				url
			});
			if (value.Length <= MaxOfferBytes)
			{
				return value;
			}
			name = name.Length > 12 ? name.Substring(0, 12) : name;
			summary = attempt == 0 ? summary : $"파일 {count}개";
		}
		throw new InvalidOperationException("서버 주소가 너무 깁니다.");
	}

	/// <summary>상대 기기의 inbox에 offer를 씁니다 (응답 있는 쓰기). 실패하면 이유, 성공하면 null.</summary>
	private async Task<string?> WriteOfferAsync(ulong address, byte[] offer, CancellationToken cancel)
	{
		using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel, stop.Token);
		timeout.CancelAfter(TimeSpan.FromSeconds(15));
		const string unreachable = "상대 기기에 연결하지 못했습니다. 상대 기기에서 아나를 열고 '근처 기기에서 받기'를 '10분 동안 모두'로 켜 달라고 하세요.";
		try
		{
			await gattGate.WaitAsync(timeout.Token);
		}
		catch (OperationCanceledException) when (!cancel.IsCancellationRequested)
		{
			return unreachable;
		}
		try
		{
			using BluetoothLEDevice? device = await BluetoothLEDevice.FromBluetoothAddressAsync(address).AsTask(timeout.Token);
			if (device == null)
			{
				return unreachable;
			}
			GattDeviceServicesResult services = await device.GetGattServicesForUuidAsync(ServiceUuid, BluetoothCacheMode.Uncached).AsTask(timeout.Token);
			try
			{
				if (services.Status != GattCommunicationStatus.Success || services.Services.Count == 0)
				{
					return unreachable;
				}
				GattCharacteristicsResult characteristics = await services.Services[0].GetCharacteristicsForUuidAsync(InboxUuid, BluetoothCacheMode.Uncached).AsTask(timeout.Token);
				if (characteristics.Status != GattCommunicationStatus.Success || characteristics.Characteristics.Count == 0)
				{
					return unreachable;
				}
				GattWriteResult result = await characteristics.Characteristics[0].WriteValueWithResultAsync(ToBuffer(offer), GattWriteOption.WriteWithResponse).AsTask(timeout.Token);
				return result.Status == GattCommunicationStatus.Success ? null : result.Status == GattCommunicationStatus.ProtocolError ? "상대 기기가 지금은 받지 않습니다. '근처 기기에서 받기'를 '10분 동안 모두'로 켜 달라고 하세요." : unreachable;
			}
			finally
			{
				DisposeAll(services);
			}
		}
		catch (OperationCanceledException) when (!cancel.IsCancellationRequested)
		{
			return unreachable;
		}
		catch (Exception ex) when (ex is not OperationCanceledException)
		{
			return unreachable;
		}
		finally
		{
			gattGate.Release();
		}
	}

	private static void DisposeAll(GattDeviceServicesResult services)
	{
		try
		{
			if (services.Services == null)
			{
				return;
			}
			foreach (GattDeviceService service in services.Services)
			{
				service.Dispose();
			}
		}
		catch
		{
		}
	}

	private static byte[] FromBuffer(IBuffer buffer)
	{
		byte[] bytes = new byte[buffer.Length];
		using DataReader reader = DataReader.FromBuffer(buffer);
		reader.ReadBytes(bytes);
		return bytes;
	}

	private static IBuffer ToBuffer(byte[] bytes)
	{
		using DataWriter writer = new DataWriter();
		writer.WriteBytes(bytes);
		return writer.DetachBuffer();
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
			StopWatcher();
		}
		catch
		{
		}
		try
		{
			if (advertising)
			{
				provider?.StopAdvertising();
			}
		}
		catch
		{
		}
		advertising = false;
		SetRadio(null);
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
