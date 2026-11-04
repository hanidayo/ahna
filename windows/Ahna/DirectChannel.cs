using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Ahna;

// 같은 네트워크(같은 공유기)면 서버를 거치지 않고 기기끼리 바로 주고받기.
// 이 파일은 windows/Ahna/DirectChannel.cs 와 같은 파일이어야 합니다.
//
// 받는 기기는 서버를 거친(=인증된) /api/state?direct=1 응답에 이 연결용 키·포트·주소를 넣어 줍니다.
// 보내는 기기는 그 주소로 TCP 연결해 요청 하나를 암호화해 보냅니다. 연결이 안 되면 지금처럼 서버로 보냅니다.
//
// 연결 한 번 = 요청 한 번:
//   보내는 쪽 → "AHNADR01"(8바이트) + 키 id(16바이트) + salt(16바이트, 연결마다 새로)
//   그다음 양쪽 모두 레코드: [길이 u32 big-endian][AES-256-GCM 암호문 + 태그 16바이트], 레코드 본문 최대 1 MiB
//   키: 보내는 쪽 = HMAC-SHA256(key, "c2s" + salt), 받는 쪽 = HMAC-SHA256(key, "s2c" + salt)
//   nonce(12바이트) = 0 0 0 0 + 레코드 번호(u64 big-endian, 방향마다 0부터)
//   보내는 쪽 첫 레코드 {"m":방법,"p":경로,"l":본문 길이,"t":Content-Type} → 본문 레코드들
//   받는 쪽 첫 레코드 {"s":상태 코드,"l":본문 길이} → 본문 레코드들
public static class DirectWire
{
    public const int FirstPort = 45853;
    public const int RecordSize = 1 << 20;
    /// 레코드 하나를 주고받는 최대 시간. 상대가 사라지면 이만큼 뒤에 끊습니다.
    public static readonly TimeSpan Idle = TimeSpan.FromSeconds(60);
    /// 본문을 다 보낸 뒤 응답을 기다리는 최대 시간(받는 쪽이 큰 파일을 옮기는 시간).
    public static readonly TimeSpan Reply = TimeSpan.FromMinutes(45);
    public static readonly byte[] Magic = "AHNADR01"u8.ToArray();

    public static byte[] Derive(byte[] key, string label, byte[] salt)
    {
        var input = new byte[label.Length + salt.Length];
        Encoding.ASCII.GetBytes(label, input);
        salt.CopyTo(input, label.Length);
        return HMACSHA256.HashData(key, input);
    }

