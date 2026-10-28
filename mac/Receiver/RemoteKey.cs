using System.Security.Cryptography;
using System.Text;
namespace Ahna;

// The containing Mac app obtains this app's random key from its own Keychain
// item and passes it through an anonymous pipe, never command-line arguments.
internal static class RemoteKey
{
    static byte[]? key;
    public static void Initialize(string encoded)
    {
        var decoded=Convert.FromBase64String(encoded);
        if(decoded.Length!=32)throw new ArgumentException("Invalid receiver encryption key");
        key=decoded;
    }
    public static string Protect(string value)
    {
        var nonce=RandomNumberGenerator.GetBytes(12);
        var clear=Encoding.UTF8.GetBytes(value);var encrypted=new byte[clear.Length];var tag=new byte[16];
        using var aes=new AesGcm(key??throw new InvalidOperationException("Key not initialized"),16);
        aes.Encrypt(nonce,clear,encrypted,tag);
        return "mac1:"+Convert.ToBase64String(nonce.Concat(tag).Concat(encrypted).ToArray());
    }
    public static string Unprotect(string value)
    {
        if(value.Length==0)return "";
        if(!value.StartsWith("mac1:"))throw new CryptographicException("Unrecognized stored secret");
        var data=Convert.FromBase64String(value[5..]);
        if(data.Length<28)throw new CryptographicException("Incomplete stored secret");
        var clear=new byte[data.Length-28];
        using var aes=new AesGcm(key??throw new InvalidOperationException("Key not initialized"),16);
        aes.Decrypt(data.AsSpan(0,12),data.AsSpan(28),data.AsSpan(12,16),clear);
        return Encoding.UTF8.GetString(clear);
    }
}
