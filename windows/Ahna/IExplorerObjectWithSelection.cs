using System;
using System.Runtime.InteropServices;

namespace Ahna;

[ComVisible(true)]
[Guid("1C9CD5BB-98E9-4491-A60F-31AACC72B83C")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IExplorerObjectWithSelection
{
	[PreserveSig]
	int SetSelection(IShellItemArray selection);

	[PreserveSig]
	int GetSelection(ref Guid iid, out nint selection);
}