    public sealed class Cipher(byte[] key) : IDisposable
    {
        readonly AesGcm aes = new(key, 16);
        ulong counter;
        byte[] Nonce()
        {
            var nonce = new byte[12];
            BinaryPrimitives.WriteUInt64BigEndian(nonce.AsSpan(4), counter++);
            return nonce;
        }
        public async Task WriteAsync(Stream stream, ReadOnlyMemory<byte> plain, CancellationToken ct)
        {
            var frame = new byte[4 + plain.Length + 16];
            BinaryPrimitives.WriteUInt32BigEndian(frame, (uint)(plain.Length + 16));
            aes.Encrypt(Nonce(), plain.Span, frame.AsSpan(4, plain.Length), frame.AsSpan(4 + plain.Length, 16));
            using var idle = CancellationTokenSource.CreateLinkedTokenSource(ct);
            idle.CancelAfter(Idle);
            try { await stream.WriteAsync(frame, idle.Token); }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new IOException("상대 기기가 응답하지 않습니다."); }
        }
        /// wait: 이 레코드를 기다릴 최대 시간(기본 Idle). 상대가 사라져도 멈춰 있지 않게 합니다.
        public async Task<byte[]> ReadAsync(Stream stream, CancellationToken ct, TimeSpan? wait = null)
        {
            using var idle = CancellationTokenSource.CreateLinkedTokenSource(ct);
            idle.CancelAfter(wait ?? Idle);
            var head = new byte[4];
            var frame = Array.Empty<byte>();
            try
            {
                await stream.ReadExactlyAsync(head, idle.Token);
                var length = BinaryPrimitives.ReadUInt32BigEndian(head);
                if (length < 16 || length > RecordSize + 16) throw new IOException("올바르지 않은 직접 전송 데이터입니다.");
                frame = new byte[length];
                await stream.ReadExactlyAsync(frame, idle.Token);
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new IOException("상대 기기가 응답하지 않습니다."); }
            var plain = new byte[frame.Length - 16];
            try { aes.Decrypt(Nonce(), frame.AsSpan(0, plain.Length), frame.AsSpan(plain.Length), plain); }
            catch (CryptographicException) { throw new IOException("직접 전송 데이터를 확인하지 못했습니다."); }
            return plain;
        }
        public void Dispose() => aes.Dispose();
    }

    /// 쓰는 내용을 1 MiB 레코드로 암호화해 내보냅니다. 정해진 길이를 넘기거나 모자라면 오류.
    public sealed class SealStream(Stream inner, Cipher cipher, long length) : Stream
    {
        readonly byte[] buffer = new byte[RecordSize];
        int filled;
        long written;
        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => written; set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override Task FlushAsync(CancellationToken ct) => Task.CompletedTask;
        public override int Read(byte[] b, int o, int c) => throw new NotSupportedException();
        public override long Seek(long o, SeekOrigin s) => throw new NotSupportedException();
        public override void SetLength(long v) => throw new NotSupportedException();
        public override void Write(byte[] b, int o, int c) => WriteAsync(b.AsMemory(o, c)).AsTask().GetAwaiter().GetResult();
        public override async ValueTask WriteAsync(ReadOnlyMemory<byte> data, CancellationToken ct = default)
        {
            if (written + data.Length > length) throw new IOException("보낼 파일 크기가 바뀌었습니다.");
            written += data.Length;
            while (data.Length > 0)
            {
                var n = Math.Min(data.Length, buffer.Length - filled);
                data.Span[..n].CopyTo(buffer.AsSpan(filled));
                filled += n; data = data[n..];
                if (filled == buffer.Length) { await cipher.WriteAsync(inner, buffer, ct); filled = 0; }
            }
        }
        public override Task WriteAsync(byte[] b, int o, int c, CancellationToken ct) => WriteAsync(b.AsMemory(o, c), ct).AsTask();
        public async Task CompleteAsync(CancellationToken ct)
        {
            if (written != length) throw new IOException("보낼 파일 크기가 바뀌었습니다.");
            if (filled > 0) { await cipher.WriteAsync(inner, buffer.AsMemory(0, filled), ct); filled = 0; }
            await inner.FlushAsync(ct);
        }
    }

    /// 정해진 길이만큼 레코드를 풀어 읽습니다.
    public sealed class OpenStream(Stream inner, Cipher cipher, long length, bool owns) : Stream
    {
        byte[] current = [];
        int offset;
        long left = length;
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => length;
        public override long Position { get => length - left - (current.Length - offset); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long o, SeekOrigin s) => throw new NotSupportedException();
        public override void SetLength(long v) => throw new NotSupportedException();
        public override void Write(byte[] b, int o, int c) => throw new NotSupportedException();
        public override int Read(byte[] b, int o, int c) => ReadAsync(b.AsMemory(o, c)).AsTask().GetAwaiter().GetResult();
        public override Task<int> ReadAsync(byte[] b, int o, int c, CancellationToken ct) => ReadAsync(b.AsMemory(o, c), ct).AsTask();
        public override async ValueTask<int> ReadAsync(Memory<byte> destination, CancellationToken ct = default)
        {
            if (destination.Length == 0) return 0;
            if (offset == current.Length)
            {
                if (left == 0) return 0;
                try { current = await cipher.ReadAsync(inner, ct); }
                catch (IOException e) when (owns && e is not DirectClient.Unavailable) { throw new DirectClient.Unavailable("직접 받기가 끊겼습니다.", e); }
                offset = 0;
                if (current.Length == 0 || current.Length > left) throw new IOException("올바르지 않은 직접 전송 데이터입니다.");
                left -= current.Length;
            }
            var n = Math.Min(destination.Length, current.Length - offset);
            current.AsSpan(offset, n).CopyTo(destination.Span);
            offset += n;
            return n;
        }
        protected override void Dispose(bool disposing)
        {
            if (disposing && owns) { cipher.Dispose(); inner.Dispose(); }
            base.Dispose(disposing);
        }
    }

    static (DateTimeOffset At, string[] List) addressCache = (DateTimeOffset.MinValue, []);
    /// 이 기기의 공유기 안 주소(IPv4). 루프백·169.254.x.x는 뺍니다.
    public static string[] LocalAddresses()
    {
        var cached = addressCache;
        if (DateTimeOffset.UtcNow - cached.At < TimeSpan.FromSeconds(30)) return cached.List;
        string[] list;
        try
        {
            list = NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
                .SelectMany(n => n.GetIPProperties().UnicastAddresses)
                .Select(a => a.Address)
                .Where(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a) && !a.ToString().StartsWith("169.254.", StringComparison.Ordinal))
                .Select(a => a.ToString()).Distinct().Take(8).ToArray();
        }
        catch (NetworkInformationException) { list = []; }
        addressCache = (DateTimeOffset.UtcNow, list);
        return list;
    }
}

