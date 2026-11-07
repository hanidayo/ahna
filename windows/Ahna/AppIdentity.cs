using System;
using System.IO;
using System.Runtime.InteropServices;

namespace Ahna;

/// <summary>
/// Windows 알림(트레이 풍선 → 알림 센터)을 누르면 Windows는 앱 ID(AppUserModelID)로 앱을 찾아 엽니다.
/// 앱 ID가 없으면 비슷한 다른 앱(예: 같은 이름 계열의 다른 설치본)이 열릴 수 있어, 실행할 때 이 프로세스와
/// 시작 메뉴 바로가기에 고유한 앱 ID를 붙입니다.
/// </summary>
internal static class AppIdentity
{
	public static string Id => "Hanidayo." + Path.GetFileNameWithoutExtension(Environment.ProcessPath ?? "아나");

	public static void Apply()
	{
		try { SetCurrentProcessExplicitAppUserModelID(Id); } catch { }
		try { StampShortcut(); } catch { }
	}

	private static void StampShortcut()
	{
		string exe = Environment.ProcessPath ?? "";
		if (exe.Length == 0) return;
		string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "아나.lnk");
		if (!File.Exists(path)) return;
		var link = (IShellLinkW)new CShellLink();
		var file = (IPersistFile)link;
		file.Load(path, 2);
		var target = new char[1024];
		link.GetPath(target, target.Length, IntPtr.Zero, 0);
		if (!string.Equals(new string(target).TrimEnd('\0'), exe, StringComparison.OrdinalIgnoreCase)) return;
		var store = (IPropertyStore)link;
		var key = new PropertyKey { FormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), PropertyId = 5 };
		store.GetValue(ref key, out PropVariant current);
		string? existing = current.Type == 31 ? Marshal.PtrToStringUni(current.Pointer) : null;
		PropVariantClear(ref current);
		if (existing == Id) return;
		var value = new PropVariant { Type = 31, Pointer = Marshal.StringToCoTaskMemUni(Id) };
		try { store.SetValue(ref key, ref value); store.Commit(); }
		finally { PropVariantClear(ref value); }
		file.Save(path, true);
	}

	[DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
	private static extern void SetCurrentProcessExplicitAppUserModelID(string appId);

	[DllImport("ole32.dll")]
	private static extern int PropVariantClear(ref PropVariant value);

	[ComImport, Guid("00021401-0000-0000-C000-000000000046")]
	private class CShellLink { }

	[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
	private interface IShellLinkW
	{
		void GetPath([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] file, int max, IntPtr findData, uint flags);
	}

	[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("0000010b-0000-0000-C000-000000000046")]
	private interface IPersistFile
	{
		void GetClassID(out Guid classId);
		[PreserveSig] int IsDirty();
		void Load([MarshalAs(UnmanagedType.LPWStr)] string file, uint mode);
		void Save([MarshalAs(UnmanagedType.LPWStr)] string file, [MarshalAs(UnmanagedType.Bool)] bool remember);
	}

	[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
	private interface IPropertyStore
	{
		void GetCount(out uint count);
		void GetAt(uint index, out PropertyKey key);
		void GetValue(ref PropertyKey key, out PropVariant value);
		void SetValue(ref PropertyKey key, ref PropVariant value);
		void Commit();
	}

	[StructLayout(LayoutKind.Sequential, Pack = 4)]
	private struct PropertyKey
	{
		public Guid FormatId;
		public uint PropertyId;
	}

	[StructLayout(LayoutKind.Explicit, Size = 24)]
	private struct PropVariant
	{
		[FieldOffset(0)] public ushort Type;
		[FieldOffset(8)] public IntPtr Pointer;
	}
}
