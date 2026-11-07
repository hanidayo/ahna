using System;

namespace Ahna;

public sealed record ShareItem(string Id, string Name, string Path, long Bytes, string Target, bool Temporary, DateTimeOffset Created)
{
	public int DeliveryNotified;

	public int ReceiptRank;
}
