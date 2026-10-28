using System;
using System.Runtime.InteropServices;

namespace Ahna;

[ComVisible(true)]
[ClassInterface(ClassInterfaceType.None)]
public sealed class ExplorerClassFactory(Action<string[]> deliver) : IExplorerClassFactory
{
	public int CreateInstance(nint outer, ref Guid iid, out nint instance)
	{
		instance = IntPtr.Zero;
		if (outer != IntPtr.Zero)
		{
			return -2147221232;
		}
		nint iUnknownForObject = Marshal.GetIUnknownForObject(new ExplorerCommand(deliver));
		try
		{
			return Marshal.QueryInterface(iUnknownForObject, in iid, out instance);
		}
		finally
		{
			Marshal.Release(iUnknownForObject);
		}
	}

	public int LockServer(bool locked)
	{
		return 0;
	}
}
