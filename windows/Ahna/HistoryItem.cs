using System;

namespace Ahna;

public sealed record HistoryItem(string Id, DateTimeOffset At, string Direction, string Name, long Bytes, string Device, string Status, string Session);
