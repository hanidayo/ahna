using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;
using static Ahna.UiTheme;

namespace Ahna;

/// <summary>
/// ‘클립보드 보내기 / 받은 글자’ 창 (트레이 메뉴 · 클립보드 수신 알림).
/// 왼쪽: 받을 기기 카드 + 보낼 글자 칸, 아래: [붙여넣기] [OO에 글자 보내기], 오른쪽: 받은 글자 목록(최신순, 카드마다 [복사]).
/// 받을 기기는 보내기 창과 같은 목록(SendTargets: 옵션에서 추가한 기기 + 이 PC에 연결한 기기)이고,
/// 추가한 기기는 OutboundDevices.SendTextAsync로, 연결한 기기는 이 PC의 클립보드 대기열(SendClipboard)로 보냅니다.
/// 모양 · 다크 모드 · DPI는 SendDialog와 같습니다 (UiTheme.cs).
/// </summary>
internal sealed class ClipboardForm : Form
{
	private const int VisibleDeviceRows = 3;

	private const TextFormatFlags LineFlags = TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis | TextFormatFlags.VerticalCenter;

	private const TextFormatFlags WrapFlags = TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding;

	private const string IdleStatus = "복사한 글자를 붙여넣고 보낼 기기를 선택하세요. 최대 64 KB · Ctrl+Enter로 보내기";

	private readonly TransferServer server;

	private readonly OutboundDevices outbound;

	private readonly Func<(string Id, string Name)[]> source;

	private (string Id, string Name)[] shown = Array.Empty<(string Id, string Name)>();

	private readonly List<DeviceCard> deviceCards = new List<DeviceCard>();

	private readonly List<ReceivedCard> receivedCards = new List<ReceivedCard>();

	private string? selected;

	private string? selectedLabel;

	private string? messageIds;

	private HashSet<string> knownMessages = new HashSet<string>();

	private string? highlightId;

	private DateTime highlightUntil;

	private string? copiedId;

	private DateTime copiedUntil;

	private bool sending;

	private bool ready;

	private bool focusReceivedOnShown;

	private bool dark;

	private Palette palette = LightPalette;

	private string status = IdleStatus;

	private bool statusError;

	private int draftBytes;

	private string counterText = "0 B / 64 KB";

	private readonly Font titleFont = new Font("Segoe UI", 12f, FontStyle.Bold);

	private readonly Font bodyFont = new Font("Segoe UI", 10f);

	private readonly Font nameFont = new Font("Segoe UI Semibold", 10f);

	private readonly Font smallFont = new Font("Segoe UI", 9f);

	private readonly Font labelFont = new Font("Segoe UI Semibold", 9f);

	private readonly Font buttonBoldFont = new Font("Segoe UI", 10f, FontStyle.Bold);

	private readonly int bodyLine;

	private readonly DeviceListPanel deviceList;

	private readonly EmptyNote deviceEmpty;

	private readonly TextBox editor;

	private readonly EditorFrame editorFrame;

	private readonly ScrollPanel inboxPanel;

	private readonly EmptyNote inboxEmpty;

	private readonly FooterPanel footer;

	private readonly FlatButton pasteButton;

	private readonly FlatButton sendButton;

	private readonly System.Windows.Forms.Timer timer;

	// OnPaint에서 그리는 글자 자리 (LayoutForm이 정합니다)
	private Rectangle deviceLabelRect;

	private Rectangle draftLabelRect;

	private Rectangle inboxLabelRect;

	private Rectangle inboxNoteRect;

	public ClipboardForm(TransferServer server, OutboundDevices outbound, Func<(string Id, string Name)[]> source)
	{
		this.server = server;
		this.outbound = outbound;
		this.source = source;
		dark = ReadDarkMode();
		palette = dark ? DarkPalette : LightPalette;
		bodyLine = LineHeight(bodyFont);
		SuspendLayout();
		Text = "아나 · 클립보드";
		Icon = Program.AppIcon;
		AutoScaleMode = AutoScaleMode.None;
		Font = bodyFont;
		FormBorderStyle = FormBorderStyle.Sizable;
		StartPosition = FormStartPosition.CenterScreen;
		KeyPreview = true;
		SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
		deviceList = new DeviceListPanel(this)
		{
			AutoScroll = true,
			AccessibleName = "받을 기기",
			AccessibleRole = AccessibleRole.List
		};
		deviceEmpty = new EmptyNote(this, "받을 기기가 없습니다", "다른 기기의 아나에서 이 PC의 연결 코드를 입력하거나, 옵션에서 기기를 추가하세요.")
		{
			Visible = false
		};
		deviceList.Controls.Add(deviceEmpty);
		editor = new TextBox
		{
			Multiline = true,
			AcceptsReturn = true,
			AcceptsTab = false,
			WordWrap = true,
			ScrollBars = ScrollBars.Vertical,
			BorderStyle = BorderStyle.None,
			// 기본 32767자 제한을 풉니다 (64 KB 검사는 보낼 때 따로 합니다).
			MaxLength = int.MaxValue,
			PlaceholderText = "보낼 글자를 입력하거나 붙여넣으세요",
			AccessibleName = "보낼 글자"
		};
		editorFrame = new EditorFrame(this, editor);
		inboxPanel = new ScrollPanel
		{
			AutoScroll = true,
			TabStop = false,
			AccessibleName = "받은 글자",
			AccessibleRole = AccessibleRole.List
		};
		inboxEmpty = new EmptyNote(this, "아직 받은 글자가 없습니다", "다른 기기에서 글자를 보내면 여기에 바로 표시됩니다.")
		{
			Visible = false
		};
		inboxPanel.Controls.Add(inboxEmpty);
		footer = new FooterPanel(this);
		pasteButton = new FlatButton(this, ButtonKind.Secondary, "붙여넣기")
		{
			AccessibleDescription = "복사해 둔 글자를 보낼 글자 칸에 넣습니다 (Ctrl+V)"
		};
		sendButton = new FlatButton(this, ButtonKind.Primary, "글자 보내기")
		{
			AccessibleDescription = "Ctrl+Enter"
		};
		// 탭 순서: 받을 기기 → 보낼 글자 → 붙여넣기 → 보내기 → 받은 글자
		deviceList.TabIndex = 0;
		editorFrame.TabIndex = 1;
		footer.TabIndex = 2;
		inboxPanel.TabIndex = 3;
		pasteButton.TabIndex = 0;
		sendButton.TabIndex = 1;
		footer.Controls.AddRange(new Control[] { pasteButton, sendButton });
		Controls.AddRange(new Control[] { deviceList, editorFrame, footer, inboxPanel });
		pasteButton.Click += (object? _, EventArgs _) => PasteFromClipboard();
		sendButton.Click += (object? _, EventArgs _) => Send();
		editor.TextChanged += (object? _, EventArgs _) => OnDraftChanged();
		deviceList.HandleCreated += (object? _, EventArgs _) => ApplyControlTheme(deviceList, dark);
		inboxPanel.HandleCreated += (object? _, EventArgs _) => ApplyControlTheme(inboxPanel, dark);
		editor.HandleCreated += (object? _, EventArgs _) => ApplyControlTheme(editor, dark);
		ApplyTheme();
		ClientSize = new Size(S(860), S(620));
		MinimumSize = new Size(S(740), S(560));
		ready = true;
		RefreshTargets(force: true);
		RefreshInbox(force: true);
		OnDraftChanged();
		LayoutForm();
		ResumeLayout(performLayout: false);
		// 받을 기기와 받은 글자는 1.5초마다 새로 읽습니다.
		timer = new System.Windows.Forms.Timer
		{
			Interval = 1500
		};
		timer.Tick += (object? _, EventArgs _) => OnTick();
		timer.Start();
		SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
	}

