using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Windows.ApplicationModel.DataTransfer;
using Windows.ApplicationModel.DataTransfer.ShareTarget;

namespace Ahna;

internal sealed class WindowsShareForm : Form
{
	private readonly ShareOperation operation;

	private readonly CancellationTokenSource cancel = new CancellationTokenSource();

	private readonly Label status;

	private bool finished;

	public WindowsShareForm(ShareOperation operation)
	{
		this.operation = operation;
		Text = "아나 · Windows 공유";
		Icon = Program.AppIcon;
		Width = 490;
		Height = 230;
		StartPosition = FormStartPosition.CenterScreen;
		FormBorderStyle = FormBorderStyle.FixedDialog;
		MaximizeBox = false;
		status = new Label
		{
			Left = 24,
			Top = 25,
			Width = 425,
			Height = 65,
			Text = "공유한 파일을 준비하고 있습니다…"
		};
		ProgressBar progressBar = new ProgressBar
		{
			Left = 24,
			Top = 100,
			Width = 420,
			Height = 8,
			Style = ProgressBarStyle.Marquee
		};
		Button button = new Button
		{
			Left = 335,
			Top = 130,
			Width = 110,
			Height = 32,
			Text = "취소"
		};
		button.Click += (object? _, EventArgs _) =>
		{
			cancel.Cancel();
		};
		Controls.AddRange(status, progressBar, button);
		FormClosing += (object? _, FormClosingEventArgs e) =>
		{
			// 처음 닫으면 취소를 요청하고, 그래도 안 끝나면 두 번째에는 바로 닫습니다(창이 닫히지 않던 문제).
			if (!finished && !cancel.IsCancellationRequested)
			{
				e.Cancel = true;
				cancel.Cancel();
				status.Text = "취소하는 중입니다… 한 번 더 닫으면 바로 닫힙니다.";
			}
		};
		Shown += async (object? _, EventArgs _) =>
		{
			await ReceiveAsync();
		};
	}

	private async Task ReceiveAsync()
	{
		string manifest = null;
		bool accepted = false;
		try
		{
			operation.ReportStarted();
			if (!operation.Data.Contains(StandardDataFormats.StorageItems))
			{
				throw new ArgumentException("Windows 공유에서는 파일과 폴더만 지원합니다.");
			}
			manifest = await ShareStaging.StageAsync(await operation.Data.GetStorageItemsAsync(), WindowsShare.CacheRoot, (string name) =>
			{
				status.Text = "준비 중 · " + name;
			}, cancel.Token);
			operation.ReportDataRetrieved();
			status.Text = "아나에서 받을 기기를 선택해 주세요.";
			await WindowsShare.DeliverAsync(manifest, cancel.Token);
			accepted = true;
			operation.ReportCompleted();
		}
		catch (OperationCanceledException)
		{
			try
			{
				operation.ReportError("공유를 취소했습니다.");
			}
			catch
			{
			}
		}
		catch (Exception ex2)
		{
			try
			{
				operation.ReportError(ex2.Message);
			}
			catch
			{
			}
			MessageBox.Show(this, ex2.Message, "아나 공유 실패");
		}
		finally
		{
			if (!accepted && manifest != null)
			{
				try
				{
					ShareStaging.RemoveStage(Path.GetDirectoryName(manifest), WindowsShare.CacheRoot);
				}
				catch
				{
				}
			}
			finished = true;
			Close();
		}
	}
}
