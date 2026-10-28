using System.Runtime.InteropServices;

namespace Ahna;

[ComVisible(true)]
[Guid("7F9185B0-CB92-43C5-80A9-92277A4F7B54")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IExplorerExecuteCommand
{
	[PreserveSig]
	int SetKeyState(uint state);

	[PreserveSig]
	int SetParameters([MarshalAs(UnmanagedType.LPWStr)] string? parameters);

	[PreserveSig]
	int SetPosition(NativePoint point);

	[PreserveSig]
	int SetShowWindow(int show);

	[PreserveSig]
	int SetNoShowUI([MarshalAs(UnmanagedType.Bool)] bool noUI);

	[PreserveSig]
	int SetDirectory([MarshalAs(UnmanagedType.LPWStr)] string? directory);

	[PreserveSig]
	int Execute();
}