	/// <summary>클립보드 수신 알림을 눌렀을 때: 받은 글자 목록을 새로 읽고 가장 최근 글자를 강조합니다.</summary>
	internal void ShowReceived()
	{
		RefreshInbox(force: false);
		ReceivedCard? newest = receivedCards.FirstOrDefault();
		if (newest == null)
		{
			return;
		}
		Highlight(newest.Id);
		inboxPanel.AutoScrollPosition = new Point(0, 0);
		LayoutInbox();
		inboxPanel.ScrollControlIntoView(newest);
		// 처음 열 때는 OnShown이 나중에 실행되므로 그때 포커스를 옮깁니다.
		focusReceivedOnShown = true;
		try
		{
			ActiveControl = newest.CopyButton;
		}
		catch
		{
		}
	}

	private int S(float value)
	{
		return (int)Math.Round(value * DeviceDpi / 96f);
	}

	private static string NormalizeNewlines(string text)
	{
		return text.Replace("\r\n", "\n").Replace('\r', '\n');
	}

	// 예전 창(RichTextBox)처럼 줄바꿈은 \n으로 보냅니다.
	private string Draft()
	{
		return NormalizeNewlines(editor.Text);
	}

	private static string FormatBytes(int n)
	{
		if (n < 1024)
		{
			return n + " B";
		}
		return (n / 1024.0).ToString("0.0", CultureInfo.InvariantCulture) + " KB";
	}

	private void OnDraftChanged()
	{
		draftBytes = Encoding.UTF8.GetByteCount(Draft());
		counterText = FormatBytes(draftBytes) + " / 64 KB";
		if (ready)
		{
			Invalidate(draftLabelRect);
		}
	}

	private void SetStatus(string text, bool error)
	{
		if (IsDisposed)
		{
			return;
		}
		status = text;
		statusError = error;
		footer.AccessibleDescription = text;
		footer.Invalidate();
	}

	private void OnTick()
	{
		RefreshTargets(force: false);
		RefreshInbox(force: false);
		DateTime now = DateTime.UtcNow;
		if (highlightId != null && now >= highlightUntil)
		{
			highlightId = null;
			InvalidateReceived();
		}
		if (copiedId != null && now >= copiedUntil)
		{
			copiedId = null;
			foreach (ReceivedCard card in receivedCards)
			{
				card.UpdateCopyLabel();
			}
		}
	}

	private void RefreshTargets(bool force)
	{
		(string Id, string Name)[] list;
		try
		{
			list = source();
		}
		catch
		{
			return;
		}
		if (!force && list.SequenceEqual(shown))
		{
			return;
		}
		shown = list;
		if (selected == null || !list.Any(((string Id, string Name) d) => d.Id == selected))
		{
			// 같은 기기가 다른 연결(id)로 바뀌었으면 이름으로 이어서 고릅니다.
			string? sameName = selectedLabel == null ? null : list.Where(((string Id, string Name) d) => DisplayName(d.Name) == selectedLabel).Select(((string Id, string Name) d) => d.Id).FirstOrDefault();
			selected = sameName ?? list.Where(((string Id, string Name) d) => !IsOffline(d.Name)).Select(((string Id, string Name) d) => d.Id).FirstOrDefault() ?? (list.Length > 0 ? list[0].Id : null);
		}
		deviceList.SuspendLayout();
		foreach (DeviceCard old in deviceCards)
		{
			deviceList.Controls.Remove(old);
			old.Dispose();
		}
		deviceCards.Clear();
		foreach ((string Id, string Name) d in list)
		{
			DeviceCard card = new DeviceCard(this, d.Id, DisplayName(d.Name), !IsOffline(d.Name));
			card.MouseDown += (object? _, MouseEventArgs e) =>
			{
				if (e.Button == MouseButtons.Left)
				{
					SelectDevice(card.Id);
				}
			};
			deviceCards.Add(card);
			deviceList.Controls.Add(card);
		}
		deviceEmpty.Visible = deviceCards.Count == 0;
		selectedLabel = deviceCards.FirstOrDefault((DeviceCard c) => c.Id == selected)?.Label;
		deviceList.ResumeLayout(performLayout: false);
		deviceList.AutoScrollPosition = new Point(0, 0);
		LayoutForm();
		UpdateButtons();
	}

	private void SelectDevice(string id)
	{
		if (sending || selected == id)
		{
			return;
		}
		selected = id;
		DeviceCard? current = null;
		foreach (DeviceCard card in deviceCards)
		{
			card.UpdateAccessibility();
			card.Invalidate();
			if (card.Id == id)
			{
				current = card;
			}
		}
		selectedLabel = current?.Label;
		if (current != null)
		{
			deviceList.ScrollControlIntoView(current);
		}
		UpdateButtons();
	}

	private void MoveSelection(int delta)
	{
		if (deviceCards.Count == 0 || sending)
		{
			return;
		}
		int index = deviceCards.FindIndex((DeviceCard c) => c.Id == selected);
		index = index < 0 ? 0 : Math.Clamp(index + delta, 0, deviceCards.Count - 1);
		SelectDevice(deviceCards[index].Id);
	}

