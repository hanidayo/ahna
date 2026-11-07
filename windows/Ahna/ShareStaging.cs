using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Windows.Storage;

namespace Ahna;

internal static class ShareStaging
{
	public static async Task<string> StageAsync(IReadOnlyList<IStorageItem> items, string root, Action<string>? progress = null, CancellationToken cancellation = default(CancellationToken))
	{
		int count = items.Count;
		if ((count > 256 || count == 0) ? true : false)
		{
			throw new ArgumentException("한 번에 공유할 수 있는 항목은 1~256개입니다.");
		}
		Util.NoLinks(root);
		Directory.CreateDirectory(root);
		string directory = Path.Combine(root, Guid.NewGuid().ToString("N"));
		Directory.CreateDirectory(directory);
		File.WriteAllText(Path.Combine(directory, ".ahna-stage"), "1");
		string payload = Path.Combine(directory, "files");
		Directory.CreateDirectory(payload);
		List<string> paths = new List<string>();
		long bytes = 0L;
		int count2 = 0;
		try
		{
			foreach (IStorageItem item in items)
			{
				await CopyItem(item, payload, 0);
			}
			string text = Path.Combine(directory, "request.json");
			Util.SaveJson(text, new SharedFiles(paths.ToArray(), bytes));
			return text;
		}
		catch
		{
			RemoveStage(directory, root);
			throw;
		}
		async Task CopyItem(IStorageItem item, string parent, int depth)
		{
			cancellation.ThrowIfCancellationRequested();
			if (depth > 64 || ++count2 > 10000)
			{
				throw new ArgumentException("공유할 폴더의 항목 수 또는 깊이가 너무 큽니다.");
			}
			if (!string.IsNullOrEmpty(item.Path))
			{
				Util.NoLinks(item.Path);
			}
			string text2 = Util.SafeRelative(item.Name);
			if (text2.Contains(Path.DirectorySeparatorChar))
			{
				throw new ArgumentException("올바르지 않은 공유 파일 이름입니다.");
			}
			string destination = UniqueName(parent, text2);
			if (depth == 0)
			{
				paths.Add(destination);
			}
			if (item is StorageFolder folder)
			{
				Directory.CreateDirectory(destination);
				uint offset = 0u;
				while (true)
				{
					IReadOnlyList<IStorageItem> children = await folder.GetItemsAsync(offset, 100u);
					if (children.Count == 0)
					{
						break;
					}
					foreach (IStorageItem item2 in children)
					{
						await CopyItem(item2, destination, depth + 1);
					}
					offset += (uint)children.Count;
				}
			}
			else
			{
				if (!(item is StorageFile file))
				{
					throw new ArgumentException("파일 또는 폴더 공유만 지원합니다.");
				}
				if ((await file.GetBasicPropertiesAsync()).Size > 4294967296L)
				{
					throw new ArgumentException("파일 한 개는 최대 4 GiB까지 공유할 수 있습니다.");
				}
				progress?.Invoke(file.Name);
				await using Stream input = await file.OpenStreamForReadAsync();
				await using FileStream output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, useAsync: true);
				byte[] buffer = new byte[65536];
				long fileBytes = 0L;
				int num;
				while ((num = await input.ReadAsync(buffer, cancellation)) > 0)
				{
					fileBytes += num;
					if (fileBytes > 4294967296L)
					{
						throw new ArgumentException("파일 한 개는 최대 4 GiB까지 공유할 수 있습니다.");
					}
					await output.WriteAsync(buffer.AsMemory(0, num), cancellation);
				}
				bytes += fileBytes;
			}
		}
	}

	private static string UniqueName(string parent, string name)
	{
		string text = Path.Combine(parent, name);
		int num = 0;
		while (File.Exists(text) || Directory.Exists(text))
		{
			text = Path.Combine(parent, Path.GetFileNameWithoutExtension(name) + $" ({++num})" + Path.GetExtension(name));
		}
		return text;
	}

	public static SharedFiles Load(string manifest, string root)
	{
		string value = Path.GetFullPath(root) + Path.DirectorySeparatorChar;
		string fullPath = Path.GetFullPath(manifest);
		Util.NoLinks(fullPath);
		string directoryName = Path.GetDirectoryName(fullPath);
		if (!fullPath.StartsWith(value, StringComparison.OrdinalIgnoreCase) || Path.GetFileName(fullPath) != "request.json" || !File.Exists(Path.Combine(directoryName, ".ahna-stage")))
		{
			throw new ArgumentException("올바르지 않은 Windows 공유 요청입니다.");
		}
		if (new FileInfo(fullPath).Length > 1048576)
		{
			throw new ArgumentException("공유 요청이 너무 큽니다.");
		}
		SharedFiles sharedFiles = JsonSerializer.Deserialize<SharedFiles>(File.ReadAllText(fullPath), Util.Json) ?? throw new ArgumentException("공유 요청을 읽을 수 없습니다.");
		bool flag = sharedFiles.Paths == null;
		if (!flag)
		{
			int num = sharedFiles.Paths.Length;
			bool flag2 = ((num > 256 || num == 0) ? true : false);
			flag = flag2;
		}
		if (flag)
		{
			throw new ArgumentException("공유 항목이 올바르지 않습니다.");
		}
		string[] paths = sharedFiles.Paths;
		foreach (string path in paths)
		{
			if (!Path.GetFullPath(path).StartsWith(directoryName + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
			{
				throw new ArgumentException("공유 경로가 허용 범위를 벗어났습니다.");
			}
			Util.NoLinks(path);
			if (!File.Exists(path) && !Directory.Exists(path))
			{
				throw new ArgumentException("공유 파일이 더 이상 존재하지 않습니다.");
			}
		}
		return sharedFiles;
	}

	public static void Cleanup(string root)
	{
		if (!Directory.Exists(root))
		{
			return;
		}
		string[] directories = Directory.GetDirectories(root);
		foreach (string text in directories)
		{
			if (Directory.GetLastWriteTimeUtc(text) < DateTime.UtcNow.AddHours(-48.0))
			{
				try
				{
					RemoveStage(text, root);
				}
				catch
				{
				}
			}
		}
	}

	public static void RemoveStage(string directory, string root)
	{
		string fullPath = Path.GetFullPath(directory);
		string value = Path.GetFullPath(root) + Path.DirectorySeparatorChar;
		if (!fullPath.StartsWith(value, StringComparison.OrdinalIgnoreCase) || !File.Exists(Path.Combine(fullPath, ".ahna-stage")))
		{
			return;
		}
		Stack<string> stack = new Stack<string>();
		stack.Push(fullPath);
		while (stack.Count > 0)
		{
			string path = stack.Pop();
			Util.NoLinks(path);
			foreach (string item in Directory.EnumerateFileSystemEntries(path))
			{
				Util.NoLinks(item);
				if (Directory.Exists(item))
				{
					stack.Push(item);
				}
			}
		}
		Directory.Delete(fullPath, recursive: true);
	}
}
