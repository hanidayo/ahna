using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Ahna;

internal static class ExplorerSend
{
	private sealed class CommandServerContext : ApplicationContext
	{
		private readonly ExplorerClassFactory factory;

		private readonly System.Windows.Forms.Timer idle = new System.Windows.Forms.Timer
		{
			Interval = 60000
		};

		private readonly uint cookie;

		private int active;

		public CommandServerContext()
		{
			factory = new ExplorerClassFactory(Deliver);
			Guid clsid = new Guid("{5B8E2A61-3D47-4C19-A0F2-9E64C7D1B3A8}");
			Marshal.ThrowExceptionForHR(CoRegisterClassObject(ref clsid, factory, 4u, 1u, out cookie));
			idle.Tick += (object? _, EventArgs _) =>
			{
				if (active == 0)
				{
					ExitThread();
				}
			};
			idle.Start();
		}

		private async void Deliver(string[] paths)
		{
			active++;
			idle.Stop();
			try
			{
				using CancellationTokenSource cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(35L));
				if (!Mutex.TryOpenExisting("Local\\Ahna.v1", out Mutex result))
				{
					Process.Start(new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "Ahna.exe"))
					{
						UseShellExecute = false,
						CreateNoWindow = true,
						ArgumentList = { "--background" }
					});
				}
				result?.Dispose();
				while (true)
				{
					try
					{
						string text = "--send";
						int num = 0;
						string[] array = new string[1 + paths.Length];
						array[num] = text;
						num++;
						ReadOnlySpan<string> readOnlySpan = new ReadOnlySpan<string>(paths);
						readOnlySpan.CopyTo(new Span<string>(array).Slice(num, readOnlySpan.Length));
						_ = num + readOnlySpan.Length;
						await WindowsShare.ForwardAsync(array, cancellation.Token);
					}
					catch (Exception ex) when (((ex is TimeoutException || ex is IOException) ? true : false) && !cancellation.IsCancellationRequested)
					{
						await Task.Delay(250, cancellation.Token);
						continue;
					}
					break;
				}
			}
			catch (Exception ex2)
			{
				MessageBox.Show("선택한 항목을 아나로 전달하지 못했습니다.\n" + ex2.Message, "아나");
			}
			finally
			{
				active--;
				idle.Start();
			}
		}

		protected override void Dispose(bool disposing)
		{
			if (disposing)
			{
				idle.Dispose();
				CoRevokeClassObject(cookie);
				GC.KeepAlive(factory);
			}
			base.Dispose(disposing);
		}
	}

	public const string ClassId = "{5B8E2A61-3D47-4C19-A0F2-9E64C7D1B3A8}";

	public const string ClassPath = "Software\\Classes\\CLSID\\{5B8E2A61-3D47-4C19-A0F2-9E64C7D1B3A8}";

	public static readonly string[] VerbPaths = new string[2] { "Software\\Classes\\*\\shell\\Ahna", "Software\\Classes\\Directory\\shell\\Ahna" };

	public static void Register(string exe, bool enabled)
	{
		string[] verbPaths = VerbPaths;
		foreach (string subkey in verbPaths)
		{
			if (!enabled)
			{
				Registry.CurrentUser.DeleteSubKeyTree(subkey, throwOnMissingSubKey: false);
				continue;
			}
			using RegistryKey registryKey = Registry.CurrentUser.CreateSubKey(subkey);
			registryKey.SetValue("", "아나로 보내기");
			registryKey.SetValue("Icon", exe);
			registryKey.SetValue("MultiSelectModel", "Player");
			using RegistryKey registryKey2 = registryKey.CreateSubKey("command");
			registryKey2.SetValue("", "");
			registryKey2.SetValue("DelegateExecute", "{5B8E2A61-3D47-4C19-A0F2-9E64C7D1B3A8}");
		}
		if (enabled)
		{
			using RegistryKey registryKey3 = Registry.CurrentUser.CreateSubKey("Software\\Classes\\CLSID\\{5B8E2A61-3D47-4C19-A0F2-9E64C7D1B3A8}\\LocalServer32");
			registryKey3.SetValue("", "\"" + exe + "\" --explorer-command");
		}
		else
		{
			Registry.CurrentUser.DeleteSubKeyTree("Software\\Classes\\CLSID\\{5B8E2A61-3D47-4C19-A0F2-9E64C7D1B3A8}", throwOnMissingSubKey: false);
		}
		SHChangeNotify(134217728u, 0u, IntPtr.Zero, IntPtr.Zero);
	}

	public static string[] ReadSelection(IShellItemArray selection)
	{
		Marshal.ThrowExceptionForHR(selection.GetCount(out var count));
		if ((count > 256 || count == 0) ? true : false)
		{
			throw new ArgumentException("한 번에 보낼 항목은 1~256개를 선택하세요.");
		}
		List<string> list = new List<string>();
		for (uint num = 0u; num < count; num++)
		{
			Marshal.ThrowExceptionForHR(selection.GetItemAt(num, out IShellItem item));
			try
			{
				Marshal.ThrowExceptionForHR(item.GetDisplayName(2147844096u, out var name));
				try
				{
					string text = Marshal.PtrToStringUni(name);
					if (string.IsNullOrEmpty(text) || !Path.IsPathFullyQualified(text) || (!File.Exists(text) && !Directory.Exists(text)))
					{
						throw new ArgumentException("보낼 파일이나 폴더를 찾을 수 없습니다.");
					}
					list.Add(text);
				}
				finally
				{
					Marshal.FreeCoTaskMem(name);
				}
			}
			finally
			{
				if (Marshal.IsComObject(item))
				{
					Marshal.ReleaseComObject(item);
				}
			}
		}
		return list.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
	}

	public static int Run()
	{
		Application.OleRequired();
		using CommandServerContext context = new CommandServerContext();
		Application.Run(context);
		return 0;
	}

	[DllImport("ole32.dll")]
	private static extern int CoRegisterClassObject(ref Guid clsid, [MarshalAs(UnmanagedType.Interface)] IExplorerClassFactory factory, uint context, uint flags, out uint cookie);

	[DllImport("ole32.dll")]
	private static extern int CoRevokeClassObject(uint cookie);

	[DllImport("shell32.dll")]
	private static extern void SHChangeNotify(uint eventId, uint flags, nint item1, nint item2);
}