/// 받는 기기 쪽: 공유기 안에서 들어오는 직접 연결을 받아 이 기기의 아나(127.0.0.1)로 넘깁니다.
public sealed class DirectHost : IAsyncDisposable
{
    sealed record Key(string Id, byte[] Secret, string Token, DateTimeOffset Created)
    {
        /// 이미 쓴 salt: 같은 연결 내용을 다시 보내는(재전송) 것을 막습니다.
        public HashSet<string> Seen { get; } = new();
    }
    sealed record Head(string M, string P, long L, string? T);
    static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };
    readonly ConcurrentDictionary<string, Key> keys = new();
    readonly ConcurrentDictionary<string, string> byToken = new();
    readonly Uri local;
    readonly HttpClient http = new(new SocketsHttpHandler { UseCookies = false, AllowAutoRedirect = false, UseProxy = false }) { Timeout = Timeout.InfiniteTimeSpan };
    readonly CancellationTokenSource stop = new();
    readonly SemaphoreSlim slots = new(8, 8);
    TcpListener? listener;
    public int Port { get; private set; }
    public DirectHost(Uri local) { this.local = local; }

    public void Start()
    {
        for (var port = DirectWire.FirstPort; port < DirectWire.FirstPort + 5; port++)
        {
            try
            {
                var candidate = new TcpListener(IPAddress.Any, port);
                candidate.Start(16);
                listener = candidate; Port = port;
                _ = AcceptLoop(candidate);
                return;
            }
            catch (SocketException) { }
        }
    }

    /// /api/state?direct=1 응답에 넣을 값. 같은 세션이면 30분 동안 같은 키를 씁니다(키는 1시간 뒤 만료).
    public object? Offer(string token)
    {
        if (listener is null || token.Length == 0) return null;
        var now = DateTimeOffset.UtcNow;
        foreach (var old in keys.Values.Where(k => now - k.Created > TimeSpan.FromHours(1)).ToArray())
        {
            keys.TryRemove(old.Id, out _);
            byToken.TryRemove(new KeyValuePair<string, string>(old.Token, old.Id));
        }
        if (keys.Count > 1000) return null;
        Key? key = byToken.TryGetValue(token, out var id) && keys.TryGetValue(id, out var existing) && now - existing.Created < TimeSpan.FromMinutes(30) ? existing : null;
        if (key is null)
        {
            key = new Key(Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant(), RandomNumberGenerator.GetBytes(32), token, now);
            keys[key.Id] = key;
            byToken[token] = key.Id;
        }
        var addrs = DirectWire.LocalAddresses();
        return addrs.Length == 0 ? null : new { id = key.Id, key = Convert.ToBase64String(key.Secret), port = Port, addrs };
    }

    async Task AcceptLoop(TcpListener server)
    {
        while (!stop.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await server.AcceptTcpClientAsync(stop.Token); }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }
            catch (SocketException) { continue; }
            if (!slots.Wait(0)) { client.Dispose(); continue; }
            _ = Task.Run(async () =>
            {
                try { await Serve(client); }
                catch (Exception) { }
                finally { client.Dispose(); slots.Release(); }
            });
        }
    }

    static bool Allowed(Head h)
    {
        var path = h.P.Split('?')[0];
        if (!Ahna.Remote.Wire.Allowed(h.M, h.P) || Ahna.Remote.Wire.GuestComputer(h.P) is not null || !path.StartsWith("/api/", StringComparison.Ordinal) || path == "/api/pair") return false;
        if (h.M == "GET") return h.L == 0;
        return h.M == "POST" && h.L >= 0 && h.L <= (Ahna.Remote.Wire.LargeBody(h.P) ? TransferServer.MaxFile : 16384);
    }

    async Task Serve(TcpClient client)
    {
        client.NoDelay = true;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        var stream = client.GetStream();
        var hello = new byte[40];
        await stream.ReadExactlyAsync(hello, timeout.Token);
        if (!hello.AsSpan(0, 8).SequenceEqual(DirectWire.Magic)) return;
        var id = Convert.ToHexString(hello, 8, 16).ToLowerInvariant();
        if (!keys.TryGetValue(id, out var key) || DateTimeOffset.UtcNow - key.Created > TimeSpan.FromHours(1)) return;
        var salt = hello[24..40];
        lock (key.Seen)
        {
            if (key.Seen.Count > 20000 || !key.Seen.Add(Convert.ToHexString(salt))) return;
        }
        using var inbound = new DirectWire.Cipher(DirectWire.Derive(key.Secret, "c2s", salt));
        using var outbound = new DirectWire.Cipher(DirectWire.Derive(key.Secret, "s2c", salt));
        var head = JsonSerializer.Deserialize<Head>(await inbound.ReadAsync(stream, timeout.Token), JsonOptions);
        timeout.CancelAfter(TimeSpan.FromMinutes(45));
        var ct = timeout.Token;
        if (head is null || head.M is null || head.P is null || !Allowed(head)) { await Respond(stream, outbound, 400, [], ct); return; }
        using var request = new HttpRequestMessage(new HttpMethod(head.M), new Uri(local, head.P));
        request.Headers.TryAddWithoutValidation("Cookie", "ahna=" + key.Token);
        request.Headers.TryAddWithoutValidation("X-Ahna-Remote", "1");
        if (head.M == "POST")
        {
            var body = new StreamContent(new DirectWire.OpenStream(stream, inbound, head.L, owns: false), 65536);
            body.Headers.ContentLength = head.L;
            if (head.T is { Length: > 0 } type && MediaTypeHeaderValue.TryParse(type, out var media)) body.Headers.ContentType = media;
            request.Content = body;
        }
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
        await using var input = await response.Content.ReadAsStreamAsync(ct);
        var length = response.Content.Headers.ContentLength;
        if (length is null)
        {
            // JSON 같은 짧은 응답: 길이를 알 수 있게 모아서 보냅니다(최대 4 MiB).
            using var collected = new MemoryStream();
            var chunk = new byte[65536]; int read;
            while ((read = await input.ReadAsync(chunk, ct)) > 0)
            {
                if (collected.Length + read > 4 * 1024 * 1024) throw new IOException("응답이 너무 깁니다.");
                collected.Write(chunk, 0, read);
            }
            await Respond(stream, outbound, (int)response.StatusCode, collected.ToArray(), ct);
            return;
        }
        await outbound.WriteAsync(stream, JsonSerializer.SerializeToUtf8Bytes(new { s = (int)response.StatusCode, l = length.Value }), ct);
        await using (var seal = new DirectWire.SealStream(stream, outbound, length.Value))
        {
            await input.CopyToAsync(seal, 65536, ct);
            await seal.CompleteAsync(ct);
        }
    }

    static async Task Respond(Stream stream, DirectWire.Cipher outbound, int status, byte[] body, CancellationToken ct)
    {
        await outbound.WriteAsync(stream, JsonSerializer.SerializeToUtf8Bytes(new { s = status, l = body.LongLength }), ct);
        for (var i = 0; i < body.Length; i += DirectWire.RecordSize)
            await outbound.WriteAsync(stream, body.AsMemory(i, Math.Min(DirectWire.RecordSize, body.Length - i)), ct);
        await stream.FlushAsync(ct);
    }

    public async ValueTask DisposeAsync()
    {
        stop.Cancel();
        try { listener?.Stop(); } catch (SocketException) { }
        listener = null;
        http.Dispose();
        await Task.CompletedTask;
    }
}

