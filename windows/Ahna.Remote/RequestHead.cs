namespace Ahna.Remote;

public sealed record RequestHead(string Method, string Path, long Length, string? Cookie, string? ContentType);