	private void RefreshInbox(bool force)
	{
		ClipboardMessage[] messages;
		try
		{
			messages = server.ClipboardInbox();
		}
		catch
		{
			return;
		}
		string ids = string.Join('|', messages.Select((ClipboardMessage m) => m.Id));
		if (!force && ids == messageIds)
		{
			return;
		}
		bool firstLoad = messageIds == null;
		messageIds = ids;
		// 창이 열려 있는 동안 새로 도착한 글자는 잠시 강조합니다 (목록은 최신순).
		ClipboardMessage? arrived = firstLoad ? null : messages.FirstOrDefault((ClipboardMessage m) => !knownMessages.Contains(m.Id));
		knownMessages = new HashSet<string>(messages.Select((ClipboardMessage m) => m.Id));
		string? focusedId = receivedCards.FirstOrDefault((ReceivedCard c) => c.ContainsFocus)?.Id;
		inboxPanel.SuspendLayout();
		foreach (ReceivedCard old in receivedCards)
		{
			inboxPanel.Controls.Remove(old);
			old.Dispose();
		}
		receivedCards.Clear();
		foreach (ClipboardMessage message in messages)
		{
			ReceivedCard card = new ReceivedCard(this, message);
			receivedCards.Add(card);
			inboxPanel.Controls.Add(card);
		}
		inboxEmpty.Visible = receivedCards.Count == 0;
		if (highlightId != null && !knownMessages.Contains(highlightId))
		{
			highlightId = null;
		}
		if (arrived != null)
		{
			Highlight(arrived.Id);
		}
		inboxPanel.ResumeLayout(performLayout: false);
		inboxPanel.AutoScrollPosition = new Point(0, 0);
		LayoutInbox();
		if (focusedId != null)
		{
			ReceivedCard? again = receivedCards.FirstOrDefault((ReceivedCard c) => c.Id == focusedId) ?? receivedCards.FirstOrDefault();
			if (again != null)
			{
				again.CopyButton.Focus();
			}
			else
			{
				pasteButton.Focus();
			}
		}
		if (ready)
		{
			Invalidate(inboxLabelRect);
		}
	}

	private void Highlight(string id)
	{
		highlightId = id;
		highlightUntil = DateTime.UtcNow.AddSeconds(6.0);
		InvalidateReceived();
	}

	private void InvalidateReceived()
	{
		foreach (ReceivedCard card in receivedCards)
		{
			card.Invalidate(invalidateChildren: true);
		}
	}

	private void CopyMessage(string id)
	{
		ClipboardMessage? message = server.FindClipboard(id);
		if (message is null)
		{
			SetStatus("보관 기간이 지나 지워진 글자입니다.", error: true);
			RefreshInbox(force: true);
			return;
		}
		try
		{
			Clipboard.SetText(message.Text, TextDataFormat.UnicodeText);
			SetStatus("복사했습니다. 원하는 곳에서 Ctrl+V로 붙여넣으세요.", error: false);
			copiedId = id;
			copiedUntil = DateTime.UtcNow.AddSeconds(2.0);
			foreach (ReceivedCard card in receivedCards)
			{
				card.UpdateCopyLabel();
			}
		}
		catch
		{
			SetStatus("복사하지 못했습니다. 잠시 후 다시 누르세요.", error: true);
		}
	}

	private void PasteFromClipboard()
	{
		if (sending)
		{
			return;
		}
		try
		{
			if (!Clipboard.ContainsText())
			{
				SetStatus("클립보드에 글자가 없습니다. 먼저 글자를 복사하세요.", error: true);
				return;
			}
			string text = Clipboard.GetText(TextDataFormat.UnicodeText);
			// 글자 칸(Windows 편집 컨트롤)은 \r\n으로 줄을 나눕니다.
			editor.Text = NormalizeNewlines(text).Replace("\n", "\r\n");
			editor.SelectionStart = editor.TextLength;
			editor.SelectionLength = 0;
			editor.ScrollToCaret();
			editor.Focus();
			SetStatus("보낼 글자를 확인한 뒤 보내기를 누르세요.", error: false);
		}
		catch
		{
			SetStatus("클립보드를 읽지 못했습니다. 잠시 후 다시 시도하세요.", error: true);
		}
	}

	private async void Send()
	{
		if (sending)
		{
			return;
		}
		string? id = selected;
		string name = selectedLabel ?? "받을 기기";
		string text = Draft();
		if (id == null)
		{
			SetStatus("받을 기기에서 아나를 열어 주세요.", error: true);
			return;
		}
		if (text.Length == 0)
		{
			SetStatus("보낼 글자를 먼저 붙여넣어 주세요.", error: true);
			return;
		}
		if (text.Contains('\0') || Encoding.UTF8.GetByteCount(text) > TransferServer.MaxClipboardBytes)
		{
			SetStatus("클립보드 텍스트는 최대 64 KB까지 보낼 수 있습니다. 긴 글은 파일로 보내세요.", error: true);
			return;
		}
		sending = true;
		UpdateButtons();
		SetStatus(name + "에 보내는 중…", error: false);
		try
		{
			if (outbound.Owns(id))
			{
				// 옵션에서 추가한 기기: 그 기기의 아나로 바로 보냅니다.
				await outbound.SendTextAsync(id, text);
			}
			else
			{
				// 이 PC에 연결한 기기: 이 PC의 클립보드 대기열에 넣으면 그 기기가 가져갑니다.
				server.SendClipboard(text, id);
			}
			SetStatus(name + "에 보냈습니다. 받은 기기의 ‘복사’를 누르세요.", error: false);
		}
		catch (Exception ex)
		{
			SetStatus(ex.Message, error: true);
		}
		finally
		{
			sending = false;
			if (!IsDisposed)
			{
				UpdateButtons();
			}
		}
	}

	private string SendText()
	{
		if (sending)
		{
			return "보내는 중…";
		}
		string? name = selectedLabel;
		if (name == null)
		{
			return "글자 보내기";
		}
		if (name.Length > 14)
		{
			name = name.Substring(0, 13) + "…";
		}
		return name + "에 글자 보내기";
	}

	private void UpdateButtons()
	{
		if (IsDisposed)
		{
			return;
		}
		sendButton.Text = SendText();
		sendButton.Enabled = !sending && selected != null;
		pasteButton.Enabled = !sending;
		LayoutFooter();
		footer.Invalidate();
	}

	private void LayoutForm()
	{
		int width = ClientSize.Width;
		int height = ClientSize.Height;
		if (!ready || width < S(200) || height < S(200))
		{
			return;
		}
		int pad = S(24);
		int headerBottom = pad + S(44);
		int contentTop = headerBottom + S(22);
		int labelHeight = S(24);
		int footerHeight = S(72);
		footer.Bounds = new Rectangle(0, height - footerHeight, width, footerHeight);
		int contentBottom = footer.Top - S(20);
		int columnGap = S(28);
		int leftWidth = (width - pad * 2 - columnGap) * 52 / 100;
		int leftX = pad;
		int rightX = leftX + leftWidth + columnGap;
		int rightWidth = width - pad - rightX;
		// 왼쪽: 받을 기기 + 보낼 글자
		deviceLabelRect = new Rectangle(leftX, contentTop, leftWidth, labelHeight);
		int deviceTop = deviceLabelRect.Bottom + S(6);
		int rowHeight = S(60);
		int gap = S(8);
		int shownRows = Math.Clamp(deviceCards.Count, 1, VisibleDeviceRows);
		int deviceHeight = deviceCards.Count == 0 ? S(100) : shownRows * rowHeight + (shownRows - 1) * gap;
		deviceList.Bounds = new Rectangle(leftX, deviceTop, leftWidth, deviceHeight);
		LayoutDevices();
		draftLabelRect = new Rectangle(leftX, deviceList.Bottom + S(18), leftWidth, labelHeight);
		int editorTop = draftLabelRect.Bottom + S(6);
		editorFrame.Bounds = new Rectangle(leftX, editorTop, leftWidth, Math.Max(S(96), contentBottom - editorTop));
		// 오른쪽: 받은 글자
		inboxLabelRect = new Rectangle(rightX, contentTop, rightWidth, labelHeight);
		int inboxTop = inboxLabelRect.Bottom + S(6);
		int noteHeight = LineHeight(smallFont);
		int inboxBottom = Math.Max(editorFrame.Bottom, contentBottom) - noteHeight - S(10);
		inboxPanel.Bounds = new Rectangle(rightX, inboxTop, rightWidth, Math.Max(S(96), inboxBottom - inboxTop));
		inboxNoteRect = new Rectangle(rightX, inboxPanel.Bottom + S(10), rightWidth, noteHeight);
		LayoutInbox();
		LayoutFooter();
		Invalidate();
	}

