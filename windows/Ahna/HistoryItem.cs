using System;

namespace Ahna;

/// Preview: 글자(클립보드) 전송이면 앞부분 한 줄
public sealed record HistoryItem(string Id, DateTimeOffset At, string Direction, string Name, long Bytes, string Device, string Status, string Session, string? Preview = null);
