using System.Globalization;
using System.Text.Json;

// 관리자 페이지(/_ahna/admin)가 쓰는 기기 목록·사용량·설정. /data/admin.json 에 저장합니다.
// 서버는 기기끼리의 등록(짝 맺기) 정보는 모릅니다. 여기 있는 것은 "서버에 연결한 기기"와 그 기기를 거친 전송량입니다.
sealed class DeviceRecord
{
    public string Name { get; set; } = "";
    public string Platform { get; set; } = "";
    public DateTimeOffset First { get; set; }
    public DateTimeOffset Last { get; set; }
    public string Ip { get; set; } = "";
    /// 초기화할 때마다 1씩 올라가 예전 연결 토큰을 무효로 만듭니다.
    public int Gen { get; set; }
    public bool Blocked { get; set; }
    public bool Hidden { get; set; }
    public string? WarnedDay { get; set; }
    public Dictionary<string, long> Days { get; set; } = new();
}

/// 전체 공지. 기기는 연결할 때 받아 가서 읽지 않은 공지를 띄우고, 읽으면 알려 줍니다(Reads).
sealed class Announcement
{
    public string Id { get; set; } = "";
    public string Text { get; set; } = "";
    public DateTimeOffset Created { get; set; }
    public Dictionary<string, DateTimeOffset> Reads { get; set; } = new();
}

sealed class AdminData
{
    /// 전체 초기화할 때마다 1씩 올라갑니다.
    public int Epoch { get; set; }
    /// 기기 하나가 하루에 서버를 거쳐 주고받을 수 있는 양(GB). 0이면 제한 없음.
    public double LimitGB { get; set; }
    /// 한도를 넘으면 그날은 서버를 통한 파일 전송을 막습니다(false면 알림만).
    public bool Enforce { get; set; }
    public Dictionary<string, DeviceRecord> Devices { get; set; } = new();
    public List<Announcement> Notices { get; set; } = new();
}

sealed class AdminStore
{
    readonly string path;
    readonly object gate = new();
    readonly AdminData data;
    bool dirty;
    static readonly JsonSerializerOptions Json = new() { WriteIndented = false };

    public AdminStore(string path)
    {
        this.path = path;
        try { data = File.Exists(path) ? JsonSerializer.Deserialize<AdminData>(File.ReadAllText(path), Json) ?? new() : new(); }
        catch (Exception) { data = new(); }
        _ = Task.Run(async () => { while (true) { await Task.Delay(TimeSpan.FromSeconds(20)); Save(false); } });
    }

    public static string Today => DateTime.Now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    public long LimitBytes { get { lock (gate) return data.LimitGB <= 0 ? 0 : (long)(data.LimitGB * 1024 * 1024 * 1024); } }
    public double LimitGB { get { lock (gate) return data.LimitGB; } }
    public bool Enforce { get { lock (gate) return data.Enforce && data.LimitGB > 0; } }

    public (int Gen, int Epoch) Generation(string id) { lock (gate) return (data.Devices.TryGetValue(id, out var d) ? d.Gen : 0, data.Epoch); }
    public bool Blocked(string id) { lock (gate) return data.Devices.TryGetValue(id, out var d) && d.Blocked; }
    public bool Known(string id) { lock (gate) return data.Devices.ContainsKey(id); }

    DeviceRecord Get(string id)
    {
        if (!data.Devices.TryGetValue(id, out var d))
        {
            // 목록이 끝없이 커지지 않게: 오래 안 보인 숨긴 기기부터 정리
            if (data.Devices.Count >= 2000)
                foreach (var old in data.Devices.Where(x => x.Value.Hidden && x.Value.Gen == 0 && !x.Value.Blocked).OrderBy(x => x.Value.Last).Take(100).Select(x => x.Key).ToArray()) data.Devices.Remove(old);
            d = new DeviceRecord { First = DateTimeOffset.UtcNow, Last = DateTimeOffset.UtcNow };
            data.Devices[id] = d; dirty = true;
        }
        return d;
    }

    public void Touch(string id, string? ip, string? name = null, string? platform = null)
    {
        lock (gate)
        {
            if (data.Devices.Count >= 2000 && !data.Devices.ContainsKey(id)) return;
            var d = Get(id); var now = DateTimeOffset.UtcNow;
            if (now - d.Last > TimeSpan.FromMinutes(1)) { d.Last = now; dirty = true; }
            if (ip is { Length: > 0 } && ip != d.Ip) { d.Ip = ip.Length > 64 ? ip[..64] : ip; dirty = true; }
            if (name is { Length: > 0 } && name != d.Name) { d.Name = name; dirty = true; }
            if (platform is { Length: > 0 } && platform != d.Platform) { d.Platform = platform; dirty = true; }
            if (d.Hidden) { d.Hidden = false; dirty = true; }
        }
    }

    public long Used(string id) { lock (gate) return data.Devices.TryGetValue(id, out var d) ? d.Days.GetValueOrDefault(Today) : 0; }

