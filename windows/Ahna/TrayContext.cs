using System;
using System.Drawing;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace Ahna;

internal sealed class TrayContext : ApplicationContext
{
	private readonly TransferServer server;

	private readonly NotifyIcon tray;

	private readonly Control dispatcher = new Control();

	private readonly CancellationTokenSource stop = new CancellationTokenSource();

	private readonly Task pipeTask;

	private readonly string? testLog;

	private bool sending;

	private SendDialog? sendDialog;

	// 끌어다 놓아 [옵션에서 추가한 기기]로 보내는 중인 임시 폴더 (보내기가 끝나면 지움)
	private string? outboundDropFolder;

	private bool pickerOpen;

	// 안내용 알림. 알림을 눌렀을 때 업데이트 설치 같은 이전 동작이 실행되지 않도록 표시를 지웁니다.
	private void ShowTip(string title, string text, ToolTipIcon icon)
	{
		nearbyNotification = false;
		updateNotification = false;
		infoNotification = false;
		clipboardNotification = false;
		noticeNotification = false;
		tray.ShowBalloonTip(5000, title, text, icon);
	}

	private bool clipboardNotification;

	// 공지 알림을 누르면 아나 창을 열어 공지를 보여 줍니다.
	private bool noticeNotification;

	// 근처 기기 · QR (1.2): Bluetooth LE 근처 기기, QR 창, 받기 확인 창
	private readonly NearbyService nearby;

	private QrForm? qrForm;

	private NearbyRequestForm? requestForm;

	private bool nearbyNotification;

	private ClipboardForm? clipboardForm;

	private readonly OutboundDevices outbound;

	private bool balloonVisible;

	private DateTimeOffset lastReceivedFolderOpen = DateTimeOffset.MinValue;

	private Ahna.Update.UpdateService? updater;

	private bool updateNotification;

	private bool infoNotification;