	private void LayoutDevices()
	{
		int rowHeight = S(60);
		int gap = S(8);
		bool scrolling = deviceCards.Count > VisibleDeviceRows;
		int rowWidth = deviceList.Width - (scrolling ? SystemInformation.VerticalScrollBarWidth + S(6) : 0);
		int offset = deviceList.AutoScrollPosition.Y;
		for (int i = 0; i < deviceCards.Count; i++)
		{
			deviceCards[i].Bounds = new Rectangle(0, offset + i * (rowHeight + gap), rowWidth, rowHeight);
		}
		deviceEmpty.Bounds = new Rectangle(0, 0, deviceList.Width, deviceList.Height);
		DeviceCard? current = deviceCards.FirstOrDefault((DeviceCard c) => c.Id == selected);
		if (current != null)
		{
			deviceList.ScrollControlIntoView(current);
		}
	}

	private int ReceivedCardHeight()
	{
		return S(10) + S(30) + S(6) + bodyLine * 2 + S(14);
	}

	private void LayoutInbox()
	{
		int gap = S(8);
		int cardHeight = ReceivedCardHeight();
		int count = receivedCards.Count;
		int total = count * cardHeight + Math.Max(0, count - 1) * gap;
		bool scrolling = count > 0 && total > inboxPanel.Height;
		int cardWidth = inboxPanel.Width - (scrolling ? SystemInformation.VerticalScrollBarWidth + S(6) : 0);
		int offset = inboxPanel.AutoScrollPosition.Y;
		for (int i = 0; i < count; i++)
		{
			receivedCards[i].Bounds = new Rectangle(0, offset + i * (cardHeight + gap), cardWidth, cardHeight);
		}
		inboxEmpty.Bounds = new Rectangle(0, 0, inboxPanel.Width, Math.Min(inboxPanel.Height, S(120)));
	}

	private void LayoutFooter()
	{
		if (!ready)
		{
			return;
		}
		int pad = S(24);
		int gap = S(8);
		int height = S(40);
		int top = (footer.Height - height) / 2;
		int sendWidth = Math.Max(sendButton.PreferredWidth(), S(140));
		int pasteWidth = pasteButton.PreferredWidth();
		int maxSend = Math.Max(S(120), footer.Width - pad * 2 - pasteWidth - gap - S(160));
		sendWidth = Math.Min(sendWidth, maxSend);
		sendButton.Bounds = new Rectangle(footer.Width - pad - sendWidth, top, sendWidth, height);
		pasteButton.Bounds = new Rectangle(sendButton.Left - gap - pasteWidth, top, pasteWidth, height);
	}

	protected override void OnResize(EventArgs e)
	{
		base.OnResize(e);
		LayoutForm();
	}

	protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
	{
		switch (keyData)
		{
		case Keys.Escape:
			Close();
			return true;
		case Keys.Control | Keys.Return:
			Send();
			return true;
		case Keys.Return:
			if (ActiveControl is FlatButton focused)
			{
				focused.PerformClick();
				return true;
			}
			break;
		case Keys.Control | Keys.V:
			// 글자 칸 밖에서 Ctrl+V를 누르면 [붙여넣기]와 같습니다.
			if (!editor.Focused)
			{
				PasteFromClipboard();
				return true;
			}
			break;
		case Keys.Up:
		case Keys.Left:
			if (deviceList.Focused)
			{
				MoveSelection(-1);
				return true;
			}
			break;
		case Keys.Down:
		case Keys.Right:
			if (deviceList.Focused)
			{
				MoveSelection(1);
				return true;
			}
			break;
		}
		return base.ProcessCmdKey(ref msg, keyData);
	}

	protected override void OnShown(EventArgs e)
	{
		base.OnShown(e);
		if (focusReceivedOnShown)
		{
			focusReceivedOnShown = false;
			ReceivedCard? newest = receivedCards.FirstOrDefault();
			if (newest != null)
			{
				newest.CopyButton.Focus();
				return;
			}
		}
		// 글자 칸은 비워 두고 안내 문구가 보이게 합니다 (Ctrl+V는 어디서나 글자 칸에 붙여넣습니다).
		pasteButton.Focus();
	}

	protected override void OnHandleCreated(EventArgs e)
	{
		base.OnHandleCreated(e);
		SetDarkTitleBar(Handle, dark);
	}

