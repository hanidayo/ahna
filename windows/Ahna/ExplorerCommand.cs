using System;
using System.Runtime.InteropServices;

namespace Ahna;

[ComVisible(true)]
[ClassInterface(ClassInterfaceType.None)]
public sealed class ExplorerCommand(Action<string[]> deliver) : IExplorerExecuteCommand, IExplorerObjectWithSelection
{
	private IShellItemArray? selection;

	public int SetSelection(IShellItemArray value)
	{
		selection = value;
		return 0;
	}

	public int GetSelection(ref Guid iid, out nint value)
	{
		value = IntPtr.Zero;
		if (selection == null)
		{
			return -2147467259;
		}
		nint iUnknownForObject = Marshal.GetIUnknownForObject(selection);
		try
		{
			return Marshal.QueryInterface(iUnknownForObject, in iid, out value);
		}
		finally
		{
			Marshal.Release(iUnknownForObject);
		}
	}

	public int SetKeyState(uint state)
	{
		return 0;
	}

	public int SetParameters(string? parameters)
	{
		return 0;
	}

	public int SetPosition(NativePoint point)
	{
		return 0;
	}

	public int SetShowWindow(int show)
	{
		return 0;
	}

	public int SetNoShowUI(bool noUI)
	{
		return 0;
	}

	public int SetDirectory(string? directory)
	{
		return 0;
	}

	public int Execute()
	{
		try
		{
			if (selection == null)
			{
				return -2147024809;
			}
			deliver(ExplorerSend.ReadSelection(selection));
			return 0;
		}
		catch (Exception e)
		{
			return Marshal.GetHRForException(e);
		}
	}
}
