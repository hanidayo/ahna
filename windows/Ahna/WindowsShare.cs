using System;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Windows.ApplicationModel;
using Windows.ApplicationModel.Activation;
using Windows.ApplicationModel.DataTransfer.ShareTarget;

namespace Ahna;

internal static class WindowsShare
{
	public const string PipeName = "Ahna.v1";

	public static string CacheRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Ahna", "WindowsShare");

	public static bool HasPackageIdentity
	{
		get
		{
			uint length = 0u;
			return GetCurrentPackageFullName(ref length, IntPtr.Zero) == 122;
		}
	}

	public static bool IsNotificationActivation
	{
		get
		{
			try
			{
				int result;
				if (HasPackageIdentity)
				{
					IActivatedEventArgs activatedEventArgs = AppInstance.GetActivatedEventArgs();
					result = ((activatedEventArgs != null && activatedEventArgs.Kind == ActivationKind.ToastNotification) ? 1 : 0);
				}
				else
				{
					result = 0;
				}
				return (byte)result != 0;
			}
			catch
			{
				return false;
			}
		}
	}

	[DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
	private static extern int GetCurrentPackageFullName(ref uint length, nint name);

	public static ShareOperation? GetOperation()
	{
		if (!HasPackageIdentity)
		{
			return null;
		}
		IActivatedEventArgs activatedEventArgs = AppInstance.GetActivatedEventArgs();
		try
		{
			string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Ahna", "activation.log");
			Directory.CreateDirectory(Path.GetDirectoryName(path));
			File.AppendAllText(path, $"{DateTimeOffset.Now:O} pid={Environment.ProcessId} activation={activatedEventArgs?.Kind.ToString() ?? "Direct"}\n");
		}
		catch
		{
		}
		if (!(activatedEventArgs is ShareTargetActivatedEventArgs e))
		{
			return null;
		}
		return e.ShareOperation;
	}

	public static async Task ForwardAsync(string[] args, CancellationToken cancellation = default(CancellationToken), string pipeName = "Ahna.v1")
	{
		using NamedPipeClientStream client = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
		await client.ConnectAsync(1500, cancellation);
		using StreamWriter writer = new StreamWriter(client, null, -1, leaveOpen: true)
		{
			AutoFlush = true
		};
		using StreamReader reader = new StreamReader(client, null, detectEncodingFromByteOrderMarks: true, -1, leaveOpen: true);
		await writer.WriteLineAsync(JsonSerializer.Serialize(args).AsMemory(), cancellation);
		using JsonDocument jsonDocument = JsonDocument.Parse((await reader.ReadLineAsync(cancellation).AsTask().WaitAsync(TimeSpan.FromSeconds(5L), cancellation)) ?? "{}");
		if (!jsonDocument.RootElement.TryGetProperty("accepted", out var value) || !value.GetBoolean())
		{
			throw new IOException("아나가 공유 요청을 받지 못했습니다.");
		}
	}

	public static async Task DeliverAsync(string manifest, CancellationToken cancellation)
	{
		bool flag = Mutex.TryOpenExisting("Local\\Ahna.v1", out Mutex result);
		result?.Dispose();
		if (!flag)
		{
			Process.Start(new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "Ahna.exe"))
			{
				UseShellExecute = false,
				CreateNoWindow = true,
				ArgumentList = { "--background" }
			});
		}
		DateTime until = DateTime.UtcNow.AddSeconds(35.0);
		while (true)
		{
			cancellation.ThrowIfCancellationRequested();
			try
			{
				await ForwardAsync(new string[2] { "--shared-manifest", manifest }, cancellation);
				break;
			}
			catch (Exception ex) when (((ex is TimeoutException || ex is IOException) ? true : false) && DateTime.UtcNow < until)
			{
				await Task.Delay(300, cancellation);
			}
		}
	}
}
