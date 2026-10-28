using System;
using System.Runtime.InteropServices;

namespace Ahna;

[ComImport]
[Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IShellItem
{
	[PreserveSig]
	int BindToHandler(nint context, ref Guid handler, ref Guid iid, out nint result);

	[PreserveSig]
	int GetParent(out IShellItem parent);

	[PreserveSig]
	int GetDisplayName(uint flags, out nint name);

	[PreserveSig]
	int GetAttributes(uint mask, out uint attributes);

	[PreserveSig]
	int Compare(IShellItem other, uint hint, out int order);
}
