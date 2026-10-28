using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;
using static Ahna.UiTheme;

namespace Ahna;

/// <summary>
/// ‘아나로 보내기’ 창 (탐색기 우클릭 · 트레이 ‘파일 / 폴더 보내기’ · 웹 화면의 파일 선택).
/// 화면만 담당합니다. 실제 보내기는 <see cref="SendRequested"/>(TrayContext)가 합니다.
/// Windows 앱 테마(라이트/다크)를 따르고, 시스템 DPI에 맞춰 크기를 정합니다.
/// 색 · 둥근 모양 · 다크 모드 도구는 UiTheme.cs (ClipboardForm과 공용).
/// </summary>
internal sealed class SendDialog : Form
{
	private const int VisibleRows = 4;

	private const TextFormatFlags LineFlags = TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis | TextFormatFlags.VerticalCenter;

	private readonly Func<(string Id, string Name)[]> source;

	private readonly bool pathsGiven;

	private string[] paths;

	private string summary;

	private (string Id, string Name)[] shown = Array.Empty<(string Id, string Name)>();

	private readonly List<DeviceRow> rows = new List<DeviceRow>();

	private string? selected;

	private string? selectedLabel;

	private bool busy;

	private bool dark;

	private Palette palette = LightPalette;

	private readonly Font titleFont = new Font("Segoe UI", 12f, FontStyle.Bold);

	private readonly Font bodyFont = new Font("Segoe UI", 10f);

	private readonly Font nameFont = new Font("Segoe UI Semibold", 10f);

	private readonly Font smallFont = new Font("Segoe UI", 9f);

	private readonly Font labelFont = new Font("Segoe UI Semibold", 9f);

	private readonly Font buttonBoldFont = new Font("Segoe UI", 10f, FontStyle.Bold);

	private readonly ListPanel listPanel;

	private readonly EmptyView empty;

	private readonly FooterPanel footer;

	private readonly FlatButton addButton;

	private readonly FlatButton cancelButton;

	private readonly FlatButton fileButton;

	private readonly FlatButton folderButton;

	private readonly FlatButton sendButton;

	private readonly System.Windows.Forms.Timer timer;

	private int labelTop;

	/// <summary>보낼 파일·폴더. 처음에 받은 경로이거나, 창에서 고른 경로입니다.</summary>
	public string[] Paths => paths;

	/// <summary>고른 받을 기기의 id (SendTargets의 Id).</summary>
	public string? SelectedTarget => selected;

