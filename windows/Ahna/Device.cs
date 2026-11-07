using System;

namespace Ahna;

public sealed class Device(string id, string name, bool owner)
{
	public string Id { get; } = id;

	public string Name { get; set; } = name;

	public bool Owner { get; } = owner;

	public DateTimeOffset LastSeen { get; set; } = DateTimeOffset.UtcNow;

	public DateTimeOffset LastReceiverSeen { get; set; } = DateTimeOffset.MinValue;

	public bool Native { get; init; }

	public bool CanReceive { get; set; } = true;

	// The paired device's own receiver identity (32 hex), when its app reports it. Empty for older apps.
	public string ComputerId { get; set; } = "";
}