    /// 오늘 사용량에 더하고, 이번에 처음 한도를 넘었으면 true(알림을 보낼 때)
    public bool Add(string id, long bytes)
    {
        if (bytes <= 0) return false;
        lock (gate)
        {
            var d = Get(id); var today = Today;
            d.Days[today] = d.Days.GetValueOrDefault(today) + bytes; dirty = true;
            if (d.Days.Count > 40) foreach (var old in d.Days.Keys.OrderBy(k => k, StringComparer.Ordinal).Take(d.Days.Count - 35).ToArray()) d.Days.Remove(old);
            var limit = data.LimitGB <= 0 ? 0 : (long)(data.LimitGB * 1024 * 1024 * 1024);
            if (limit > 0 && d.Days[today] >= limit && d.WarnedDay != today) { d.WarnedDay = today; return true; }
            return false;
        }
    }

    public void Settings(double limitGB, bool enforce) { lock (gate) { data.LimitGB = Math.Clamp(Math.Round(limitGB, 1), 0, 100000); data.Enforce = enforce; dirty = true; } Save(true); }
    public bool SetBlocked(string id, bool blocked) { lock (gate) { if (!data.Devices.TryGetValue(id, out var d)) return false; d.Blocked = blocked; dirty = true; } Save(true); return true; }
    public bool Reset(string id) { lock (gate) { if (!data.Devices.TryGetValue(id, out var d)) return false; d.Gen++; dirty = true; } Save(true); return true; }
    public bool Hide(string id) { lock (gate) { if (!data.Devices.TryGetValue(id, out var d)) return false; d.Hidden = true; dirty = true; } Save(true); return true; }
    // 공지: 30일이 지나면 서버에서도 지웁니다(기기에서는 읽고 3일 뒤 사라짐).
    static readonly TimeSpan NoticeLife = TimeSpan.FromDays(30);
    void PruneNotices() { if (data.Notices.RemoveAll(n => DateTimeOffset.UtcNow - n.Created > NoticeLife) > 0) dirty = true; }
    public string Announce(string text)
    {
        var id = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(6)).ToLowerInvariant();
        lock (gate) { PruneNotices(); data.Notices.Insert(0, new Announcement { Id = id, Text = text, Created = DateTimeOffset.UtcNow }); if (data.Notices.Count > 30) data.Notices.RemoveRange(30, data.Notices.Count - 30); dirty = true; }
        Save(true); return id;
    }
    public bool RemoveNotice(string id) { bool removed; lock (gate) { removed = data.Notices.RemoveAll(n => n.Id == id) > 0; dirty |= removed; } if (removed) Save(true); return removed; }
    public object[] Notices() { lock (gate) { PruneNotices(); return data.Notices.Select(n => (object)new { id = n.Id, text = n.Text, created = n.Created.ToUnixTimeSeconds() }).ToArray(); } }
    public void ReadNotice(string id, string device)
    {
        lock (gate) { var n = data.Notices.FirstOrDefault(x => x.Id == id); if (n is null || n.Reads.ContainsKey(device) || n.Reads.Count >= 2000) return; n.Reads[device] = DateTimeOffset.UtcNow; dirty = true; }
    }
    public void ResetAll() { lock (gate) { data.Epoch++; dirty = true; } Save(true); }

    public object Snapshot(Func<string, bool> online)
    {
        lock (gate)
        {
            var today = DateTime.Now.Date;
            long Sum(DeviceRecord d, int days) => d.Days.Where(x => DateTime.TryParseExact(x.Key, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var day) && (today - day).TotalDays < days).Sum(x => x.Value);
            PruneNotices();
            var all = data.Devices.Values.ToArray();
            return new
            {
                total = new { today = all.Sum(d => Sum(d, 1)), week = all.Sum(d => Sum(d, 7)), month = all.Sum(d => Sum(d, 30)) },
                // 최근 7일 날짜별 합계(오래된 날부터)
                days = Enumerable.Range(0, 7).Reverse().Select(back => { var key = today.AddDays(-back).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture); return new { day = key, bytes = all.Sum(d => d.Days.GetValueOrDefault(key)) }; }).ToArray(),
                notices = data.Notices.Select(n => new { id = n.Id, text = n.Text, created = n.Created, reads = n.Reads.Count }).ToArray(),
                limitGB = data.LimitGB,
                enforce = data.Enforce,
                epoch = data.Epoch,
                devices = data.Devices.Where(x => !x.Value.Hidden).Select(x => new
                {
                    id = x.Key, name = x.Value.Name, platform = x.Value.Platform, online = online(x.Key),
                    first = x.Value.First, last = x.Value.Last, ip = x.Value.Ip, blocked = x.Value.Blocked, resets = x.Value.Gen,
                    today = Sum(x.Value, 1), week = Sum(x.Value, 7), month = Sum(x.Value, 30),
                }).OrderByDescending(x => x.online).ThenByDescending(x => x.last).ToArray(),
            };
        }
    }

    public void Save(bool force)
    {
        string text;
        lock (gate) { if (!dirty && !force) return; text = JsonSerializer.Serialize(data, Json); dirty = false; }
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var part = path + "." + Guid.NewGuid().ToString("N") + ".part";
            File.WriteAllText(part, text); File.Move(part, path, true);
        }
        catch (Exception) { lock (gate) dirty = true; }
    }
}