	protected override void OnPaint(PaintEventArgs e)
	{
		Graphics g = e.Graphics;
		g.Clear(palette.Surface);
		Smooth(g);
		int pad = S(24);
		int tile = S(44);
		Rectangle tileRect = new Rectangle(pad, pad, tile, tile);
		using (GraphicsPath path = RoundRect(tileRect, S(11)))
		using (SolidBrush brush = new SolidBrush(palette.Accent))
		{
			g.FillPath(brush, path);
		}
		DrawPlane(g, tileRect, palette.OnAccent);
		int textLeft = tileRect.Right + S(14);
		int textWidth = Math.Max(0, ClientSize.Width - textLeft - pad);
		int titleHeight = LineHeight(titleFont);
		int subtitleHeight = LineHeight(bodyFont);
		int top = pad + (tile - titleHeight - S(2) - subtitleHeight) / 2;
		TextRenderer.DrawText(g, "클립보드", titleFont, new Rectangle(textLeft, top, textWidth, titleHeight), palette.Text, LineFlags);
		TextRenderer.DrawText(g, "글자를 다른 기기로 보내고, 받은 글자를 복사합니다", bodyFont, new Rectangle(textLeft, top + titleHeight + S(2), textWidth, subtitleHeight), palette.Muted, LineFlags);
		TextRenderer.DrawText(g, "받을 기기", labelFont, deviceLabelRect, palette.Muted, LineFlags);
		// 보낼 글자 + 오른쪽에 크기 (64 KB를 넘으면 빨간색)
		int counterWidth = TextRenderer.MeasureText(counterText, smallFont, default(Size), TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding).Width;
		Rectangle counterRect = new Rectangle(draftLabelRect.Right - counterWidth, draftLabelRect.Top, counterWidth, draftLabelRect.Height);
		TextRenderer.DrawText(g, "보낼 글자", labelFont, new Rectangle(draftLabelRect.Left, draftLabelRect.Top, Math.Max(0, draftLabelRect.Width - counterWidth - S(8)), draftLabelRect.Height), palette.Muted, LineFlags);
		TextRenderer.DrawText(g, counterText, smallFont, counterRect, draftBytes > TransferServer.MaxClipboardBytes ? palette.Danger : palette.Faint, LineFlags);
		// 받은 글자 + 개수
		const string inboxTitle = "받은 글자";
		int inboxTitleWidth = TextRenderer.MeasureText(inboxTitle, labelFont, default(Size), TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding).Width;
		TextRenderer.DrawText(g, inboxTitle, labelFont, inboxLabelRect, palette.Muted, LineFlags);
		if (receivedCards.Count > 0)
		{
			int countLeft = inboxLabelRect.Left + inboxTitleWidth + S(8);
			TextRenderer.DrawText(g, receivedCards.Count + "개", smallFont, new Rectangle(countLeft, inboxLabelRect.Top, Math.Max(0, inboxLabelRect.Right - countLeft), inboxLabelRect.Height), palette.Faint, LineFlags);
		}
		TextRenderer.DrawText(g, "최근 20개 · 최대 24시간 보관 · 아나를 종료하면 지워집니다", smallFont, inboxNoteRect, palette.Faint, LineFlags);
	}

	private void ApplyTheme()
	{
		palette = dark ? DarkPalette : LightPalette;
		BackColor = palette.Surface;
		ForeColor = palette.Text;
		deviceList.BackColor = palette.Surface;
		deviceEmpty.BackColor = palette.Surface;
		inboxPanel.BackColor = palette.Surface;
		inboxEmpty.BackColor = palette.Surface;
		editorFrame.BackColor = palette.Surface;
		editor.BackColor = palette.Surface;
		editor.ForeColor = palette.Text;
		footer.BackColor = palette.Subtle;
		if (IsHandleCreated)
		{
			SetDarkTitleBar(Handle, dark);
		}
		ApplyControlTheme(deviceList, dark);
		ApplyControlTheme(inboxPanel, dark);
		ApplyControlTheme(editor, dark);
		Invalidate(invalidateChildren: true);
	}

	private void OnUserPreferenceChanged(object? sender, UserPreferenceChangedEventArgs e)
	{
		if (e.Category != UserPreferenceCategory.General && e.Category != UserPreferenceCategory.Color)
		{
			return;
		}
		if (IsDisposed || !IsHandleCreated)
		{
			return;
		}
		try
		{
			BeginInvoke(() =>
			{
				bool now = ReadDarkMode();
				if (!IsDisposed && now != dark)
				{
					dark = now;
					ApplyTheme();
				}
			});
		}
		catch
		{
		}
	}

	protected override void Dispose(bool disposing)
	{
		if (disposing)
		{
			SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
			timer.Dispose();
		}
		base.Dispose(disposing);
		if (disposing)
		{
			titleFont.Dispose();
			bodyFont.Dispose();
			nameFont.Dispose();
			smallFont.Dispose();
			labelFont.Dispose();
			buttonBoldFont.Dispose();
		}
	}

	private static string When(DateTimeOffset created)
	{
		DateTime local = created.ToLocalTime().DateTime;
		DateTime today = DateTime.Today;
		string time = local.ToString("HH:mm", CultureInfo.InvariantCulture);
		if (local.Date == today)
		{
			return "오늘 " + time;
		}
		if (local.Date == today.AddDays(-1.0))
		{
			return "어제 " + time;
		}
		return local.ToString("MM/dd", CultureInfo.InvariantCulture) + " " + time;
	}

	// 미리보기: 줄바꿈 · 공백을 한 칸으로 줄인 앞부분 (카드에는 두 줄까지 보입니다).
	private static string Preview(string text)
	{
		StringBuilder builder = new StringBuilder(Math.Min(text.Length, 400));
		bool space = false;
		foreach (char c in text)
		{
			if (builder.Length >= 400)
			{
				break;
			}
			if (char.IsWhiteSpace(c) || char.IsControl(c))
			{
				space = builder.Length > 0;
				continue;
			}
			if (space)
			{
				builder.Append(' ');
				space = false;
			}
			builder.Append(c);
		}
		return builder.ToString();
	}

	private enum ButtonKind
	{
		Primary,
		Secondary,
		Soft
	}

	/// <summary>둥근 모서리 평면 버튼 (SendDialog와 같은 모양, 받은 글자의 [복사]는 연한 초록).</summary>
	private sealed class FlatButton : Control
	{
		private readonly ClipboardForm owner;

		private readonly ButtonKind kind;

		private bool hover;

		private bool down;

		public FlatButton(ClipboardForm owner, ButtonKind kind, string text)
		{
			this.owner = owner;
			this.kind = kind;
			Text = text;
			SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable | ControlStyles.StandardClick, true);
			SetStyle(ControlStyles.StandardDoubleClick, false);
			TabStop = true;
			Cursor = Cursors.Hand;
			AccessibleRole = AccessibleRole.PushButton;
		}

		private Font TextFont => kind switch
		{
			ButtonKind.Primary => owner.buttonBoldFont,
			ButtonKind.Soft => owner.labelFont,
			_ => owner.bodyFont
		};

		internal int PreferredWidth()
		{
			int text = TextRenderer.MeasureText(Text, TextFont, default(Size), TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding).Width;
			return text + owner.S(kind == ButtonKind.Soft ? 28 : 36);
		}

		internal void PerformClick()
		{
			if (Enabled && Visible)
			{
				OnClick(EventArgs.Empty);
			}
		}

		protected override void OnMouseEnter(EventArgs e)
		{
			hover = true;
			Invalidate();
			base.OnMouseEnter(e);
		}

		protected override void OnMouseLeave(EventArgs e)
		{
			hover = false;
			down = false;
			Invalidate();
			base.OnMouseLeave(e);
		}

		protected override void OnMouseDown(MouseEventArgs e)
		{
			if (e.Button == MouseButtons.Left)
			{
				down = true;
				Invalidate();
			}
			base.OnMouseDown(e);
		}

		protected override void OnMouseUp(MouseEventArgs e)
		{
			down = false;
			Invalidate();
			base.OnMouseUp(e);
		}

		protected override void OnKeyUp(KeyEventArgs e)
		{
			if (e.KeyCode == Keys.Space)
			{
				PerformClick();
				e.Handled = true;
			}
			base.OnKeyUp(e);
		}

