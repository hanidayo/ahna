using System.Collections.Generic;

namespace Ahna.Remote;

public sealed record ResponseHead(int Status, long? Length = null, Dictionary<string, string[]>? Headers = null);
