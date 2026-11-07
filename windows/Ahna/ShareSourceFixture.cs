using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using WinRT;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace Ahna;

internal sealed class ShareSourceFixture : Form
{
	[ComImport]
	[Guid("3A3DCD6C-3EAB-43DC-BCDE-45671CE800C8")]
	[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
	private interface IDataTransferManagerInterop
	{
		nint GetForWindow(nint window, in Guid iid);

		void ShowShareUIForWindow(nint window);
	}

	private DataTransferManager? manager;

	private readonly string log = Path.Combine(AppContext.BaseDirectory, "share-source.log");

	private void Trace(string message)
	{
		try
		{
			File.AppendAllText(log, $"{DateTimeOffset.Now:O} {message}\n");
		}
		catch
		{
		}
	}

	public ShareSourceFixture(string file)
	{
		ShareSourceFixture shareSourceFixture = this;
		Text = "아나 · 공유 검증용 파일";
		Icon = Program.AppIcon;
		Width = 420;
		Height = 210;
		StartPosition = FormStartPosition.CenterScreen;
		Label label = new Label
		{
			Left = 20,
			Top = 22,
			Width = 360,
			Height = 55,
			Text = "합성 시험 파일로 Windows 공유를 검증합니다.\n" + Path.GetFileName(file)
		};
		Button button = new Button
		{
			Left = 20,
			Top = 90,
			Width = 360,
			Height = 40,
			Text = "Windows 공유 열기"
		};
		button.Enabled = false;
		Controls.AddRange(label, button);
		Shown += async (object? _, EventArgs _) =>
		{
			try
			{
				StorageFile storage = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(file));
				IDataTransferManagerInterop interop = DataTransferManager.As<IDataTransferManagerInterop>();
				Guid iid = new Guid("A5CAEE9B-8708-49D1-8D36-67D25A8DA00C");
				nint forWindow = interop.GetForWindow(shareSourceFixture.Handle, in iid);
				try
				{
					shareSourceFixture.manager = MarshalInterface<DataTransferManager>.FromAbi(forWindow);
				}
				finally
				{
					Marshal.Release(forWindow);
				}
				shareSourceFixture.manager.DataRequested += (DataTransferManager dataTransferManager, DataRequestedEventArgs e) =>
				{
					shareSourceFixture.Trace("data-requested");
					e.Request.Data.Properties.Title = "아나 파일 전송 검증";
					e.Request.Data.SetStorageItems(new IStorageItem[1] { storage });
					e.Request.Data.RequestedOperation = DataPackageOperation.Copy;
				};
				button.Enabled = true;
				button.Focus();
				button.Click += (object? obj, EventArgs e) =>
				{
					ShowShare();
					void ShowShare()
					{
						try
						{
							shareSourceFixture.Trace("show-requested");
							interop.ShowShareUIForWindow(shareSourceFixture.Handle);
							shareSourceFixture.Trace("show-returned");
							label.Text = "Windows 공유 호출 완료 · 공유 창을 확인해 주세요.";
						}
						catch (Exception ex2)
						{
							shareSourceFixture.Trace($"show-failed {ex2.GetType().Name} 0x{ex2.HResult:X8}");
							label.Text = $"공유 열기 실패 (0x{ex2.HResult:X8})\n{ex2.Message}";
						}
					}
				};
			}
			catch (Exception ex)
			{
				shareSourceFixture.Trace($"setup-failed {ex.GetType().Name} 0x{ex.HResult:X8}");
				label.Text = ex.Message;
			}
		};
	}
}