	/// <summary>[보내기]를 눌렀을 때 (TrayContext의 준비/전송 로직).</summary>
	[System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
	public Func<Task>? SendRequested { get; set; }

	/// <summary>[기기 추가] / [옵션 열기]를 눌렀을 때.</summary>
	[System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
	public Action? OptionsRequested { get; set; }

	/// <summary>전송 준비 중에는 버튼을 잠그고 제목에 표시합니다.</summary>
	[System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
	public bool Busy
	{
		get => busy;
		set
		{
			busy = value;
			Text = value ? "전송 준비 중…" : "아나로 보내기";
			UpdateButtons();
		}
	}

	public SendDialog(string[] paths, Func<(string Id, string Name)[]> source, string? target)
	{
		this.source = source;
		this.paths = paths;
		pathsGiven = paths.Length != 0;
		selected = target;
		summary = Summarize(paths);
		dark = ReadDarkMode();
		palette = dark ? DarkPalette : LightPalette;
		SuspendLayout();
		Text = "아나로 보내기";
		Icon = Program.AppIcon;
		AutoScaleMode = AutoScaleMode.None;
		Font = bodyFont;
		FormBorderStyle = FormBorderStyle.FixedDialog;
		MaximizeBox = false;
		MinimizeBox = false;
		StartPosition = FormStartPosition.CenterScreen;
		TopMost = true;
		KeyPreview = true;
		SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
		listPanel = new ListPanel
		{
			AutoScroll = true,
			TabStop = false,
			AccessibleName = "받을 기기",
			AccessibleRole = AccessibleRole.List
		};
		empty = new EmptyView(this)
		{
			Visible = false
		};
		listPanel.Controls.Add(empty);
		footer = new FooterPanel(this);
		addButton = new FlatButton(this, ButtonKind.Text, "+ 기기 추가")
		{
			AccessibleName = "기기 추가 · 옵션 열기"
		};
		cancelButton = new FlatButton(this, ButtonKind.Secondary, "취소");
		fileButton = new FlatButton(this, ButtonKind.Secondary, "파일 선택");
		folderButton = new FlatButton(this, ButtonKind.Secondary, "폴더 선택")
		{
			AccessibleDescription = "폴더는 ZIP으로 압축해 보냅니다"
		};
		sendButton = new FlatButton(this, ButtonKind.Primary, "보내기");
		fileButton.Visible = folderButton.Visible = !pathsGiven;
		// 탭 순서: 기기 추가 → 보내기 → 파일 선택 → 폴더 선택 → 취소
		addButton.TabIndex = 0;
		sendButton.TabIndex = 0;
		fileButton.TabIndex = 1;
		folderButton.TabIndex = 2;
		cancelButton.TabIndex = 3;
		listPanel.TabIndex = 1;
		footer.TabIndex = 2;
		footer.Controls.AddRange(new Control[] { sendButton, fileButton, folderButton, cancelButton });
		Controls.AddRange(new Control[] { addButton, listPanel, footer });
		addButton.Click += (object? _, EventArgs _) => OptionsRequested?.Invoke();
		empty.OptionsClicked += () => OptionsRequested?.Invoke();
		cancelButton.Click += (object? _, EventArgs _) => Close();
		fileButton.Click += (object? _, EventArgs _) => Pick(folder: false);
		folderButton.Click += (object? _, EventArgs _) => Pick(folder: true);
		sendButton.Click += (object? _, EventArgs _) => Send();
		listPanel.HandleCreated += (object? _, EventArgs _) => ApplyScrollbarTheme();
		ApplyTheme();
		RefreshTargets(force: true);
		ResumeLayout(performLayout: false);
		// 받을 기기 목록은 2.5초마다 새로 읽습니다 (연결·오프라인 변화 반영).
		timer = new System.Windows.Forms.Timer
		{
			Interval = 2500
		};
		timer.Tick += (object? _, EventArgs _) => RefreshTargets(force: false);
		timer.Start();
		SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
	}

	private int S(float value)
	{
		return (int)Math.Round(value * DeviceDpi / 96f);
	}

	private static string FormatSize(long n)
	{
		if (n < 1024)
		{
			return n + " B";
		}
		if (n < 1048576)
		{
			return (n / 1024.0).ToString("0.0", CultureInfo.InvariantCulture) + " KB";
		}
		if (n < 1073741824)
		{
			return (n / 1048576.0).ToString("0.0", CultureInfo.InvariantCulture) + " MB";
		}
		return (n / 1073741824.0).ToString("0.00", CultureInfo.InvariantCulture) + " GB";
	}

	// "파일 2개 · 4.1 MB" / "폴더 1개" / "파일 1개 · 폴더 1개 · 12.0 KB"
	private static string Summarize(string[] paths)
	{
		if (paths.Length == 0)
		{
			return "보낼 파일을 고르세요";
		}
		int files = 0;
		int folders = 0;
		long bytes = 0;
		foreach (string path in paths)
		{
			try
			{
				if (Directory.Exists(path))
				{
					folders++;
				}
				else
				{
					files++;
					bytes += new FileInfo(path).Length;
				}
			}
			catch
			{
			}
		}
		List<string> parts = new List<string>();
		if (files > 0)
		{
			parts.Add($"파일 {files}개");
		}
		if (folders > 0)
		{
			parts.Add($"폴더 {folders}개 (ZIP)");
		}
		if (files > 0)
		{
			parts.Add(FormatSize(bytes));
		}
		return parts.Count == 0 ? $"{paths.Length}개 항목" : string.Join(" · ", parts);
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
		bool hadFocus = listPanel.ContainsFocus;
		listPanel.SuspendLayout();
		foreach (DeviceRow old in rows)
		{
			listPanel.Controls.Remove(old);
			old.Dispose();
		}
		rows.Clear();
		foreach ((string Id, string Name) d in list)
		{
			DeviceRow row = new DeviceRow(this, d.Id, DisplayName(d.Name), !IsOffline(d.Name));
			row.MouseDown += (object? _, MouseEventArgs e) =>
			{
				if (e.Button == MouseButtons.Left)
				{
					SelectDevice(row.Id);
				}
			};
			row.DoubleClick += (object? _, EventArgs _) => Send();
			rows.Add(row);
			listPanel.Controls.Add(row);
		}
		empty.Visible = rows.Count == 0;
		addButton.Visible = rows.Count != 0;
		selectedLabel = rows.FirstOrDefault((DeviceRow r) => r.Id == selected)?.Label;
		listPanel.ResumeLayout(performLayout: false);
		LayoutDialog();
		UpdateButtons();
		if (hadFocus && !busy)
		{
			sendButton.Focus();
		}
	}

	private void SelectDevice(string id)
	{
		if (busy || selected == id)
		{
			return;
		}
		selected = id;
		DeviceRow? current = null;
		foreach (DeviceRow row in rows)
		{
			row.UpdateAccessibility();
			row.Invalidate();
			if (row.Id == id)
			{
				current = row;
			}
		}
		selectedLabel = current?.Label;
		if (current != null)
		{
			listPanel.ScrollControlIntoView(current);
		}
		UpdateButtons();
	}

	private void MoveSelection(int delta)
	{
		if (rows.Count == 0 || busy)
		{
			return;
		}
		int index = rows.FindIndex((DeviceRow r) => r.Id == selected);
		index = index < 0 ? 0 : Math.Clamp(index + delta, 0, rows.Count - 1);
		SelectDevice(rows[index].Id);
	}

	private string SendText()
	{
		if (busy)
		{
			return "준비 중…";
		}
		string? name = selectedLabel;
		if (paths.Length == 0 || name == null)
		{
			return "보내기";
		}
		if (name.Length > 16)
		{
			name = name.Substring(0, 15) + "…";
		}
		return $"{name}에 {paths.Length}개 보내기";
	}

	private void UpdateButtons()
	{
		sendButton.Text = SendText();
		sendButton.Enabled = !busy && paths.Length != 0 && selected != null;
		fileButton.Enabled = folderButton.Enabled = !busy;
		LayoutFooter();
	}

	private void LayoutDialog()
	{
		int width = S(480);
		int pad = S(24);
		int headerBottom = pad + S(44);
		labelTop = headerBottom + S(20);
		int labelHeight = S(28);
		addButton.Size = new Size(addButton.PreferredWidth(), labelHeight);
		addButton.Location = new Point(width - pad - addButton.Width + S(8), labelTop);
		int listTop = labelTop + labelHeight + S(6);
		int rowHeight = S(60);
		int gap = S(8);
		int shownRows = Math.Clamp(rows.Count, 1, VisibleRows);
		int listHeight = rows.Count == 0 ? S(150) : shownRows * rowHeight + (shownRows - 1) * gap;
		listPanel.Bounds = new Rectangle(pad, listTop, width - pad * 2, listHeight);
		bool scrolling = rows.Count > VisibleRows;
		int rowWidth = listPanel.Width - (scrolling ? SystemInformation.VerticalScrollBarWidth + S(6) : 0);
		listPanel.AutoScrollPosition = new Point(0, 0);
		for (int i = 0; i < rows.Count; i++)
		{
			rows[i].Bounds = new Rectangle(0, i * (rowHeight + gap), rowWidth, rowHeight);
		}
		empty.Bounds = new Rectangle(0, 0, listPanel.Width, listHeight);
		int footerTop = listTop + listHeight + S(24);
		int footerHeight = S(72);
		footer.Bounds = new Rectangle(0, footerTop, width, footerHeight);
		ClientSize = new Size(width, footerTop + footerHeight);
		DeviceRow? current = rows.FirstOrDefault((DeviceRow r) => r.Id == selected);
		if (current != null)
		{
			listPanel.ScrollControlIntoView(current);
		}
		LayoutFooter();
		Invalidate();
	}

	private void LayoutFooter()
	{
		int pad = S(24);
		int gap = S(8);
		int height = S(40);
		int top = (footer.Height - height) / 2;
		List<FlatButton> secondary = new List<FlatButton> { cancelButton };
		if (!pathsGiven)
		{
			secondary.Add(fileButton);
			secondary.Add(folderButton);
		}
		int x = pad;
		foreach (FlatButton button in secondary)
		{
			button.Bounds = new Rectangle(x, top, button.PreferredWidth(), height);
			x = button.Right + gap;
		}
		int available = footer.Width - pad - x;
		int sendWidth = Math.Min(Math.Max(sendButton.PreferredWidth(), S(120)), Math.Max(available, S(80)));
		sendButton.Bounds = new Rectangle(footer.Width - pad - sendWidth, top, sendWidth, height);
	}

	private void Pick(bool folder)
	{
		if (busy)
		{
			return;
		}
		string[]? picked = null;
		if (folder)
		{
			using FolderBrowserDialog dialog = new FolderBrowserDialog
			{
				Description = "보낼 폴더를 선택하세요 · ZIP으로 압축해 보냅니다",
				UseDescriptionForTitle = true
			};
			if (dialog.ShowDialog(this) == DialogResult.OK)
			{
				picked = new string[1] { dialog.SelectedPath };
			}
		}
		else
		{
			using OpenFileDialog dialog = new OpenFileDialog
			{
				Multiselect = true,
				Title = "보낼 파일 선택"
			};
			if (dialog.ShowDialog(this) == DialogResult.OK)
			{
				picked = dialog.FileNames;
			}
		}
		if (IsDisposed || picked == null || picked.Length == 0)
		{
			return;
		}
		paths = picked;
		summary = Summarize(paths);
		Invalidate();
		UpdateButtons();
		if (sendButton.Enabled)
		{
			sendButton.Focus();
		}
	}

	private async void Send()
	{
		if (busy || paths.Length == 0 || selected == null || SendRequested == null)
		{
			return;
		}
		try
		{
			await SendRequested();
		}
		catch (Exception ex)
		{
			if (!IsDisposed)
			{
				MessageBox.Show(this, ex.Message, "전송 준비 실패");
			}
		}
	}

	protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
	{
		switch (keyData)
		{
		case Keys.Escape:
			Close();
			return true;
		case Keys.Return:
			if (ActiveControl is FlatButton focused && focused != sendButton)
			{
				focused.PerformClick();
			}
			else
			{
				sendButton.PerformClick();
			}
			return true;
		case Keys.Up:
		case Keys.Left:
			MoveSelection(-1);
			return true;
		case Keys.Down:
		case Keys.Right:
			MoveSelection(1);
			return true;
		default:
			return base.ProcessCmdKey(ref msg, keyData);
		}
	}

	protected override void OnShown(EventArgs e)
	{
		base.OnShown(e);
		if (sendButton.Enabled)
		{
			sendButton.Focus();
		}
		else if (!pathsGiven)
		{
			fileButton.Focus();
		}
		else
		{
			cancelButton.Focus();
		}
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
		int textWidth = ClientSize.Width - textLeft - pad;
		int titleHeight = LineHeight(titleFont);
		int summaryHeight = LineHeight(bodyFont);
		int top = pad + (tile - titleHeight - S(2) - summaryHeight) / 2;
		TextRenderer.DrawText(g, "아나로 보내기", titleFont, new Rectangle(textLeft, top, textWidth, titleHeight), palette.Text, LineFlags);
		TextRenderer.DrawText(g, summary, bodyFont, new Rectangle(textLeft, top + titleHeight + S(2), textWidth, summaryHeight), palette.Muted, LineFlags);
		TextRenderer.DrawText(g, "받을 기기", labelFont, new Rectangle(pad, labelTop, S(200), S(28)), palette.Muted, LineFlags);
	}

	private void ApplyTheme()
	{
		palette = dark ? DarkPalette : LightPalette;
		BackColor = palette.Surface;
		ForeColor = palette.Text;
		listPanel.BackColor = palette.Surface;
		empty.BackColor = palette.Surface;
		footer.BackColor = palette.Subtle;
		if (IsHandleCreated)
		{
			SetDarkTitleBar(Handle, dark);
		}
		ApplyScrollbarTheme();
		Invalidate(invalidateChildren: true);
	}

	private void ApplyScrollbarTheme()
	{
		if (!listPanel.IsHandleCreated)
		{
			return;
		}
		try
		{
			SetWindowTheme(listPanel.Handle, dark ? "DarkMode_Explorer" : "Explorer", null);
		}
		catch
		{
		}
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

	private enum ButtonKind
	{
		Primary,
		Secondary,
		Text
	}

	/// <summary>둥근 모서리 평면 버튼 (기본 3D 버튼 대신).</summary>
	private sealed class FlatButton : Control
	{
		private readonly SendDialog owner;

		private readonly ButtonKind kind;

		private bool hover;

		private bool down;

		public FlatButton(SendDialog owner, ButtonKind kind, string text)
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

		private Font TextFont => kind == ButtonKind.Primary ? owner.buttonBoldFont : owner.bodyFont;

		public int PreferredWidth()
		{
			int text = TextRenderer.MeasureText(Text, TextFont, default(Size), TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding).Width;
			return text + owner.S(kind == ButtonKind.Text ? 20 : 36);
		}

		public void PerformClick()
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
			Color back = Parent?.BackColor ?? p.Surface;
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
				fill = Enabled && (hover || down) ? Mix(back, p.Accent, down ? 0.16f : 0.10f) : back;
				border = fill;
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

	/// <summary>받을 기기 한 줄: 둥근 카드, 선택 = 강조 테두리 + 연한 강조 배경, 온라인 = 꽉 찬 점 / 오프라인 = 빈 테두리 점.</summary>
	private sealed class DeviceRow : Control
	{
		private readonly SendDialog owner;

		private bool hover;

		public string Id { get; }

		public string Label { get; }

		public bool Online { get; }

		public DeviceRow(SendDialog owner, string id, string label, bool online)
		{
			this.owner = owner;
			Id = id;
			Label = label;
			Online = online;
			SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.StandardClick | ControlStyles.StandardDoubleClick, true);
			SetStyle(ControlStyles.Selectable, false);
			TabStop = false;
			Cursor = Cursors.Hand;
			AccessibleRole = AccessibleRole.RadioButton;
			UpdateAccessibility();
		}

		private bool IsSelected => owner.selected == Id;

		public void UpdateAccessibility()
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
			int textWidth = Width - textLeft - owner.S(16);
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

	/// <summary>받을 기기가 없을 때 목록 자리에 보이는 안내.</summary>
	private sealed class EmptyView : Control
	{
		private readonly SendDialog owner;

		private readonly FlatButton options;

		public event Action? OptionsClicked;

		public EmptyView(SendDialog owner)
		{
			this.owner = owner;
			options = new FlatButton(owner, ButtonKind.Text, "옵션에서 기기 추가");
			SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
			options.Click += (object? _, EventArgs _) => OptionsClicked?.Invoke();
			Controls.Add(options);
			AccessibleRole = AccessibleRole.StaticText;
			AccessibleName = "받을 기기가 없습니다. 옵션에서 기기를 추가하세요.";
		}

		private int TitleTop => owner.S(20);

		protected override void OnLayout(LayoutEventArgs e)
		{
			base.OnLayout(e);
			int height = owner.S(32);
			int width = options.PreferredWidth();
			options.Bounds = new Rectangle((Width - width) / 2, Height - height - owner.S(14), width, height);
		}

		protected override void OnPaint(PaintEventArgs e)
		{
			Palette p = owner.palette;
			Graphics g = e.Graphics;
			g.Clear(Parent?.BackColor ?? p.Surface);
			Smooth(g);
			float radius = owner.S(12);
			using (GraphicsPath path = RoundRect(new RectangleF(1f, 1f, Width - 2f, Height - 2f), radius))
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
			TextRenderer.DrawText(g, "받을 기기가 없습니다", owner.nameFont, new Rectangle(pad, TitleTop, Width - pad * 2, titleHeight), p.Text, TextFormatFlags.HorizontalCenter | LineFlags);
			int bodyTop = TitleTop + titleHeight + owner.S(6);
			int bodyBottom = options.Top - owner.S(6);
			TextRenderer.DrawText(g, "다른 기기의 아나에서 이 PC의 연결 코드를 입력하거나,\n옵션에서 기기를 추가하세요.", owner.smallFont, new Rectangle(pad, bodyTop, Width - pad * 2, Math.Max(0, bodyBottom - bodyTop)), p.Muted, TextFormatFlags.HorizontalCenter | TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding);
		}
	}

	private sealed class ListPanel : Panel
	{
		public ListPanel()
		{
			DoubleBuffered = true;
		}
	}

	/// <summary>아래 버튼 줄 (연한 배경 + 위쪽 구분선).</summary>
	private sealed class FooterPanel : Panel
	{
		private readonly SendDialog owner;

		public FooterPanel(SendDialog owner)
		{
			this.owner = owner;
			DoubleBuffered = true;
			ResizeRedraw = true;
		}

		protected override void OnPaint(PaintEventArgs e)
		{
			base.OnPaint(e);
			using Pen pen = new Pen(owner.palette.Border, 1f);
			e.Graphics.DrawLine(pen, 0, 0, Width, 0);
		}
	}
}
