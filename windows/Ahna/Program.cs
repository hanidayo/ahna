using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Windows.ApplicationModel.DataTransfer.ShareTarget;

namespace Ahna;

internal static class Program
{
	private static readonly Lazy<Icon> appIcon = new Lazy<Icon>(() =>
	{
		using Stream stream = typeof(Program).Assembly.GetManifestResourceStream("Ahna.AppIcon") ?? throw new InvalidOperationException("App icon resource is missing.");
		using Icon icon = new Icon(stream, 32, 32);
		return (Icon)icon.Clone();
	});

	public static Icon AppIcon => appIcon.Value;

	[STAThread]
	private static int Main(string[] args)
	{
		ApplicationConfiguration.Initialize();
		AppIdentity.Apply();
		if (args.Contains("--explorer-command"))
		{
			return ExplorerSend.Run();
		}
		if (args.Contains("--register-explorer"))
		{
			ExplorerSend.Register(Environment.ProcessPath, enabled: true);
			return 0;
		}
		args = NormalizeActivationArgs(args, WindowsShare.IsNotificationActivation, alreadyRunning: false);
		int num2 = Array.IndexOf(args, "--share-source-test");
		if (num2 >= 0)
		{
			using (ShareSourceFixture mainForm2 = new ShareSourceFixture(args[num2 + 1]))
			{
				Application.Run(mainForm2);
				return 0;
			}
		}
		if (args.Contains("--self-test"))
		{
			return SelfTest.RunAsync(args.SkipWhile((string a) => a != "--self-test").Skip(1).FirstOrDefault()).GetAwaiter().GetResult();
		}
		int num3 = Array.IndexOf(args, "--diagnostics");
		if (num3 >= 0)
		{
			Util.SaveJson(args[num3 + 1], new
			{
				version = Ahna.Update.UpdateService.CurrentText,
				executable = Environment.ProcessPath,
				hasPackageIdentity = WindowsShare.HasPackageIdentity,
				shareActivation = ((object)WindowsShare.GetOperation() != null)
			});
			return 0;
		}
		if (!args.Contains("--ui-test"))
		{
			ShareOperation operation = WindowsShare.GetOperation();
			if ((object)operation != null)
			{
				using (WindowsShareForm mainForm3 = new WindowsShareForm(operation))
				{
					Application.Run(mainForm3);
					return 0;
				}
			}
		}
		bool flag = args.Contains("--ui-test");
		bool createdNew;
		using (new Mutex(initiallyOwned: true, flag ? "Local\\Ahna.UITest" : "Local\\Ahna.v1", out createdNew))
		{
			if (!createdNew)
			{
				try
				{
					WindowsShare.ForwardAsync(NormalizeActivationArgs(args, notification: false, alreadyRunning: true)).GetAwaiter().GetResult();
				}
				catch
				{
					MessageBox.Show("아나에 연결할 수 없습니다. 트레이에서 종료한 뒤 다시 실행하세요.", "아나");
				}
				return 0;
			}
			try
			{
				using TrayContext context = new TrayContext(args);
				Application.Run(context);
				return 0;
			}
			catch (Exception ex)
			{
				MessageBox.Show("아나를 시작하지 못했습니다. 45851 포트가 사용 중인지 확인하세요.\n\n" + ex.Message, "아나");
				return 1;
			}
		}
	}

	public static void Open(string value)
	{
		Process.Start(new ProcessStartInfo(value)
		{
			UseShellExecute = true
		});
	}

	[DllImport("user32.dll")]
	private static extern bool ShowWindow(nint window, int command);

	internal static void Reveal(Form form)
	{
		ShowWindow(form.Handle, 5);
		form.Activate();
	}

	internal static string[] NormalizeActivationArgs(string[] args, bool notification, bool alreadyRunning)
	{
		if (!notification)
		{
			if (!alreadyRunning || args.Length != 0)
			{
				return args;
			}
			return new string[1] { "--background" };
		}
		return new string[1] { "--notification" };
	}
}