/// 보내는 기기 쪽(Windows): 상대가 알려 준 주소로 직접 연결해 요청 하나를 보내고 응답을 HttpResponseMessage로 돌려줍니다.
public sealed record DirectInfo(string Id, byte[] Key, int Port, string[] Addrs)
{
    public static DirectInfo? Parse(JsonElement root)
    {
        try
        {
            if (!root.TryGetProperty("direct", out var d) || d.ValueKind != JsonValueKind.Object) return null;
            var id = d.GetProperty("id").GetString() ?? "";
            var key = Convert.FromBase64String(d.GetProperty("key").GetString() ?? "");
            var port = d.GetProperty("port").GetInt32();
            var addrs = d.GetProperty("addrs").EnumerateArray().Select(a => a.GetString() ?? "").Where(a => IPAddress.TryParse(a, out var ip) && ip.AddressFamily == AddressFamily.InterNetwork).Take(8).ToArray();
            if (id.Length != 32 || !id.All(Uri.IsHexDigit) || key.Length != 32 || port is < 1 or > 65535 || addrs.Length == 0) return null;
            return new DirectInfo(id, key, port, addrs);
        }
        catch (Exception e) when (e is FormatException or InvalidOperationException or KeyNotFoundException) { return null; }
    }
}

public static class DirectClient
{
    /// 직접 연결이 안 되거나 도중에 끊김: 서버를 거쳐 다시 보내면 됩니다.
    public sealed class Unavailable(string message, Exception? inner = null) : IOException(message, inner);