	public TrayContext(string[] args)
	{
		TrayContext trayContext = this;
		_ = dispatcher.Handle;
		int testIndex = Array.IndexOf(args, "--ui-test");
		bool flag = testIndex >= 0;
		if (testIndex < 0)
		{
			testIndex = Array.IndexOf(args, "--integration-test");
		}
		string data = ((testIndex >= 0) ? Path.GetFullPath(args[testIndex + 1]) : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Ahna"));
		testLog = ((testIndex >= 0) ? Path.Combine(data, "ui-events.log") : null);
		if (testIndex < 0)
		{
			try
			{
				ShareStaging.Cleanup(WindowsShare.CacheRoot);
			}
			catch
			{
			}
		}
		server = new TransferServer(data, flag ? 45852 : 45851);
		server.AppVersion = Ahna.Update.UpdateService.CurrentText;
		outbound = new OutboundDevices(server, data);
		nearby = new NearbyService(server, data);
		Task.Run(() => trayContext.server.StartAsync(Path.Combine(AppContext.BaseDirectory, "wwwroot"))).GetAwaiter().GetResult();
		if (testIndex >= 0)
		{
			server.SaveSettings(new Preferences
			{
				SavePath = Path.Combine(data, "received")
			});
			Util.SaveJson(Path.Combine(data, "ui-test-bootstrap.json"), new { server.OwnerUrl, server.Pin });
		}
		tray = new NotifyIcon
		{
			Icon = Program.AppIcon,
			Text = "아나 " + Ahna.Update.UpdateService.CurrentText + " · 파일 전송",
			Visible = true
		};
		ContextMenuStrip contextMenuStrip = new ContextMenuStrip
		{
			Items = 
			{
				{
					"아나 열기",
					(Image?)null,
					(EventHandler?)((object? _, EventArgs _) =>
					{
						Program.Open(trayContext.server.OwnerUrl);
					})
				},
				{
					"파일 / 폴더 보내기",
					(Image?)null,
					(EventHandler?)(async (object? _, EventArgs _) =>
					{
						await trayContext.SendDialogAsync(Array.Empty<string>(), null);
					})
				},
				{
					"서버 기기 추가 / 연결",
					(Image?)null,
					(EventHandler?)((object? _, EventArgs _) =>
					{
						trayContext.ShowSettings();
					})
				},
				{
					"QR로 보내기 / 받기",
					(Image?)null,
					(EventHandler?)((object? _, EventArgs _) =>
					{
						trayContext.ShowQr(receive: false);
					})
				},
				{
					"클립보드 보내기 / 받은 글자",
					(Image?)null,
					(EventHandler?)((object? _, EventArgs _) =>
					{
						trayContext.ShowClipboard();
					})
				},
				{
					"받은 폴더 열기",
					(Image?)null,
					(EventHandler?)((object? _, EventArgs _) =>
					{
						Directory.CreateDirectory(trayContext.server.Settings.SavePath);
						Program.Open(trayContext.server.Settings.SavePath);
					})
				},
				{
					"옵션 · 저장 폴더 변경",
					(Image?)null,
					(EventHandler?)((object? _, EventArgs _) =>
					{
						trayContext.ShowSettings();
					})
				},
				{
					"업데이트 확인",
					(Image?)null,
					(EventHandler?)(async (object? _, EventArgs _) =>
					{
						if (trayContext.updater != null)
						{
							if (trayContext.updater.Pending is { FullInstallRequired: true } full) Ahna.Update.UpdateService.Open(full.NotesUrl ?? Ahna.Update.UpdateService.ReleasesPage);
							else if (trayContext.updater.Pending != null && MessageBox.Show("아나 v" + trayContext.updater.Pending.Version + "을(를) 설치하고 다시 시작할까요?", "아나 업데이트", MessageBoxButtons.YesNo) == DialogResult.Yes) await trayContext.updater.InstallPendingAsync();
							else await trayContext.updater.CheckAsync(userInitiated: true);
						}
					})
				},
				(ToolStripItem)new ToolStripSeparator(),
				{
					"종료",
					(Image?)null,
					(EventHandler?)((object? _, EventArgs _) =>
					{
						trayContext.ExitThread();
					})
				}
			}
		};
		foreach (ToolStripItem item in contextMenuStrip.Items) if(item is ToolStripMenuItem) item.Padding = new Padding(4, 6, 4, 6);
		tray.ContextMenuStrip = contextMenuStrip;
		if (testIndex >= 0)
		{
			File.AppendAllText(Path.Combine(data, "ui-events.log"), "tray-ready\n");
		}
		else
		{
			updater = new Ahna.Update.UpdateService
			{
				IsBusy = () => trayContext.sending,
				RequestExit = () => trayContext.dispatcher.BeginInvoke(() => trayContext.ExitThread()),
				Notify = (string title, string text, bool installOnClick) => trayContext.dispatcher.BeginInvoke(() =>
				{
					trayContext.nearbyNotification = false;
					trayContext.updateNotification = installOnClick;
					trayContext.infoNotification = !installOnClick;
					trayContext.clipboardNotification = false;
					trayContext.noticeNotification = false;
					trayContext.tray.ShowBalloonTip(installOnClick ? 15000 : 5000, title, text, ToolTipIcon.Info);
				})
			};
			updater.Start();
		}
		DateTimeOffset lastNotificationClick = DateTimeOffset.MinValue;
		System.Windows.Forms.Timer openFromTray = new System.Windows.Forms.Timer
		{
			Interval = SystemInformation.DoubleClickTime + 100
		};
		openFromTray.Tick += (object? _, EventArgs _) =>
		{
			openFromTray.Stop();
			if (DateTimeOffset.UtcNow - lastNotificationClick > TimeSpan.FromMilliseconds(SystemInformation.DoubleClickTime + 200))
			{
				Program.Open(trayContext.server.OwnerUrl);
			}
		};
		tray.Disposed += (object? _, EventArgs _) =>
		{
			openFromTray.Dispose();
		};
		tray.BalloonTipShown += (object? _, EventArgs _) =>
		{
			trayContext.balloonVisible = true;
		};
		tray.BalloonTipClosed += (object? _, EventArgs _) =>
		{
			trayContext.balloonVisible = false;
		};
		// 트레이 아이콘을 두 번 누르면 아나 기본 화면(웹)을 엽니다.
		// 알림이 떠 있을 때만, 알림 클릭과 겹치지 않도록 잠깐 기다렸다가 엽니다.
		tray.MouseDoubleClick += (object? _, MouseEventArgs e) =>
		{
			if (e.Button != MouseButtons.Left)
			{
				return;
			}
			openFromTray.Stop();
			if (trayContext.balloonVisible)
			{
				openFromTray.Start();
			}
			else
			{
				Program.Open(trayContext.server.OwnerUrl);
			}
		};
		tray.BalloonTipClicked += async (object? _, EventArgs _) =>
		{
			trayContext.balloonVisible = false;
			lastNotificationClick = DateTimeOffset.UtcNow;
			openFromTray.Stop();
			if (trayContext.updateNotification)
			{
				trayContext.updateNotification = false;
				if (trayContext.updater != null) await trayContext.updater.InstallPendingAsync();
			}
			else if (trayContext.infoNotification)
			{
				trayContext.infoNotification = false;
				if (trayContext.updater?.Pending is { FullInstallRequired: true } full) Ahna.Update.UpdateService.Open(full.NotesUrl ?? Ahna.Update.UpdateService.ReleasesPage);
			}
			else if (trayContext.clipboardNotification)
			{
				trayContext.ShowClipboard(received: true);
			}
			else if (trayContext.noticeNotification)
			{
				trayContext.noticeNotification = false;
				Program.Open(trayContext.server.OwnerUrl);
			}
			else if (trayContext.nearbyNotification)
			{
				trayContext.nearbyNotification = false;
				if (trayContext.requestForm != null && !trayContext.requestForm.IsDisposed)
				{
					Program.Reveal(trayContext.requestForm);
				}
			}
			else
			{
				trayContext.OpenReceivedFolder();
			}
		};
		server.Received += (string text) =>
		{
			trayContext.dispatcher.BeginInvoke(() =>
			{
				if (trayContext.server.Settings.Notifications)
				{
					trayContext.nearbyNotification = false;
					trayContext.clipboardNotification = false;
					trayContext.noticeNotification = false;
					trayContext.updateNotification = false;
					trayContext.infoNotification = false;
					trayContext.tray.ShowBalloonTip(4000, "아나 · 파일 수신", (text.Length > 200) ? text.Substring(0, 200) : text, ToolTipIcon.Info);
				}
			});
		};
		server.SendPrepared += (string text) =>
		{
			Notify("아나 · 전송 준비", text);
		};
		server.Delivered += (string text) =>
		{
			Notify("아나 · 파일 전달 완료", text);
		};
		server.ClientSaved += (string text) =>
		{
			Notify("아나 · 상대 기기 저장 완료", text, recipientSaved: true);
		};
		server.ClipboardReceived += (string sender) =>
		{
			Notify("아나 · 클립보드 수신", sender + "에서 글자가 도착했습니다. 알림을 눌러 확인하고 복사하세요.", recipientSaved: false, clipboard: true);
		};
		// 서버 관리자 공지: 새로 받은 읽지 않은 공지를 알리고, 누르면 아나 창에서 공지를 엽니다.
		server.NewAnnouncements += (TransferServer.Announcement[] list) =>
		{
			trayContext.dispatcher.BeginInvoke(() =>
			{
				string text = list.Length == 1 ? list[0].Text : (list.Length + "개의 새 공지가 있습니다. 눌러서 확인하세요.");
				trayContext.ShowTip("아나 · 공지", (text.Length > 200) ? text.Substring(0, 200) : text, ToolTipIcon.Info);
				trayContext.noticeNotification = true;
			});
		};
		// 서버 관리자 알림: 사용량 한도, 관리자 메시지, 초기화(초대 코드 다시 입력), 차단
		server.ServerNotice += (string action, string text) =>
		{
			trayContext.dispatcher.BeginInvoke(() =>
			{
				trayContext.ShowTip("아나 · 서버 알림", text, (action == "blocked" || action == "limit") ? ToolTipIcon.Warning : ToolTipIcon.Info);
			});
		};
		server.ClipboardRequested = () =>
		{
			trayContext.dispatcher.BeginInvoke(() =>
			{
				trayContext.ShowClipboard();
			});
		};
		server.PickRequested = (string target) =>
		{
			TaskCompletionSource completion = new TaskCompletionSource();
			trayContext.dispatcher.BeginInvoke(async () =>
			{
				try
				{
					await trayContext.SendDialogAsync(Array.Empty<string>(), target);
					completion.SetResult();
				}
				catch (Exception exception)
				{
					completion.SetException(exception);
				}
			});
			return completion.Task;
		};
		server.SettingsRequested = () =>
		{
			trayContext.dispatcher.BeginInvoke(() =>
			{
				if (testIndex >= 0)
				{
					File.AppendAllText(Path.Combine(data, "ui-events.log"), "settings-dispatched\n");
				}
				trayContext.ShowSettings();
			});
		};
		if (testIndex < 0)
		{
			server.IntegrationsRead = WindowsIntegration.Read;
			server.IntegrationsWrite = (TransferServer.IntegrationState state) =>
			{
				WindowsIntegration.Apply(state.Startup, state.ExplorerMenu);
			};
		}
		server.FolderPickRequested = () =>
		{
			TaskCompletionSource<string?> completion = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
			trayContext.dispatcher.BeginInvoke(() =>
			{
				try
				{
					completion.SetResult(trayContext.PickReceiveFolder());
				}
				catch (Exception exception)
				{
					completion.SetException(exception);
				}
			});
			return completion.Task;
		};
		server.UpdateRequested = (bool install) => trayContext.WebUpdateAsync(install);
		outbound.PickFiles = () =>
		{
			TaskCompletionSource<string[]?> completion = new TaskCompletionSource<string[]?>(TaskCreationOptions.RunContinuationsAsynchronously);
			trayContext.dispatcher.BeginInvoke(() =>
			{
				try
				{
					completion.SetResult(trayContext.PickSendFiles());
				}
				catch (Exception exception)
				{
					completion.SetException(exception);
				}
			});
			return completion.Task;
		};
		outbound.Finished = (string text) =>
		{
			trayContext.DeleteOutboundDrop();
			Notify("아나 · 다른 기기로 보내기", text);
		};
		// 웹 화면에 끌어다 놓은 파일을 [옵션에서 추가한 기기]로 보낼 때: 보내기가 끝나면 임시 폴더를 지웁니다.
		// 'nearby:' 로 시작하는 id는 근처 기기(Bluetooth)입니다. 근처 기기 보내기가 끝나면 그쪽에서 임시 폴더를 지웁니다.
		server.ExternalDropOwns = (string id) => id.StartsWith("nearby:", StringComparison.Ordinal) ? trayContext.nearby.Knows(id.Substring(7)) : trayContext.outbound.Owns(id);
		server.ExternalDrop = (string id, string folder, string[] files) =>
		{
			if (id.StartsWith("nearby:", StringComparison.Ordinal))
			{
				trayContext.nearby.StartSend(id.Substring(7), files, folder);
				return;
			}
			if (Interlocked.CompareExchange(ref trayContext.outboundDropFolder, folder, null) != null)
			{
				throw new ArgumentException("다른 파일을 보내는 중입니다. 끝난 뒤 다시 시도하세요.");
			}
			try
			{
				trayContext.outbound.StartSend(id, files);
			}
			catch
			{
				Interlocked.CompareExchange(ref trayContext.outboundDropFolder, null, folder);
				throw;
			}
		};
		server.ExternalDevices = outbound;
		outbound.Start();
		// 근처 기기 (Bluetooth LE) · QR · 게스트 링크
		nearby.PickFiles = outbound.PickFiles;
		nearby.RegisteredNames = () => trayContext.SendTargets().Select(((string Id, string Name) t) => t.Name);
		nearby.OfferReceived = (NearbyOffer offer) =>
		{
			trayContext.dispatcher.BeginInvoke(() =>
			{
				trayContext.ShowOffer(offer);
			});
		};
		nearby.Notify = (string title, string text) =>
		{
			Notify(title, text);
		};
		nearby.OpenQrRequested = () =>
		{
			trayContext.dispatcher.BeginInvoke(() =>
			{
				trayContext.ShowQr(receive: false);
			});
		};
		server.GuestRequested = (TransferServer.GuestTicket ticket) =>
		{
			trayContext.dispatcher.BeginInvoke(() =>
			{
				trayContext.ShowGuestRequest(ticket);
			});
		};
		server.NearbyHost = nearby;
		if (testIndex < 0)
		{
			nearby.Start();
		}
		server.ReceivedFolderRequested = () =>
		{
			trayContext.dispatcher.BeginInvoke(() =>
			{
				trayContext.OpenReceivedFolder();
			});
		};
		pipeTask = (flag ? Task.CompletedTask : ListenPipeAsync(stop.Token));
		dispatcher.BeginInvoke(async () =>
		{
			if (testIndex >= 0)
			{
				File.AppendAllText(Path.Combine(data, "ui-events.log"), "message-loop-ready\n");
			}
			await trayContext.HandleArgsAsync(args);
		});
		void Notify(string title, string text, bool recipientSaved = false, bool clipboard = false)
		{
			trayContext.dispatcher.BeginInvoke(() =>
			{
				if (recipientSaved ? trayContext.server.Settings.RecipientSavedNotifications : trayContext.server.Settings.Notifications)
				{
					trayContext.nearbyNotification = false;
					trayContext.clipboardNotification = clipboard;
					trayContext.updateNotification = false;
					trayContext.infoNotification = false;
					trayContext.tray.ShowBalloonTip(4500, title, (text.Length > 220) ? text.Substring(0, 220) : text, ToolTipIcon.Info);
				}
			});
		}
	}

	private async Task HandleArgsAsync(string[] args)
	{
		if (args.Contains("--notification"))
		{
			if (clipboardNotification)
			{
				ShowClipboard(received: true);
			}
			else
			{
				OpenReceivedFolder();
			}
			return;
		}
		if (args.Contains("--clipboard"))
		{
			ShowClipboard();
			return;
		}
		int num = Array.IndexOf(args, "--shared-manifest");
		if (num >= 0)
		{
			try
			{
				SharedFiles sharedFiles = ShareStaging.Load(args[num + 1], WindowsShare.CacheRoot);
				if (testLog != null)
				{
					File.AppendAllText(testLog, "windows-share-received count=" + sharedFiles.Paths.Length + "\n");
				}
				await SendDialogAsync(sharedFiles.Paths, null);
				return;
			}
			catch (Exception ex)
			{
				ShowTip("아나 · Windows 공유 요청 실패", ex.Message, ToolTipIcon.Warning);
				return;
			}
		}
		if (args.Contains("--settings"))
		{
			ShowSettings();
			return;
		}
		int num2 = Array.IndexOf(args, "--send");
		if (num2 >= 0 && num2 + 1 < args.Length)
		{
			await SendDialogAsync(args[(num2 + 1)..], null);
		}
		else if (!args.Contains("--background"))
		{
			Program.Open(server.OwnerUrl);
		}
	}

	private void OpenReceivedFolder()
	{
		if (!(DateTimeOffset.UtcNow - lastReceivedFolderOpen < TimeSpan.FromSeconds(1L)))
		{
			lastReceivedFolderOpen = DateTimeOffset.UtcNow;
			Directory.CreateDirectory(server.Settings.SavePath);
			Program.Open(server.Settings.SavePath);
		}
	}

	private async Task ListenPipeAsync(CancellationToken cancellation)
	{
		while (!cancellation.IsCancellationRequested)
		{
			try
			{
				await using NamedPipeServerStream pipe = new NamedPipeServerStream("Ahna.v1", PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
				await pipe.WaitForConnectionAsync(cancellation);
				using StreamReader reader = new StreamReader(pipe, null, detectEncodingFromByteOrderMarks: true, -1, leaveOpen: true);
				using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
				timeout.CancelAfter(5000);
				string text = await reader.ReadLineAsync(timeout.Token);
				if (text == null || text.Length >= 1048576)
				{
					continue;
				}
				string[] args = JsonSerializer.Deserialize<string[]>(text);
				if (args != null)
				{
					dispatcher.BeginInvoke(async () =>
					{
						await HandleArgsAsync(args);
					});
					using StreamWriter writer = new StreamWriter(pipe, null, -1, leaveOpen: true)
					{
						AutoFlush = true
					};
					await writer.WriteLineAsync("{\"accepted\":true}".AsMemory(), timeout.Token);
				}
			}
			catch (OperationCanceledException)
			{
			}
			catch (IOException)
			{
			}
			catch (JsonException)
			{
			}
		}
	}

	private Task SendDialogAsync(string[] paths, string? target)
	{
		// 보내기 창은 하나만 띄웁니다. 모달 창이 겹치면 앞 창이 닫히지 않아 멈춘 것처럼 보였습니다.
		if (sendDialog != null && !sendDialog.IsDisposed)
		{
			Program.Reveal(sendDialog);
			if (paths.Length != 0)
			{
				ShowTip("아나", "이미 열린 보내기 창이 있습니다. 그 창을 닫고 다시 보내 주세요.", ToolTipIcon.Info);
			}
			return Task.CompletedTask;
		}
		if (sending)
		{
			ShowTip("아나", "파일 준비가 진행 중입니다. 완료 후 다시 시도하세요.", ToolTipIcon.Info);
			return Task.CompletedTask;
		}
		(string, string)[] array = SendTargets();
		if (array.Length == 0 && paths.Length == 0)
		{
			ShowTip("아나", "받을 기기가 없습니다. 다른 기기의 아나에서 이 PC의 연결 코드를 입력하거나, 옵션에서 기기를 추가하세요.", ToolTipIcon.Info);
			Program.Open(server.OwnerUrl);
			return Task.CompletedTask;
		}
		// 화면은 SendDialog.cs (기기 카드 목록 · 다크 모드 · 키보드). 받을 기기 목록은 2.5초마다 SendTargets()로 새로 읽습니다.
		// 근처 기기(Bluetooth)도 함께 보여 줍니다. id는 'nearby:' + 주소.
		SendDialog dialog = new SendDialog(paths, () =>
		{
			nearby.KeepScanning();
			return SendTargets().Concat(nearby.Devices().Select(d => ("nearby:" + d.Id, d.Name + " · 근처 기기"))).ToArray();
		}, target);
		try
		{
			dialog.OptionsRequested = () =>
			{
				dialog.Close();
				ShowSettings();
			};
			dialog.SendRequested = () => Prepare(dialog);
			dialog.Shown += (object? _, EventArgs _) =>
			{
				Program.Reveal(dialog);
			};
			// 모달(ShowDialog) 대신 일반 창으로 띄워 다른 아나 창과 트레이가 막히지 않게 합니다. 일반 창은 닫힐 때 자동으로 정리됩니다.
			sendDialog = dialog;
			dialog.FormClosed += (object? _, FormClosedEventArgs _) =>
			{
				if (sendDialog == dialog)
				{
					sendDialog = null;
				}
			};
			dialog.Show();
		}
		catch
		{
			sendDialog = null;
			dialog.Dispose();
			throw;
		}
		return Task.CompletedTask;
		async Task Prepare(SendDialog form)
		{
			string[] array2 = form.Paths;
			if (array2.Length == 0 || sending)
			{
				return;
			}
			sending = true;
			form.Busy = true;
			try
			{
				string selectedTarget = form.SelectedTarget ?? throw new ArgumentException("받을 기기를 선택하세요.");
				if (selectedTarget.StartsWith("nearby:", StringComparison.Ordinal))
				{
					// 근처 기기: 1회용 링크를 만들어 Bluetooth로 알리고, 확인 숫자와 진행 상황은 아나 창에서 보여 줍니다.
					nearby.StartSend(selectedTarget.Substring(7), array2);
					Program.Open(server.OwnerUrl);
				}
				else if (outbound.Owns(selectedTarget))
				{
					// 옵션에서 추가한 기기: 백그라운드로 보내고 끝나면 알림으로 알려 줍니다.
					outbound.StartSend(selectedTarget, array2);
				}
				else
				{
					await server.AddPathsAsync(array2, selectedTarget);
				}
				if (!form.IsDisposed)
				{
					form.Close();
				}
			}
			catch (Exception ex)
			{
				if (!form.IsDisposed && form.Visible)
				{
					MessageBox.Show(form, ex.Message, "전송 준비 실패");
				}
				else
				{
					ShowTip("아나 · 전송 준비 실패", ex.Message, ToolTipIcon.Warning);
				}
			}
			finally
			{
				sending = false;
				if (!form.IsDisposed)
				{
					form.Busy = false;
				}
			}
		}
	}

	// ---- 근처 기기 · QR -------------------------------------------------------------------------

	/// <summary>근처 기기(Bluetooth)에서 온 보내기 제안: 확인 창 + 트레이 알림 (30초 뒤 자동 거절).</summary>
	private void ShowOffer(NearbyOffer offer)
	{
		string detail = NearbyUi.FormatSize(offer.Bytes) + " · " + NearbyUi.ShortFolder(server.Settings.SavePath) + "에 저장됩니다";
		NearbyRequestForm form = new NearbyRequestForm(offer.Name, "등록하지 않은 기기", offer.Proximity, offer.Summary, detail, offer.Code);
		form.Answered += (bool accept) =>
		{
			nearby.AnswerOffer(offer, accept);
			if (accept && server.Settings.Notifications)
			{
				ShowTip("아나 · 근처 기기", offer.Name + "에서 받는 중입니다…", ToolTipIcon.Info);
			}
		};
		ShowRequest(form, offer.Name + "에서 " + offer.Summary + "을(를) 보내려고 합니다 · 확인 숫자 " + offer.Code);
	}

	/// <summary>QR로 받기: 휴대폰 브라우저에서 보내기를 눌렀을 때의 확인 창.</summary>
	private void ShowGuestRequest(TransferServer.GuestTicket ticket)
	{
		if (ticket.State != "waiting")
		{
			return;
		}
		string title = ticket.Files.Length == 1 ? ticket.Files[0].Name : NearbyService.Summary(ticket.Files.Select((TransferServer.GuestFile f) => f.Name).ToArray());
		string detail = NearbyUi.FormatSize(ticket.Total) + " · " + NearbyUi.ShortFolder(server.Settings.SavePath) + "에 저장됩니다";
		NearbyRequestForm form = new NearbyRequestForm(ticket.Peer, "등록하지 않은 기기 · QR", null, title, detail, ticket.Code ?? "", () => ticket.State == "waiting");
		form.Answered += (bool accept) =>
		{
			server.AnswerGuest(ticket.Token, accept);
		};
		ShowRequest(form, ticket.Peer + "에서 " + title + "을(를) 보내려고 합니다 · 확인 숫자 " + ticket.Code);
	}

	private void ShowRequest(NearbyRequestForm form, string text)
	{
		requestForm = form;
		form.FormClosed += (object? _, FormClosedEventArgs _) =>
		{
			if (requestForm == form)
			{
				requestForm = null;
			}
		};
		form.Show();
		// 확인은 꼭 필요하므로 알림 설정과 관계없이 띄웁니다. 알림을 누르면 확인 창을 앞으로 가져옵니다.
		updateNotification = false;
		infoNotification = false;
		clipboardNotification = false;
		noticeNotification = false;
		nearbyNotification = true;
		tray.ShowBalloonTip(8000, "아나 · 근처 기기", (text.Length > 220) ? text.Substring(0, 220) : text, ToolTipIcon.Info);
	}

	/// <summary>QR 창 (QR로 보내기 / QR로 받기). 하나만 띄웁니다.</summary>
	private void ShowQr(bool receive)
	{
		QrForm? form = qrForm;
		if (form == null || form.IsDisposed)
		{
			QrForm created = new QrForm(server, receive);
			created.OptionsRequested += () =>
			{
				ShowSettings();
			};
			created.ReceivedFolderRequested += () =>
			{
				OpenReceivedFolder();
			};
			created.FormClosed += (object? _, FormClosedEventArgs _) =>
			{
				if (qrForm == created)
				{
					qrForm = null;
				}
			};
			qrForm = created;
			form = created;
			created.Show();
		}
		else
		{
			form.ShowTab(receive);
			if (form.WindowState == FormWindowState.Minimized)
			{
				form.WindowState = FormWindowState.Normal;
			}
		}
		// 웹 화면에서 열었을 때 브라우저 뒤로 숨지 않게 잠깐 맨 앞으로.
		form.TopMost = true;
		Program.Reveal(form);
		form.TopMost = false;
	}

	private void DeleteOutboundDrop()
	{
		string? folder = Interlocked.Exchange(ref outboundDropFolder, null);
		if (folder == null)
		{
			return;
		}
		try
		{
			Directory.Delete(folder, recursive: true);
		}
		catch
		{
		}
	}

	private void ShowClipboard(bool received = false)
	{
		if (clipboardForm == null || clipboardForm.IsDisposed)
		{
			// 받을 기기는 보내기 창과 같은 목록 (옵션에서 추가한 기기 + 이 PC에 연결한 기기).
			clipboardForm = new ClipboardForm(server, outbound, SendTargets);
		}
		clipboardForm.Show();
		if (received)
		{
			clipboardForm.ShowReceived();
		}
		if (clipboardForm.WindowState == FormWindowState.Minimized)
		{
			clipboardForm.WindowState = FormWindowState.Normal;
		}
		clipboardForm.Activate();
	}

	// 보내기 창의 받을 기기: 옵션에서 추가한 기기 + 이 PC에 연결한 기기 (같은 기기는 한 번만).
	private (string Id, string Name)[] SendTargets()
	{
		return outbound.Targets(server.Peers());
	}

	private void ShowSettings()
	{
		// 옵션은 이제 웹 화면 오른쪽 패널에서 엽니다 (#owner=...&options=1).
		if (testLog != null)
		{
			File.AppendAllText(testLog, "settings-web-opened\n");
			return;
		}
		Program.Open(server.OwnerUrl + "&options=1");
	}

	// 웹 화면에서 여는 파일·폴더 선택 창이 브라우저 뒤로 숨지 않도록 보이지 않는 맨 앞 창을 소유자로 씁니다.
	private static Form CreateDialogOwner()
	{
		Rectangle area = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 800, 600);
		Form owner = new Form
		{
			Text = "아나",
			ShowInTaskbar = false,
			FormBorderStyle = FormBorderStyle.None,
			StartPosition = FormStartPosition.Manual,
			Location = new Point(area.Left + area.Width / 2, area.Top + area.Height / 3),
			Size = new Size(1, 1),
			Opacity = 0,
			TopMost = true
		};
		owner.Show();
		owner.Activate();
		return owner;
	}

	// 웹 옵션의 [폴더 선택]: 트레이의 UI 스레드(STA)에서 호출됩니다.
	private string? PickReceiveFolder()
	{
		if (pickerOpen)
		{
			return null;
		}
		pickerOpen = true;
		try
		{
			return PickReceiveFolderCore();
		}
		finally
		{
			pickerOpen = false;
		}
	}

	private string? PickReceiveFolderCore()
	{
		using Form owner = CreateDialogOwner();
		using FolderBrowserDialog dialog = new FolderBrowserDialog
		{
			Description = "받은 파일을 저장할 폴더를 선택하세요",
			UseDescriptionForTitle = true,
			SelectedPath = server.Settings.SavePath,
			ShowNewFolderButton = true
		};
		return dialog.ShowDialog(owner) == DialogResult.OK ? dialog.SelectedPath : null;
	}

	// 웹 화면에서 [옵션에서 추가한 기기]로 보낼 파일 선택: 트레이의 UI 스레드(STA)에서 호출됩니다.
	private string[]? PickSendFiles()
	{
		if (pickerOpen)
		{
			return null;
		}
		pickerOpen = true;
		try
		{
			return PickSendFilesCore();
		}
		finally
		{
			pickerOpen = false;
		}
	}

	private string[]? PickSendFilesCore()
	{
		using Form owner = CreateDialogOwner();
		using OpenFileDialog dialog = new OpenFileDialog
		{
			Multiselect = true,
			Title = "보낼 파일 선택"
		};
		return dialog.ShowDialog(owner) == DialogResult.OK ? dialog.FileNames : null;
	}

	// 웹 옵션의 [업데이트 확인] / [설치]. 기존 UpdateService 흐름을 그대로 씁니다.
	private async Task<TransferServer.UpdateState> WebUpdateAsync(bool install)
	{
		string current = Ahna.Update.UpdateService.CurrentText;
		Ahna.Update.UpdateService? service = updater;
		if (service == null)
		{
			return new TransferServer.UpdateState(current, null, false, false, "이 실행에서는 업데이트를 확인할 수 없습니다.");
		}
		if (install)
		{
			Ahna.Update.UpdateManifest? pending = service.Pending;
			if (pending == null)
			{
				return new TransferServer.UpdateState(current, null, false, false, "설치할 새 버전이 없습니다. 먼저 업데이트를 확인하세요.");
			}
			if (pending.FullInstallRequired)
			{
				Ahna.Update.UpdateService.Open(pending.NotesUrl ?? Ahna.Update.UpdateService.ReleasesPage);
				return new TransferServer.UpdateState(current, pending.Version, true, true, "v" + pending.Version + "은 설치 파일로 직접 설치해야 합니다. 릴리스 페이지를 열었습니다.");
			}
			dispatcher.BeginInvoke(async () =>
			{
				await service.InstallPendingAsync();
			});
			return new TransferServer.UpdateState(current, pending.Version, true, false, "v" + pending.Version + "을 내려받아 설치합니다. 끝나면 아나가 다시 시작됩니다.");
		}
		Ahna.Update.UpdateManifest? manifest = await service.CheckAsync(userInitiated: false) ?? service.Pending;
		if (manifest != null)
		{
			return new TransferServer.UpdateState(current, manifest.Version, true, manifest.FullInstallRequired, manifest.FullInstallRequired ? "새 버전 v" + manifest.Version + " · 설치 파일로 직접 설치해야 합니다" : "새 버전 v" + manifest.Version + "이 있습니다");
		}
		if (service.LastError != null)
		{
			return new TransferServer.UpdateState(current, null, false, false, "업데이트 확인 실패 · " + service.LastError);
		}
		return new TransferServer.UpdateState(current, current, false, false, "최신 버전입니다");
	}

	protected override void ExitThreadCore()
	{
		stop.Cancel();
		updater?.Dispose();
		outbound.Dispose();
		nearby.Dispose();
		qrForm?.Dispose();
		requestForm?.Dispose();
		tray.Visible = false;
		tray.Dispose();
		clipboardForm?.Dispose();
		// 큰 파일을 주고받는 중이면 서버 종료가 오래 걸릴 수 있어 최대 3초만 기다립니다.
		try
		{
			Task.Run(async () =>
			{
				await server.DisposeAsync();
			}).Wait(TimeSpan.FromSeconds(3));
		}
		catch
		{
		}
		dispatcher.Dispose();
		stop.Dispose();
		base.ExitThreadCore();
	}
}
