using System;
using System.Runtime.InteropServices;

namespace Ahna;

[ComImport]
[Guid("B63EA76D-1F85-456F-A19C-48159EFA858B")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IShellItemArray
{
	[PreserveSig]
	int BindToHandler(nint context, ref Guid handler, ref Guid iid, out nint result);

	[PreserveSig]
	int GetPropertyStore(int flags, ref Guid iid, out nint result);

	[PreserveSig]
	int GetPropertyDescriptionList(nint key, ref Guid iid, out nint result);

	[PreserveSig]
	int GetAttributes(uint flags, uint mask, out uint attributes);

	[PreserveSig]
	int GetCount(out uint count);

	[PreserveSig]
	int GetItemAt(uint index, out IShellItem item);

	[PreserveSig]
	int EnumItems(out nint items);
}