    static async Task<NetworkStream> ConnectAsync(DirectInfo info, CancellationToken ct)
    {
        using var race = CancellationTokenSource.CreateLinkedTokenSource(ct);
        race.CancelAfter(TimeSpan.FromMilliseconds(900));
        var attempts = info.Addrs.Select(async address =>
        {
            var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
            try { await socket.ConnectAsync(IPAddress.Parse(address), info.Port, race.Token); return socket; }
            catch (Exception) { socket.Dispose(); return null; }
        }).ToList();
        Socket? winner = null;
        while (attempts.Count > 0)
        {
            var done = await Task.WhenAny(attempts);
            attempts.Remove(done);
            var socket = await done;
            if (socket is null) continue;
            if (winner is null) { winner = socket; race.Cancel(); }
            else socket.Dispose();
        }
        if (ct.IsCancellationRequested) { winner?.Dispose(); ct.ThrowIfCancellationRequested(); }
        if (winner is null) throw new Unavailable("같은 네트워크에서 상대 기기에 바로 연결하지 못했습니다.");
        return new NetworkStream(winner, ownsSocket: true);
    }

    public static async Task<HttpResponseMessage> SendAsync(DirectInfo info, HttpMethod method, string path, HttpContent? content, CancellationToken ct)
    {
        long length = content is null ? 0 : content.Headers.ContentLength ?? throw new ArgumentException("본문 길이가 필요합니다.");
        var stream = await ConnectAsync(info, ct);
        DirectWire.Cipher? inbound = null;
        var delivered = false;
        try
        {
            var salt = RandomNumberGenerator.GetBytes(16);
            var hello = new byte[40];
            DirectWire.Magic.CopyTo(hello, 0);
            Convert.FromHexString(info.Id).CopyTo(hello, 8);
            salt.CopyTo(hello, 24);
            await stream.WriteAsync(hello, ct);
            using (var outbound = new DirectWire.Cipher(DirectWire.Derive(info.Key, "c2s", salt)))
            {
                await outbound.WriteAsync(stream, JsonSerializer.SerializeToUtf8Bytes(new { m = method.Method, p = path, l = length, t = content?.Headers.ContentType?.ToString() }), ct);
                if (content is not null)
                {
                    await using var seal = new DirectWire.SealStream(stream, outbound, length);
                    await content.CopyToAsync(seal, ct);
                    await seal.CompleteAsync(ct);
                }
                await stream.FlushAsync(ct);
            }
            // 파일 본문을 다 보낸 뒤에는 상대가 이미 저장했을 수 있어 서버로 다시 보내지 않습니다(같은 파일이 두 번 생기지 않게).
            delivered = length > 0;
            inbound = new DirectWire.Cipher(DirectWire.Derive(info.Key, "s2c", salt));
            using var head = JsonDocument.Parse(await inbound.ReadAsync(stream, ct, DirectWire.Reply));
            var status = head.RootElement.GetProperty("s").GetInt32();
            var bodyLength = head.RootElement.GetProperty("l").GetInt64();
            if (status is < 100 or > 599 || bodyLength < 0 || bodyLength > TransferServer.MaxFile) throw new IOException("올바르지 않은 직접 전송 응답입니다.");
            // 401: 연결 정보가 바뀌었을 수 있으니 서버를 거쳐 다시 확인합니다(직접 연결 키가 예전 세션 것일 때).
            if (status == 401) { delivered = false; throw new Unavailable("직접 연결 인증이 바뀌었습니다."); }
            var response = new HttpResponseMessage((HttpStatusCode)status) { Content = new StreamContent(new DirectWire.OpenStream(stream, inbound, bodyLength, owns: true), 65536) };
            response.Content.Headers.ContentLength = bodyLength;
            return response;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { inbound?.Dispose(); stream.Dispose(); throw; }
        catch (Exception e) when (e is IOException or SocketException or JsonException or KeyNotFoundException or InvalidOperationException or FormatException)
        {
            inbound?.Dispose(); stream.Dispose();
            if (delivered) throw new IOException("상대 기기의 저장 결과를 받지 못했습니다. 상대 기기에서 파일을 확인하세요.", e);
            throw e as Unavailable ?? new Unavailable("직접 전송이 끊겼습니다.", e);
        }
    }
}
