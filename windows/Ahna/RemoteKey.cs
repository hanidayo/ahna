using System;
using System.Security.Cryptography;
using System.Text;

namespace Ahna;

internal static class RemoteKey
{
	public static string Protect(string key)
	{
		return Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(key), null, DataProtectionScope.CurrentUser));
	}

	public static string Unprotect(string key)
	{
		if (key.Length != 0)
		{
			return Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(key), null, DataProtectionScope.CurrentUser));
		}
		return "";
	}
}