		protected override void OnGotFocus(EventArgs e)
		{
			Invalidate();
			base.OnGotFocus(e);
		}

		protected override void OnLostFocus(EventArgs e)
		{
			Invalidate();
			base.OnLostFocus(e);
		}

		protected override void OnEnabledChanged(EventArgs e)
		{
			Cursor = Enabled ? Cursors.Hand : Cursors.Default;
			Invalidate();
			base.OnEnabledChanged(e);
		}

		protected override void OnTextChanged(EventArgs e)
		{
			AccessibleName = Text;
			Invalidate();
			base.OnTextChanged(e);
		}

		protected override void OnPaint(PaintEventArgs e)
		{
			Palette p = owner.palette;
			Graphics g = e.Graphics;
			Color back = Parent is ReceivedCard card ? card.Fill : (Parent?.BackColor ?? p.Surface);
			g.Clear(back);
			Smooth(g);
			float ring = owner.S(2);
			RectangleF shape = new RectangleF(ring, ring, Width - ring * 2f, Height - ring * 2f);
			float radius = owner.S(8);
			Color fill;
			Color border;
			Color text;
			switch (kind)
			{
			case ButtonKind.Primary:
				fill = !Enabled ? Mix(p.Accent, back, 0.55f) : (hover || down) ? p.AccentHover : p.Accent;
				border = fill;
				text = Enabled ? p.OnAccent : Mix(p.OnAccent, back, 0.35f);
				break;
			case ButtonKind.Secondary:
				fill = !Enabled ? p.Surface : down ? Mix(p.Surface, p.Text, 0.08f) : hover ? Mix(p.Surface, p.Text, 0.04f) : p.Surface;
				border = Enabled && (hover || down) ? p.BorderStrong : p.Border;
				text = Enabled ? p.Text : p.Faint;
				break;
			default:
				fill = !Enabled ? back : down ? Mix(p.AccentSoft, p.Accent, 0.22f) : hover ? Mix(p.AccentSoft, p.Accent, 0.12f) : p.AccentSoft;
				border = Mix(fill, p.Accent, 0.3f);
				text = Enabled ? p.Accent : p.Faint;
				break;
			}
			using (GraphicsPath path = RoundRect(shape, radius))
			{
				using (SolidBrush brush = new SolidBrush(fill))
				{
					g.FillPath(brush, path);
				}
				if (border != fill)
				{
					using GraphicsPath edge = RoundRect(new RectangleF(shape.X + 0.5f, shape.Y + 0.5f, shape.Width - 1f, shape.Height - 1f), radius);
					using Pen pen = new Pen(border, 1f);
					g.DrawPath(pen, edge);
				}
			}
			if (Focused && ShowFocusCues)
			{
				using GraphicsPath focus = RoundRect(new RectangleF(ring / 2f, ring / 2f, Width - ring, Height - ring), radius + ring / 2f);
				using Pen pen = new Pen(Color.FromArgb(150, p.Accent), ring);
				g.DrawPath(pen, focus);
			}
			TextRenderer.DrawText(g, Text, TextFont, Rectangle.Round(shape), text, TextFormatFlags.HorizontalCenter | LineFlags);
		}
	}

	/// <summary>받을 기기 카드 (SendDialog와 같음): 선택 = 강조 테두리 + 연한 강조 배경, 온라인 = 꽉 찬 점 / 오프라인 = 빈 테두리 점.</summary>
	private sealed class DeviceCard : Control
	{
		private readonly ClipboardForm owner;

		private bool hover;

		internal string Id { get; }

		internal string Label { get; }

		internal bool Online { get; }

		public DeviceCard(ClipboardForm owner, string id, string label, bool online)
		{
			this.owner = owner;
			Id = id;
			Label = label;
			Online = online;
			SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.StandardClick, true);
			SetStyle(ControlStyles.Selectable, false);
			TabStop = false;
			Cursor = Cursors.Hand;
			AccessibleRole = AccessibleRole.RadioButton;
			UpdateAccessibility();
		}

		private bool IsSelected => owner.selected == Id;

		internal void UpdateAccessibility()
		{
			AccessibleName = Label + (Online ? " · 연결됨" : " · 오프라인") + (IsSelected ? " · 선택됨" : "");
		}

		protected override void OnMouseEnter(EventArgs e)
		{
			hover = true;
			Invalidate();
			base.OnMouseEnter(e);
		}

		protected override void OnMouseLeave(EventArgs e)
		{
			hover = false;
			Invalidate();
			base.OnMouseLeave(e);
		}

		protected override void OnPaint(PaintEventArgs e)
		{
			Palette p = owner.palette;
			Graphics g = e.Graphics;
			g.Clear(Parent?.BackColor ?? p.Surface);
			Smooth(g);
			bool selected = IsSelected;
			float width = selected ? Math.Max(2, owner.S(2)) : Math.Max(1, owner.S(1));
			float radius = owner.S(10);
			RectangleF card = new RectangleF(width / 2f, width / 2f, Width - width, Height - width);
			Color fill = selected ? p.AccentSoft : hover ? p.Subtle : p.Surface;
			Color border = selected ? p.Accent : hover ? p.BorderStrong : p.Border;
			using (GraphicsPath path = RoundRect(card, radius))
			{
				using (SolidBrush brush = new SolidBrush(fill))
				{
					g.FillPath(brush, path);
				}
				using Pen pen = new Pen(border, width);
				g.DrawPath(pen, path);
			}
			// 키보드로 목록에 들어왔을 때: 선택한 카드 안쪽에 포커스 테두리
			if (selected && owner.deviceList.Focused && ShowFocusCues)
			{
				float inset = owner.S(4);
				using GraphicsPath focus = RoundRect(new RectangleF(inset, inset, Width - inset * 2f, Height - inset * 2f), Math.Max(1f, radius - inset / 2f));
				using Pen pen = new Pen(Color.FromArgb(150, p.Accent), 1f)
				{
					DashStyle = DashStyle.Dot
				};
				g.DrawPath(pen, focus);
			}
			// 라디오 표시 (선택을 색만이 아니라 모양으로도 구분)
			float radio = owner.S(18);
			float radioLeft = owner.S(16);
			float radioTop = (Height - radio) / 2f;
			if (selected)
			{
				float stroke = Math.Max(2, owner.S(2));
				using Pen pen = new Pen(p.Accent, stroke);
				g.DrawEllipse(pen, radioLeft + stroke / 2f, radioTop + stroke / 2f, radio - stroke, radio - stroke);
				float inner = owner.S(8);
				using SolidBrush brush = new SolidBrush(p.Accent);
				g.FillEllipse(brush, radioLeft + (radio - inner) / 2f, radioTop + (radio - inner) / 2f, inner, inner);
			}
			else
			{
				float stroke = Math.Max(1.5f, owner.S(1.5f));
				using Pen pen = new Pen(p.BorderStrong, stroke);
				g.DrawEllipse(pen, radioLeft + stroke / 2f, radioTop + stroke / 2f, radio - stroke, radio - stroke);
			}
			int textLeft = (int)(radioLeft + radio) + owner.S(14);
			int textWidth = Math.Max(0, Width - textLeft - owner.S(16));
			int nameHeight = LineHeight(owner.nameFont);
			int stateHeight = LineHeight(owner.smallFont);
			int top = (Height - nameHeight - owner.S(3) - stateHeight) / 2;
			TextRenderer.DrawText(g, Label, owner.nameFont, new Rectangle(textLeft, top, textWidth, nameHeight), Online ? p.Text : p.Muted, LineFlags);
			// 상태: 온라인 = 꽉 찬 점 + 연결됨, 오프라인 = 속이 빈 테두리 점 + 오프라인
			int stateTop = top + nameHeight + owner.S(3);
			float dot = owner.S(8);
			float dotTop = stateTop + (stateHeight - dot) / 2f;
			if (Online)
			{
				using SolidBrush brush = new SolidBrush(p.On);
				g.FillEllipse(brush, textLeft, dotTop, dot, dot);
			}
			else
			{
				float stroke = Math.Max(1.5f, owner.S(1.5f));
				using Pen pen = new Pen(p.Off, stroke);
				g.DrawEllipse(pen, textLeft + stroke / 2f, dotTop + stroke / 2f, dot - stroke, dot - stroke);
			}
			int stateLeft = textLeft + (int)dot + owner.S(6);
			TextRenderer.DrawText(g, Online ? "연결됨" : "오프라인", owner.smallFont, new Rectangle(stateLeft, stateTop, Math.Max(0, Width - stateLeft - owner.S(16)), stateHeight), Online ? p.On : p.Faint, LineFlags);
		}
	}

	/// <summary>받은 글자 한 개: 보낸 기기 · 시각, 두 줄 미리보기, 오른쪽 위 [복사]. 두 번 클릭해도 복사합니다.</summary>
	private sealed class ReceivedCard : Control
	{
		private readonly ClipboardForm owner;

		private readonly string sender;

		private readonly string when;

		private readonly string preview;

		internal string Id { get; }

		internal FlatButton CopyButton { get; }

		public ReceivedCard(ClipboardForm owner, ClipboardMessage message)
		{
			this.owner = owner;
			Id = message.Id;
			sender = string.IsNullOrWhiteSpace(message.Sender) ? "기기" : message.Sender;
			when = When(message.Created);
			preview = Preview(message.Text);
			SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.StandardClick | ControlStyles.StandardDoubleClick, true);
			SetStyle(ControlStyles.Selectable, false);
			TabStop = false;
			AccessibleRole = AccessibleRole.ListItem;
			AccessibleName = sender + " · " + when + " · " + (preview.Length > 80 ? preview.Substring(0, 80) + "…" : preview);
			CopyButton = new FlatButton(owner, ButtonKind.Soft, "복사");
			CopyButton.Click += (object? _, EventArgs _) => owner.CopyMessage(Id);
			Controls.Add(CopyButton);
			UpdateCopyLabel();
		}

		internal Color Fill => owner.highlightId == Id ? owner.palette.AccentSoft : owner.palette.Surface;

		internal void UpdateCopyLabel()
		{
			string text = owner.copiedId == Id ? "복사됨" : "복사";
			if (CopyButton.Text != text)
			{
				CopyButton.Text = text;
				LayoutButton();
			}
			CopyButton.AccessibleName = text + " · " + sender + " · " + when;
		}

		private void LayoutButton()
		{
			// 기본 Control 생성자에서 레이아웃이 먼저 불릴 수 있습니다.
			if (CopyButton == null)
			{
				return;
			}
			int width = Math.Max(CopyButton.PreferredWidth(), owner.S(72));
			CopyButton.Bounds = new Rectangle(Width - owner.S(10) - width, owner.S(10), width, owner.S(30));
		}

		protected override void OnLayout(LayoutEventArgs e)
		{
			base.OnLayout(e);
			LayoutButton();
		}

		protected override void OnDoubleClick(EventArgs e)
		{
			base.OnDoubleClick(e);
			owner.CopyMessage(Id);
		}

		protected override void OnPaint(PaintEventArgs e)
		{
			Palette p = owner.palette;
			Graphics g = e.Graphics;
			g.Clear(Parent?.BackColor ?? p.Surface);
			Smooth(g);
			bool lit = owner.highlightId == Id;
			float width = lit ? Math.Max(2, owner.S(2)) : Math.Max(1, owner.S(1));
			RectangleF card = new RectangleF(width / 2f, width / 2f, Width - width, Height - width);
			using (GraphicsPath path = RoundRect(card, owner.S(10)))
			{
				using (SolidBrush brush = new SolidBrush(Fill))
				{
					g.FillPath(brush, path);
				}
				using Pen pen = new Pen(lit ? p.Accent : p.Border, width);
				g.DrawPath(pen, path);
			}
			int pad = owner.S(14);
			int buttonTop = owner.S(10);
			int buttonHeight = owner.S(30);
			int nameHeight = LineHeight(owner.nameFont);
			int headerTop = buttonTop + (buttonHeight - nameHeight) / 2;
			int headerRight = CopyButton.Left - owner.S(10);
			int senderWidth = Math.Min(TextRenderer.MeasureText(sender, owner.nameFont, default(Size), TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding).Width, Math.Max(0, headerRight - pad));
			TextRenderer.DrawText(g, sender, owner.nameFont, new Rectangle(pad, headerTop, senderWidth, nameHeight), p.Text, LineFlags);
			int whenLeft = pad + senderWidth + owner.S(6);
			TextRenderer.DrawText(g, "· " + when, owner.smallFont, new Rectangle(whenLeft, headerTop, Math.Max(0, headerRight - whenLeft), nameHeight), p.Faint, LineFlags);
			int previewTop = buttonTop + buttonHeight + owner.S(6);
			TextRenderer.DrawText(g, preview, owner.bodyFont, new Rectangle(pad, previewTop, Math.Max(0, Width - pad * 2), owner.bodyLine * 2), p.Text, WrapFlags);
		}
	}

	/// <summary>목록이 비었을 때 보이는 점선 안내 상자.</summary>
	private sealed class EmptyNote : Control
	{
		private readonly ClipboardForm owner;

		private readonly string title;

		private readonly string body;

		public EmptyNote(ClipboardForm owner, string title, string body)
		{
			this.owner = owner;
			this.title = title;
			this.body = body;
			SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
			SetStyle(ControlStyles.Selectable, false);
			TabStop = false;
			AccessibleRole = AccessibleRole.StaticText;
			AccessibleName = title + ". " + body;
		}

		protected override void OnPaint(PaintEventArgs e)
		{
			Palette p = owner.palette;
			Graphics g = e.Graphics;
			g.Clear(Parent?.BackColor ?? p.Surface);
			Smooth(g);
			using (GraphicsPath path = RoundRect(new RectangleF(1f, 1f, Width - 2f, Height - 2f), owner.S(12)))
			{
				using (SolidBrush brush = new SolidBrush(p.Subtle))
				{
					g.FillPath(brush, path);
				}
				using Pen pen = new Pen(p.BorderStrong, Math.Max(1f, owner.S(1.5f)))
				{
					DashStyle = DashStyle.Dash
				};
				g.DrawPath(pen, path);
			}
			int pad = owner.S(20);
			int titleHeight = LineHeight(owner.nameFont);
			int bodyLine = LineHeight(owner.smallFont);
			int bodyHeight = bodyLine * 2;
			int top = Math.Max(owner.S(12), (Height - titleHeight - owner.S(6) - bodyHeight) / 2);
			TextRenderer.DrawText(g, title, owner.nameFont, new Rectangle(pad, top, Math.Max(0, Width - pad * 2), titleHeight), p.Text, TextFormatFlags.HorizontalCenter | LineFlags);
			int bodyTop = top + titleHeight + owner.S(6);
			TextRenderer.DrawText(g, body, owner.smallFont, new Rectangle(pad, bodyTop, Math.Max(0, Width - pad * 2), Math.Max(0, Math.Min(bodyHeight, Height - bodyTop - owner.S(6)))), p.Muted, TextFormatFlags.HorizontalCenter | WrapFlags);
		}
	}

	/// <summary>둥근 테두리 안의 여러 줄 글자 칸. 글자 칸에 포커스가 있으면 초록 테두리.</summary>
	private sealed class EditorFrame : Control
	{
		private readonly ClipboardForm owner;

		private readonly TextBox editor;

		private bool hover;

		public EditorFrame(ClipboardForm owner, TextBox editor)
		{
			this.owner = owner;
			this.editor = editor;
			SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
			SetStyle(ControlStyles.Selectable, false);
			TabStop = false;
			Cursor = Cursors.IBeam;
			Controls.Add(editor);
			editor.GotFocus += (object? _, EventArgs _) => Invalidate();
			editor.LostFocus += (object? _, EventArgs _) => Invalidate();
			editor.MouseEnter += (object? _, EventArgs _) => SetHover(true);
			editor.MouseLeave += (object? _, EventArgs _) => SetHover(false);
		}

		private void SetHover(bool value)
		{
			if (hover != value)
			{
				hover = value;
				Invalidate();
			}
		}

		protected override void OnMouseEnter(EventArgs e)
		{
			SetHover(true);
			base.OnMouseEnter(e);
		}

		protected override void OnMouseLeave(EventArgs e)
		{
			SetHover(false);
			base.OnMouseLeave(e);
		}

		protected override void OnMouseDown(MouseEventArgs e)
		{
			base.OnMouseDown(e);
			editor.Focus();
		}

		protected override void OnLayout(LayoutEventArgs e)
		{
			base.OnLayout(e);
			if (editor == null)
			{
				return;
			}
			int x = owner.S(14);
			int y = owner.S(10);
			editor.Bounds = new Rectangle(x, y, Math.Max(0, Width - x - owner.S(6)), Math.Max(0, Height - y * 2));
		}

		protected override void OnPaint(PaintEventArgs e)
		{
			Palette p = owner.palette;
			Graphics g = e.Graphics;
			g.Clear(Parent?.BackColor ?? p.Surface);
			Smooth(g);
			bool focused = editor.Focused;
			float width = focused ? Math.Max(2, owner.S(2)) : Math.Max(1, owner.S(1));
			RectangleF box = new RectangleF(width / 2f, width / 2f, Width - width, Height - width);
			using GraphicsPath path = RoundRect(box, owner.S(10));
			using (SolidBrush brush = new SolidBrush(p.Surface))
			{
				g.FillPath(brush, path);
			}
			using Pen pen = new Pen(focused ? p.Accent : hover ? p.BorderStrong : p.Border, width);
			g.DrawPath(pen, path);
		}
	}

	private class ScrollPanel : Panel
	{
		public ScrollPanel()
		{
			DoubleBuffered = true;
		}
	}

	/// <summary>받을 기기 목록. Tab으로 들어오면 화살표로 기기를 고릅니다.</summary>
	private sealed class DeviceListPanel : ScrollPanel
	{
		private readonly ClipboardForm owner;

		public DeviceListPanel(ClipboardForm owner)
		{
			this.owner = owner;
			SetStyle(ControlStyles.Selectable, true);
			TabStop = true;
		}

		protected override void OnGotFocus(EventArgs e)
		{
			base.OnGotFocus(e);
			InvalidateSelected();
		}

		protected override void OnLostFocus(EventArgs e)
		{
			base.OnLostFocus(e);
			InvalidateSelected();
		}

		private void InvalidateSelected()
		{
			foreach (DeviceCard card in owner.deviceCards)
			{
				card.Invalidate();
			}
		}
	}

	/// <summary>아래 줄 (연한 배경 + 위쪽 구분선): 왼쪽은 안내 · 결과 문구, 오른쪽은 [붙여넣기] [보내기].</summary>
	private sealed class FooterPanel : Panel
	{
		private readonly ClipboardForm owner;

		public FooterPanel(ClipboardForm owner)
		{
			this.owner = owner;
			DoubleBuffered = true;
			ResizeRedraw = true;
			AccessibleRole = AccessibleRole.Grouping;
		}

		protected override void OnPaint(PaintEventArgs e)
		{
			base.OnPaint(e);
			Palette p = owner.palette;
			Graphics g = e.Graphics;
			using (Pen pen = new Pen(p.Border, 1f))
			{
				g.DrawLine(pen, 0, 0, Width, 0);
			}
			int pad = owner.S(24);
			int right = owner.pasteButton.Left - owner.S(16);
			int lineHeight = LineHeight(owner.smallFont);
			int height = Math.Min(lineHeight * 2, Height);
			Rectangle area = new Rectangle(pad, (Height - height) / 2, Math.Max(0, right - pad), height);
			// 한 줄이면 가운데에, 길면 두 줄까지
			int needed = TextRenderer.MeasureText(owner.status, owner.smallFont, new Size(Math.Max(1, area.Width), int.MaxValue), WrapFlags).Height;
			if (needed <= lineHeight)
			{
				area = new Rectangle(area.Left, (Height - lineHeight) / 2, area.Width, lineHeight);
			}
			TextRenderer.DrawText(g, owner.status, owner.smallFont, area, owner.statusError ? p.Danger : p.Muted, WrapFlags);
		}
	}
}
