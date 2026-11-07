using System;
using System.Runtime.InteropServices;

namespace Ahna;

[ComVisible(true)]
[Guid("00000001-0000-0000-C000-000000000046")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IExplorerClassFactory
{
	[PreserveSig]
	int CreateInstance(nint outer, ref Guid iid, out nint instance);

	[PreserveSig]
	int LockServer([MarshalAs(UnmanagedType.Bool)] bool locked);
}
