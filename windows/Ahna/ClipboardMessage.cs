using System;
using System.Text;

namespace Ahna;

public sealed record ClipboardMessage(string Id, string Text, string Sender, string Target, DateTimeOffset Created)
{
	public int Bytes => Encoding.UTF8.GetByteCount(Text);
}
