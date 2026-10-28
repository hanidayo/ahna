using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Ahna;

public static class Util
{
	public static readonly JsonSerializerOptions Json = new JsonSerializerOptions(JsonSerializerDefaults.Web)
	{
		WriteIndented = true
	};

	public static string Token()
	{
		return Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
	}

	public static string DeviceName(string value)
	{
		string text = value.Trim().Normalize(NormalizationForm.FormC);
		int length = text.Length;
		bool flag = ((length > 40 || length == 0) ? true : false);
		if (flag || text.Any(char.IsControl))
		{
			throw new ArgumentException("기기 이름은 1~40자로 입력하세요.");
		}
		return text;
	}

	public static void SaveJson<T>(string path, T value)
	{
		string text = path + ".tmp";
		File.WriteAllText(text, JsonSerializer.Serialize(value, Json));
		File.Move(text, path, overwrite: true);
	}

	public static string SafeRelative(string name)
	{
		if (string.IsNullOrWhiteSpace(name) || name.Length > 1000 || Path.IsPathRooted(name))
		{
			throw new ArgumentException("올바르지 않은 파일 경로입니다.");
		}
		name = name.Normalize(NormalizationForm.FormC);
		string[] array = name.Replace('\\', '/').Split('/');
		string[] array2 = array;
		foreach (string text in array2)
		{
			string text2 = text.Split('.')[0].ToUpperInvariant();
			int length = text.Length;
			bool flag = ((length > 180 || length == 0) ? true : false);
			bool flag2 = flag;
			if (!flag2)
			{
				bool flag3 = ((text == "." || text == "..") ? true : false);
				flag2 = flag3;
			}
			bool flag4 = flag2 || text.EndsWith(' ') || text.EndsWith('.') || text.Any((char c) => c < ' ' || "<>:\"|?*".Contains(c));
			if (!flag4)
			{
				bool flag3;
				switch (text2)
				{
				case "CON":
				case "PRN":
				case "AUX":
				case "NUL":
				case "CLOCK$":
					flag3 = true;
					break;
				default:
					flag3 = false;
					break;
				}
				flag4 = flag3;
			}
			if (flag4 || (text2.Length == 4 && (text2.StartsWith("COM") || text2.StartsWith("LPT")) && "123456789¹²³".Contains(text2[3])))
			{
				throw new ArgumentException("Windows에서 저장할 수 없는 파일 이름입니다.");
			}
		}
		return Path.Combine(array);
	}

	public static void NoLinks(string path)
	{
		string text = Path.GetFullPath(path);
		while (!string.IsNullOrEmpty(text))
		{
			if ((File.Exists(text) || Directory.Exists(text)) && File.GetAttributes(text).HasFlag(FileAttributes.ReparsePoint))
			{
				throw new ArgumentException("연결 폴더/심볼릭 링크는 지원하지 않습니다.");
			}
			text = Path.GetDirectoryName(text);
		}
	}
}
