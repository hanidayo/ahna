using System;
using Microsoft.Win32;

namespace Ahna;

// Windows 로그인 시 자동 시작(HKCU Run)과 탐색기 우클릭 메뉴 등록을 한곳에서 처리합니다.
// 트레이와 웹 옵션 화면(/api/admin/options)이 같은 코드를 씁니다.
internal static class WindowsIntegration
{
	private const string RunPath = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";

	private const string RunValue = "Ahna";

	private const string FileMenu = "Software\\Classes\\*\\shell\\Ahna";

	public static TransferServer.IntegrationState Read()
	{
		using RegistryKey? run = Registry.CurrentUser.OpenSubKey(RunPath);
		using RegistryKey? menu = Registry.CurrentUser.OpenSubKey(FileMenu);
		return new TransferServer.IntegrationState(run?.GetValue(RunValue) != null, menu != null);
	}

	public static void Apply(bool startup, bool context)
	{
		string exe = Environment.ProcessPath ?? throw new InvalidOperationException("아나 실행 파일 경로를 찾을 수 없습니다.");
		using (RegistryKey run = Registry.CurrentUser.CreateSubKey(RunPath))
		{
			if (startup)
			{
				run.SetValue(RunValue, "\"" + exe + "\" --background");
			}
			else
			{
				run.DeleteValue(RunValue, throwOnMissingValue: false);
			}
		}
		ExplorerSend.Register(exe, context);
	}
}
