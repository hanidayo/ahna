using System;
using System.Collections;
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

/// <summary>근처 기기 · QR 창이 함께 쓰는 색(파랑 강조) · 글꼴 · 버튼.</summary>
internal static class NearbyUi
{
	internal sealed record NearPalette(Color Near, Color NearSoft, Color NearText);

	internal static readonly NearPalette LightNear = new(Hex(0x7c3aed), Hex(0xf1ebfe), Hex(0x6d28d9));

	internal static readonly NearPalette DarkNear = new(Hex(0xa78bfa), Hex(0x2b2140), Hex(0xc4b5fd));

	internal const TextFormatFlags LineFlags = TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis | TextFormatFlags.VerticalCenter;

	internal const TextFormatFlags CenterFlags = LineFlags | TextFormatFlags.HorizontalCenter;

	internal static string FormatSize(long n)
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

	/// <summary>"다운로드\Ahna" 처럼 짧게 (사용자 폴더 아래 다운로드면).</summary>
	internal static string ShortFolder(string path)
	{
		try
		{
			string downloads = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
			string full = Path.GetFullPath(path);
			if (full.StartsWith(downloads, StringComparison.OrdinalIgnoreCase))
			{
				return "다운로드" + full.Substring(downloads.Length);
			}
			return full;
		}
		catch
		{
			return path;
		}
	}

	internal static string Initial(string name)
	{
		string text = name.Trim();
		return text.Length == 0 ? "?" : char.IsSurrogate(text[0]) && text.Length > 1 ? text.Substring(0, 2) : text.Substring(0, 1).ToUpperInvariant();
	}

	internal static void FillRound(Graphics g, RectangleF r, float radius, Color fill, Color? border = null, float width = 1f)
	{
		using GraphicsPath path = RoundRect(r, radius);
		using (SolidBrush brush = new SolidBrush(fill))
		{
			g.FillPath(brush, path);
		}
		if (border is Color edge)
		{
			using Pen pen = new Pen(edge, width);
			g.DrawPath(pen, path);
		}
	}

	internal static void DrawCheck(Graphics g, RectangleF r, Color color, float width)
	{
		using Pen pen = new Pen(color, width)
		{
			StartCap = LineCap.Round,
			EndCap = LineCap.Round,
			LineJoin = LineJoin.Round
		};
		float s = r.Width / 24f;
		g.DrawLines(pen, new PointF[3]
		{
			new PointF(r.X + 5f * s, r.Y + 12.5f * s),
			new PointF(r.X + 10f * s, r.Y + 17f * s),
			new PointF(r.X + 19f * s, r.Y + 7f * s)
		});
	}

	internal static void DrawFileGlyph(Graphics g, RectangleF r, Color color, float width)
	{
		float s = r.Width / 24f;
		PointF P(float x, float y) => new PointF(r.X + x * s, r.Y + y * s);
		using Pen pen = new Pen(color, width)
		{
			LineJoin = LineJoin.Round,
			StartCap = LineCap.Round,
			EndCap = LineCap.Round
		};
		g.DrawLines(pen, new PointF[6] { P(14f, 2f), P(6f, 2f), P(4f, 4f), P(4f, 20f), P(20f, 20f), P(20f, 8f) });
		g.DrawLines(pen, new PointF[4] { P(14f, 2f), P(20f, 8f), P(14f, 8f), P(14f, 2f) });
	}
}

internal enum NearbyButtonKind
{
	Primary,
	Secondary,
	Text,
	Segment
}

/// <summary>둥근 평면 버튼 (SendDialog의 버튼과 같은 모양). Segment는 탭/세그먼트 한 칸입니다.</summary>
internal sealed class NearbyButton : Control
{
	private readonly NearbyButtonKind kind;

	private readonly Func<Palette> palette;

	private readonly Func<float, int> scale;

	private readonly Font font;

	private readonly Font boldFont;

	private bool hover;

	private bool down;

	private bool selected;

	public NearbyButton(NearbyButtonKind kind, string text, Func<Palette> palette, Func<float, int> scale, Font font, Font boldFont)
	{
		this.kind = kind;
		this.palette = palette;
		this.scale = scale;
		this.font = font;
		this.boldFont = boldFont;
		Text = text;
		SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable | ControlStyles.StandardClick, true);
		SetStyle(ControlStyles.StandardDoubleClick, false);
		TabStop = true;
		Cursor = Cursors.Hand;
		AccessibleRole = kind == NearbyButtonKind.Segment ? AccessibleRole.PageTab : AccessibleRole.PushButton;
		AccessibleName = text;
	}

	public bool IsSelected => selected;

	public void SetSelected(bool value)
	{
		if (selected != value)
		{
			selected = value;
			AccessibleDescription = value ? "선택됨" : null;
			Invalidate();
		}
	}

	private Font TextFont => kind == NearbyButtonKind.Primary || (kind == NearbyButtonKind.Segment && selected) ? boldFont : font;

	public int PreferredWidth()
	{
		int text = TextRenderer.MeasureText(Text, boldFont, default(Size), TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding).Width;
		return text + scale(kind == NearbyButtonKind.Text ? 20 : kind == NearbyButtonKind.Primary ? 48 : 36);
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
		Palette p = palette();
		Graphics g = e.Graphics;
		Color back = kind == NearbyButtonKind.Segment ? p.Subtle : Parent?.BackColor ?? p.Surface;
		g.Clear(back);
		Smooth(g);
		float ring = scale(2);
		RectangleF shape = new RectangleF(ring, ring, Width - ring * 2f, Height - ring * 2f);
		float radius = scale(8);
		Color fill;
		Color border;
		Color text;
		switch (kind)
		{
		case NearbyButtonKind.Primary:
			fill = !Enabled ? Mix(p.Accent, back, 0.55f) : (hover || down) ? p.AccentHover : p.Accent;
			border = fill;
			text = Enabled ? p.OnAccent : Mix(p.OnAccent, back, 0.35f);
			break;
		case NearbyButtonKind.Secondary:
			fill = !Enabled ? p.Surface : down ? Mix(p.Surface, p.Text, 0.08f) : hover ? Mix(p.Surface, p.Text, 0.04f) : p.Surface;
			border = Enabled && (hover || down) ? p.BorderStrong : p.Border;
			text = Enabled ? p.Text : p.Faint;
			break;
		case NearbyButtonKind.Segment:
			fill = selected ? p.Surface : (hover && Enabled) ? Mix(back, p.Text, 0.04f) : back;
			border = fill;
			text = !Enabled ? p.Faint : selected ? p.Text : p.Muted;
			if (selected)
			{
				using GraphicsPath shadow = RoundRect(new RectangleF(shape.X, shape.Y + 1f, shape.Width, shape.Height), radius);
				using SolidBrush shadowBrush = new SolidBrush(Color.FromArgb(40, 0, 0, 0));
				g.FillPath(shadowBrush, shadow);
			}
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
		TextRenderer.DrawText(g, Text, TextFont, Rectangle.Round(shape), text, NearbyUi.CenterFlags);
	}
}

/// <summary>
/// 받는 쪽 확인 창 (WinNearbyRequest 디자인): "OO에서 보내려고 합니다" · 파일 · 확인 숫자 · [거절] [받기] · 30초 뒤 자동 거절.
/// 근처 기기(Bluetooth) 제안과 QR로 받기 요청에 함께 씁니다. 결과는 <see cref="Answered"/>로 한 번만 알립니다.
/// </summary>
internal sealed class NearbyRequestForm : Form
{
	private readonly string sender;

	private readonly string origin;

	private readonly string? proximity;

	private readonly string fileTitle;

	private readonly string fileDetail;

	private readonly string code;

	private readonly Func<bool>? stillValid;

	private readonly DateTimeOffset deadline;

	private readonly NearbyButton declineButton;

	private readonly NearbyButton acceptButton;

	private readonly System.Windows.Forms.Timer timer;

	private readonly Font titleFont = new Font("Segoe UI", 12.5f, FontStyle.Bold);

	private readonly Font bodyFont = new Font("Segoe UI", 10f);

	private readonly Font boldFont = new Font("Segoe UI", 10f, FontStyle.Bold);

	private readonly Font smallFont = new Font("Segoe UI", 9f);

	private readonly Font smallBoldFont = new Font("Segoe UI Semibold", 9f);

	private readonly Font nameFont = new Font("Segoe UI Semibold", 10f);

	private readonly Font digitFont = new Font("Segoe UI", 18f, FontStyle.Bold);

	private readonly Font avatarFont = new Font("Segoe UI", 14f, FontStyle.Bold);

	private bool dark;

	private Palette palette = LightPalette;

	private NearbyUi.NearPalette near = NearbyUi.LightNear;

	private bool answered;

	private int buttonsTop;

	/// <summary>[받기] = true, [거절] · 창 닫기 · 30초 지남 = false. 한 번만 불립니다.</summary>
	public event Action<bool>? Answered;

	public NearbyRequestForm(string sender, string origin, string? proximity, string fileTitle, string fileDetail, string code, Func<bool>? stillValid = null)
	{
		this.sender = sender;
		this.origin = origin;
		this.proximity = proximity;
		this.fileTitle = fileTitle;
		this.fileDetail = fileDetail;
		this.code = code;
		this.stillValid = stillValid;
		deadline = DateTimeOffset.UtcNow + NearbyService.AnswerTimeout;
		dark = ReadDarkMode();
		ApplyPalette();
		SuspendLayout();
		Text = "아나 · 근처 기기";
		Icon = Program.AppIcon;
		AutoScaleMode = AutoScaleMode.None;
		Font = bodyFont;
		FormBorderStyle = FormBorderStyle.FixedDialog;
		MaximizeBox = false;
		MinimizeBox = false;
		ShowInTaskbar = true;
		StartPosition = FormStartPosition.CenterScreen;
		TopMost = true;
		KeyPreview = true;
		SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
		declineButton = new NearbyButton(NearbyButtonKind.Secondary, "거절", () => palette, S, bodyFont, boldFont)
		{
			TabIndex = 1
		};
		acceptButton = new NearbyButton(NearbyButtonKind.Primary, "받기", () => palette, S, bodyFont, boldFont)
		{
			TabIndex = 0
		};
		declineButton.Click += (object? _, EventArgs _) => Answer(false);
		acceptButton.Click += (object? _, EventArgs _) => Answer(true);
		Controls.AddRange(new Control[] { acceptButton, declineButton });
		BackColor = palette.Surface;
		LayoutForm();
		ResumeLayout(performLayout: false);
		timer = new System.Windows.Forms.Timer
		{
			Interval = 500
		};
		timer.Tick += (object? _, EventArgs _) =>
		{
			if (DateTimeOffset.UtcNow >= deadline || (stillValid != null && !stillValid()))
			{
				Answer(false);
				return;
			}
			Invalidate(new Rectangle(0, buttonsTop + S(40), ClientSize.Width, ClientSize.Height - buttonsTop - S(40)));
		};
		timer.Start();
	}

	// 다른 일을 하는 중에 창이 떠도 입력(Enter 등)을 가로채지 않게 활성화하지 않고 띄웁니다.
	protected override bool ShowWithoutActivation => true;

	private int S(float value)
	{
		return (int)Math.Round(value * DeviceDpi / 96f);
	}

	private void ApplyPalette()
	{
		palette = dark ? DarkPalette : LightPalette;
		near = dark ? NearbyUi.DarkNear : NearbyUi.LightNear;
	}

	private void LayoutForm()
	{
		int width = S(480);
		int pad = S(24);
		// 머리(48) · 파일 카드(64) · 확인 숫자(46) 사이 간격 14
		int top = S(20) + S(48) + S(14) + S(64) + S(14) + S(46) + S(22);
		buttonsTop = top;
		int height = S(40);
		int acceptWidth = Math.Max(acceptButton.PreferredWidth(), S(96));
		int declineWidth = Math.Max(declineButton.PreferredWidth(), S(80));
		acceptButton.Bounds = new Rectangle(width - pad - acceptWidth, top, acceptWidth, height);
		declineButton.Bounds = new Rectangle(acceptButton.Left - S(8) - declineWidth, top, declineWidth, height);
		ClientSize = new Size(width, top + height + S(10) + S(18) + S(18));
	}

	private void Answer(bool accept, bool close = true)
	{
		if (answered)
		{
			return;
		}
		answered = true;
		timer.Stop();
		try
		{
			Answered?.Invoke(accept);
		}
		catch
		{
		}
		if (close && !IsDisposed)
		{
			if (IsHandleCreated)
			{
				BeginInvoke(() => Close());
			}
			else
			{
				Dispose();
			}
		}
	}

	protected override void OnFormClosing(FormClosingEventArgs e)
	{
		base.OnFormClosing(e);
		if (!e.Cancel)
		{
			Answer(accept: false, close: false);
		}
	}

	protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
	{
		if (keyData == Keys.Escape)
		{
			Answer(false);
			return true;
		}
		if (keyData == Keys.Return && ActiveControl is NearbyButton focused)
		{
			focused.PerformClick();
			return true;
		}
		return base.ProcessCmdKey(ref msg, keyData);
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
		int width = ClientSize.Width;
		int pad = S(24);
		int y = S(20);
		// 보내는 기기: 파란 동그라미 + 첫 글자
		Rectangle avatar = new Rectangle(pad, y, S(48), S(48));
		using (SolidBrush brush = new SolidBrush(near.Near))
		{
			g.FillEllipse(brush, avatar);
		}
		TextRenderer.DrawText(g, NearbyUi.Initial(sender), avatarFont, avatar, Color.White, NearbyUi.CenterFlags);
		int textLeft = avatar.Right + S(12);
		int textWidth = width - textLeft - pad;
		int titleHeight = LineHeight(titleFont);
		int subHeight = LineHeight(smallFont);
		int top = y + (S(48) - titleHeight - S(2) - subHeight) / 2;
		TextRenderer.DrawText(g, sender + "에서 보내려고 합니다", titleFont, new Rectangle(textLeft, top, textWidth, titleHeight), palette.Text, NearbyUi.LineFlags);
		string prefix = origin + (proximity != null ? " · " : "");
		Rectangle subRect = new Rectangle(textLeft, top + titleHeight + S(2), textWidth, subHeight);
		TextRenderer.DrawText(g, prefix, smallFont, subRect, palette.Muted, NearbyUi.LineFlags);
		if (proximity != null)
		{
			// 말줄임(EndEllipsis) 플래그와 크기 0으로 재면 폭이 짧게 나와 뒤 글자가 겹쳤습니다. 제한 없는 크기로 재고, 끝 공백 폭은 따로 더합니다.
			TextFormatFlags measure = TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding;
			Size unbounded = new Size(int.MaxValue, int.MaxValue);
			int space = TextRenderer.MeasureText(g, "가 가", smallFont, unbounded, measure).Width - TextRenderer.MeasureText(g, "가가", smallFont, unbounded, measure).Width;
			int prefixWidth = TextRenderer.MeasureText(g, prefix.TrimEnd(), smallFont, unbounded, measure).Width + Math.Max(space, S(3)) + S(1);
			TextRenderer.DrawText(g, proximity, smallBoldFont, new Rectangle(textLeft + prefixWidth, subRect.Y, Math.Max(0, textWidth - prefixWidth), subHeight), near.NearText, NearbyUi.LineFlags);
		}
		y += S(48) + S(14);
		// 파일 카드
		RectangleF card = new RectangleF(pad + 0.5f, y + 0.5f, width - pad * 2 - 1f, S(64) - 1f);
		NearbyUi.FillRound(g, card, S(12), palette.Subtle, palette.Border);
		RectangleF tile = new RectangleF(pad + S(12), y + S(12), S(40), S(40));
		NearbyUi.FillRound(g, tile, S(9), palette.AccentSoft);
		NearbyUi.DrawFileGlyph(g, new RectangleF(tile.X + S(11), tile.Y + S(11), S(18), S(18)), palette.Accent, Math.Max(1.4f, S(1.6f)));
		int fileLeft = (int)tile.Right + S(12);
		int fileWidth = width - pad - S(12) - fileLeft;
		int nameHeight = LineHeight(nameFont);
		int fileTop = y + (S(64) - nameHeight - S(2) - subHeight) / 2;
		TextRenderer.DrawText(g, fileTitle, nameFont, new Rectangle(fileLeft, fileTop, fileWidth, nameHeight), palette.Text, NearbyUi.LineFlags);
		TextRenderer.DrawText(g, fileDetail, smallFont, new Rectangle(fileLeft, fileTop + nameHeight + S(2), fileWidth, subHeight), palette.Faint, NearbyUi.LineFlags);
		y += S(64) + S(14);
		// 확인 숫자
		int digitWidth = S(38);
		int digitHeight = S(46);
		int digitsLeft = width - pad - code.Length * digitWidth - Math.Max(0, code.Length - 1) * S(6);
		TextRenderer.DrawText(g, "보내는 사람 화면의 숫자와 같나요?", bodyFont, new Rectangle(pad, y, Math.Max(0, digitsLeft - pad - S(8)), digitHeight), palette.Muted, NearbyUi.LineFlags);
		for (int i = 0; i < code.Length; i++)
		{
			RectangleF box = new RectangleF(digitsLeft + i * (digitWidth + S(6)) + 0.5f, y + 0.5f, digitWidth - 1f, digitHeight - 1f);
			NearbyUi.FillRound(g, box, S(9), palette.Surface, palette.Border);
			TextRenderer.DrawText(g, code[i].ToString(), digitFont, Rectangle.Round(box), palette.Text, NearbyUi.CenterFlags);
		}
		// 남은 시간
		int left = Math.Max(0, (int)Math.Ceiling((deadline - DateTimeOffset.UtcNow).TotalSeconds));
		TextRenderer.DrawText(g, $"{left}초 뒤 자동 거절 · 트레이 알림으로도 표시됩니다", smallFont, new Rectangle(pad, buttonsTop + S(40) + S(10), width - pad * 2, S(18)), palette.Faint, NearbyUi.LineFlags | TextFormatFlags.Right);
	}

	protected override void Dispose(bool disposing)
	{
		if (disposing)
		{
			timer.Dispose();
		}
		base.Dispose(disposing);
		if (disposing)
		{
			titleFont.Dispose();
			bodyFont.Dispose();
			boldFont.Dispose();
			smallFont.Dispose();
			smallBoldFont.Dispose();
			nameFont.Dispose();
			digitFont.Dispose();
			avatarFont.Dispose();
		}
	}
}

/// <summary>
/// QR 창 (WinQr 디자인): [QR로 보내기] 고른 파일을 1회용 링크로 · [QR로 받기] 휴대폰 브라우저에서 이 PC로 올리기.
/// 링크는 서버 중계의 /s/… 주소이며 10분 동안 한 번만 쓸 수 있습니다. 창을 닫으면 아직 쓰지 않은 링크는 없어집니다.
/// </summary>
internal sealed class QrForm : Form
{
	private readonly TransferServer server;

	private readonly NearbyButton sendTab;

	private readonly NearbyButton receiveTab;

	private readonly NearbyButton copyButton;

	private readonly NearbyButton firstAction;

	private readonly NearbyButton secondAction;

	private readonly System.Windows.Forms.Timer timer;

	private readonly Font bodyFont = new Font("Segoe UI", 10f);

	private readonly Font boldFont = new Font("Segoe UI", 10f, FontStyle.Bold);

	private readonly Font mediumFont = new Font("Segoe UI Semibold", 10.5f);

	private readonly Font titleFont = new Font("Segoe UI", 12f, FontStyle.Bold);

	private readonly Font smallFont = new Font("Segoe UI", 9f);

	private readonly Font smallBoldFont = new Font("Segoe UI", 9f, FontStyle.Bold);

	private readonly Font digitFont = new Font("Segoe UI", 18f, FontStyle.Bold);

	private bool dark;

	private Palette palette = LightPalette;

	private bool receiveMode;

	private TransferServer.GuestTicket? sendTicket;

	private TransferServer.GuestTicket? receiveTicket;

	private bool creating;

	private string? error;

	private DateTime copiedUntil;

	private string? matrixText;

	private bool[,]? matrix;

	private string view = "";

	// 레이아웃 (LayoutForm)
	private Rectangle tabsRect;

	private Rectangle summaryRect;

	private Rectangle boxRect;

	private Rectangle captionRect;

	private Rectangle linkRect;

	private Rectangle statusRect;

	/// <summary>서버 설정이 필요할 때 [옵션 열기].</summary>
	public event Action? OptionsRequested;

	/// <summary>받기를 마쳤을 때 [받은 폴더 열기].</summary>
	public event Action? ReceivedFolderRequested;

	public QrForm(TransferServer server, bool receive)
	{
		this.server = server;
		receiveMode = receive;
		dark = ReadDarkMode();
		palette = dark ? DarkPalette : LightPalette;
		SuspendLayout();
		Text = "아나 · QR";
		Icon = Program.AppIcon;
		AutoScaleMode = AutoScaleMode.None;
		Font = bodyFont;
		FormBorderStyle = FormBorderStyle.FixedDialog;
		MaximizeBox = false;
		MinimizeBox = true;
		StartPosition = FormStartPosition.CenterScreen;
		KeyPreview = true;
		SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
		sendTab = new NearbyButton(NearbyButtonKind.Segment, "QR로 보내기", () => palette, S, bodyFont, boldFont);
		receiveTab = new NearbyButton(NearbyButtonKind.Segment, "QR로 받기", () => palette, S, bodyFont, boldFont);
		copyButton = new NearbyButton(NearbyButtonKind.Secondary, "링크 복사", () => palette, S, bodyFont, boldFont);
		firstAction = new NearbyButton(NearbyButtonKind.Primary, "파일 선택", () => palette, S, bodyFont, boldFont);
		secondAction = new NearbyButton(NearbyButtonKind.Secondary, "폴더 선택", () => palette, S, bodyFont, boldFont);
		sendTab.TabIndex = 0;
		receiveTab.TabIndex = 1;
		firstAction.TabIndex = 2;
		secondAction.TabIndex = 3;
		copyButton.TabIndex = 4;
		Controls.AddRange(new Control[] { sendTab, receiveTab, firstAction, secondAction, copyButton });
		sendTab.Click += (object? _, EventArgs _) => SwitchTab(receive: false);
		receiveTab.Click += (object? _, EventArgs _) => SwitchTab(receive: true);
		copyButton.Click += (object? _, EventArgs _) => CopyLink();
		firstAction.Click += (object? _, EventArgs _) => Act(first: true);
		secondAction.Click += (object? _, EventArgs _) => Act(first: false);
		BackColor = palette.Surface;
		LayoutForm();
		ResumeLayout(performLayout: false);
		timer = new System.Windows.Forms.Timer
		{
			Interval = 500
		};
		timer.Tick += (object? _, EventArgs _) => UpdateView();
		timer.Start();
		SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
		SwitchTab(receive);
	}

	private int S(float value)
	{
		return (int)Math.Round(value * DeviceDpi / 96f);
	}

	/// <summary>트레이 메뉴 · 웹 화면에서 다시 열 때 원하는 탭으로.</summary>
	public void ShowTab(bool receive)
	{
		SwitchTab(receive);
	}

	private void LayoutForm()
	{
		int width = S(480);
		int pad = S(24);
		int y = S(16);
		tabsRect = new Rectangle(pad, y, width - pad * 2, S(40));
		int inset = S(3);
		int half = (tabsRect.Width - inset * 2) / 2;
		sendTab.Bounds = new Rectangle(tabsRect.X + inset, tabsRect.Y + inset, half, tabsRect.Height - inset * 2);
		receiveTab.Bounds = new Rectangle(sendTab.Right, tabsRect.Y + inset, tabsRect.Width - inset * 2 - half, tabsRect.Height - inset * 2);
		y = tabsRect.Bottom + S(14);
		summaryRect = new Rectangle(pad, y, width - pad * 2, S(20));
		y = summaryRect.Bottom + S(12);
		int box = S(280);
		boxRect = new Rectangle((width - box) / 2, y, box, box);
		y = boxRect.Bottom + S(14);
		captionRect = new Rectangle(pad, y, width - pad * 2, S(22));
		y = captionRect.Bottom + S(14);
		int copyWidth = Math.Max(copyButton.PreferredWidth(), S(92));
		copyButton.Bounds = new Rectangle(width - pad - copyWidth, y, copyWidth, S(38));
		linkRect = new Rectangle(pad, y, copyButton.Left - S(8) - pad, S(38));
		y = linkRect.Bottom + S(14);
		statusRect = new Rectangle(pad, y, width - pad * 2, S(18));
		ClientSize = new Size(width, statusRect.Bottom + S(20));
		LayoutActions();
	}

	private void LayoutActions()
	{
		int height = S(38);
		int gap = S(8);
		int top = boxRect.Bottom - S(28) - height;
		if (secondAction.Visible)
		{
			int a = Math.Max(firstAction.PreferredWidth(), S(100));
			int b = Math.Max(secondAction.PreferredWidth(), S(100));
			int left = boxRect.X + (boxRect.Width - a - b - gap) / 2;
			firstAction.Bounds = new Rectangle(left, top, a, height);
			secondAction.Bounds = new Rectangle(left + a + gap, top, b, height);
		}
		else
		{
			int a = Math.Max(firstAction.PreferredWidth(), S(140));
			firstAction.Bounds = new Rectangle(boxRect.X + (boxRect.Width - a) / 2, top, a, height);
		}
	}

	private TransferServer.GuestTicket? Ticket => receiveMode ? receiveTicket : sendTicket;

	private void SwitchTab(bool receive)
	{
		receiveMode = receive;
		sendTab.SetSelected(!receive);
		receiveTab.SetSelected(receive);
		error = null;
		if (receive && server.GuestOrigin != null && (receiveTicket == null || receiveTicket.State is "declined" or "expired"))
		{
			try
			{
				receiveTicket = server.CreateReceiveTicket("QR");
			}
			catch (Exception ex) when (ex is InvalidOperationException or ArgumentException)
			{
				error = ex.Message;
			}
		}
		UpdateView();
	}

	private string Url(TransferServer.GuestTicket ticket)
	{
		try
		{
			return server.GuestUrl(ticket);
		}
		catch (InvalidOperationException)
		{
			return "";
		}
	}

	/// <summary>지금 보여 줄 화면: nas · pick · creating · error · qr · waiting · progress · done · ended</summary>
	private string CurrentView()
	{
		TransferServer.GuestTicket? t = Ticket;
		if (creating)
		{
			return "creating";
		}
		if (t == null)
		{
			if (server.GuestOrigin == null)
			{
				return "nas";
			}
			return error != null ? "error" : receiveMode ? "error" : "pick";
		}
		return t.State switch
		{
			"ready" => "qr",
			"waiting" => "waiting",
			"accepted" or "transferring" => "progress",
			"done" => "done",
			_ => "ended"
		};
	}

	private void UpdateView()
	{
		if (IsDisposed)
		{
			return;
		}
		string next = CurrentView();
		if (next != view)
		{
			view = next;
			bool two = view == "pick";
			firstAction.Visible = view is "pick" or "nas" or "done" or "ended" or "error";
			secondAction.Visible = two;
			firstAction.Text = view switch
			{
				"pick" => "파일 선택",
				"nas" => "옵션 열기",
				"done" => receiveMode ? "받은 폴더 열기" : "다른 파일 보내기",
				_ => "새 링크 만들기"
			};
			copyButton.Visible = view is "qr" or "waiting" or "progress";
			LayoutActions();
		}
		string url = Ticket != null && view is "qr" or "waiting" or "progress" ? Url(Ticket!) : "";
		copyButton.Enabled = url.Length > 0;
		if (view == "qr" && url.Length > 0 && url != matrixText)
		{
			matrix = Encode(url);
			matrixText = url;
		}
		Invalidate();
	}

	private static bool[,]? Encode(string text)
	{
		try
		{
			using QRCoder.QRCodeGenerator generator = new QRCoder.QRCodeGenerator();
			using QRCoder.QRCodeData data = generator.CreateQrCode(text, QRCoder.QRCodeGenerator.ECCLevel.M);
			List<BitArray> rows = data.ModuleMatrix;
			int n = rows.Count;
			bool[,] result = new bool[n, n];
			for (int y = 0; y < n; y++)
			{
				for (int x = 0; x < n && x < rows[y].Length; x++)
				{
					result[y, x] = rows[y][x];
				}
			}
			return result;
		}
		catch
		{
			return null;
		}
	}

	private async void Act(bool first)
	{
		switch (view)
		{
		case "nas":
			OptionsRequested?.Invoke();
			break;
		case "pick":
			await PickAndCreateAsync(folder: !first);
			break;
		case "done" when receiveMode:
			ReceivedFolderRequested?.Invoke();
			break;
		case "done":
			sendTicket = null;
			UpdateView();
			await PickAndCreateAsync(folder: false);
			break;
		default:
			// 새 링크 만들기 (만료 · 거절 · 오류)
			error = null;
			if (receiveMode)
			{
				receiveTicket = null;
				SwitchTab(receive: true);
			}
			else
			{
				sendTicket = null;
				UpdateView();
			}
			break;
		}
	}

	private async Task PickAndCreateAsync(bool folder)
	{
		string[]? paths = null;
		if (folder)
		{
			using FolderBrowserDialog dialog = new FolderBrowserDialog
			{
				Description = "보낼 폴더를 선택하세요 · ZIP으로 압축해 보냅니다",
				UseDescriptionForTitle = true
			};
			if (dialog.ShowDialog(this) == DialogResult.OK)
			{
				paths = new string[1] { dialog.SelectedPath };
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
				paths = dialog.FileNames;
			}
		}
		if (IsDisposed || paths == null || paths.Length == 0)
		{
			return;
		}
		await CreateSendAsync(paths);
	}

	/// <summary>보낼 파일로 1회용 링크를 만듭니다 (탐색기 · 트레이에서 파일을 고른 채로 열 때도).</summary>
	public async Task CreateSendAsync(string[] paths)
	{
		if (creating)
		{
			return;
		}
		SwitchTab(receive: false);
		if (sendTicket is { Finished: false } old)
		{
			server.CancelTicket(old.Token);
		}
		sendTicket = null;
		creating = true;
		error = null;
		UpdateView();
		try
		{
			sendTicket = await server.CreateSendTicketAsync(paths, "QR");
		}
		catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or IOException or UnauthorizedAccessException)
		{
			error = ex.Message;
		}
		finally
		{
			creating = false;
			if (!IsDisposed)
			{
				UpdateView();
			}
		}
		if (IsDisposed && sendTicket != null)
		{
			server.CancelTicket(sendTicket.Token);
		}
	}

	private void CopyLink()
	{
		TransferServer.GuestTicket? t = Ticket;
		string url = t == null ? "" : Url(t);
		if (url.Length == 0)
		{
			return;
		}
		try
		{
			Clipboard.SetText(url);
			copiedUntil = DateTime.UtcNow.AddSeconds(2.5);
		}
		catch
		{
		}
		Invalidate();
	}

	protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
	{
		switch (keyData)
		{
		case Keys.Escape:
			Close();
			return true;
		case Keys.Return:
			if (ActiveControl is NearbyButton focused)
			{
				focused.PerformClick();
				return true;
			}
			break;
		case Keys.Left when sendTab.Focused || receiveTab.Focused:
			SwitchTab(receive: false);
			sendTab.Focus();
			return true;
		case Keys.Right when sendTab.Focused || receiveTab.Focused:
			SwitchTab(receive: true);
			receiveTab.Focus();
			return true;
		}
		return base.ProcessCmdKey(ref msg, keyData);
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
		// 탭 바탕
		NearbyUi.FillRound(g, new RectangleF(tabsRect.X + 0.5f, tabsRect.Y + 0.5f, tabsRect.Width - 1f, tabsRect.Height - 1f), S(10), palette.Subtle, palette.Border);
		TransferServer.GuestTicket? t = Ticket;
		// 파일 요약
		string summary = "";
		if (!receiveMode && t != null)
		{
			summary = (t.Files.Length == 1 ? t.Files[0].Name : NearbyService.Summary(t.Files.Select((TransferServer.GuestFile f) => f.Name).ToArray())) + " · " + NearbyUi.FormatSize(t.Total);
		}
		else if (receiveMode && t != null && t.Files.Length > 0)
		{
			summary = t.Peer + " · " + (t.Files.Length == 1 ? t.Files[0].Name : NearbyService.Summary(t.Files.Select((TransferServer.GuestFile f) => f.Name).ToArray())) + " · " + NearbyUi.FormatSize(t.Total);
		}
		else if (receiveMode)
		{
			summary = "휴대폰 브라우저에서 이 PC(" + server.GuestOwnerName + ")로 보냅니다";
		}
		TextRenderer.DrawText(g, summary, bodyFont, summaryRect, palette.Muted, NearbyUi.CenterFlags);
		// 가운데 상자
		string caption = "";
		string status = "";
		Color statusColor = palette.Accent;
		switch (view)
		{
		case "qr":
			PaintQr(g);
			caption = receiveMode ? "휴대폰 카메라로 찍으면 이 PC로 보낼 수 있습니다" : "휴대폰 카메라로 찍으면 바로 받을 수 있습니다";
			status = Remaining(t) + " 남음 · 한 번만 쓸 수 있는 링크";
			break;
		case "waiting":
			PaintBox(g, false);
			PaintCentered(g, (t?.Peer ?? "상대") + "의 요청", "확인 창에서 [받기]를 누르면 전송됩니다", t?.Code);
			caption = "보내는 사람 화면의 숫자와 같은지 확인하세요";
			status = Remaining(t) + " 남음 · 한 번만 쓸 수 있는 링크";
			break;
		case "progress":
		{
			PaintBox(g, false);
			int percent = t != null && t.Total > 0 ? (int)Math.Min(100L, t.Transferred * 100 / t.Total) : 0;
			PaintCentered(g, (receiveMode ? "받는 중 · " : "보내는 중 · ") + percent + "%", t == null ? "" : $"{t.CompletedCount}/{t.Files.Length}개 완료", null);
			Rectangle bar = new Rectangle(boxRect.X + S(32), boxRect.Bottom - S(64), boxRect.Width - S(64), S(8));
			NearbyUi.FillRound(g, bar, S(4), palette.Subtle);
			if (percent > 0)
			{
				NearbyUi.FillRound(g, new RectangleF(bar.X, bar.Y, Math.Max(S(8), bar.Width * percent / 100f), bar.Height), S(4), palette.Accent);
			}
			caption = "창을 닫아도 전송은 계속됩니다";
			status = "한 번만 쓸 수 있는 링크";
			break;
		}
		case "done":
			PaintBox(g, false);
			PaintDone(g, receiveMode ? "받았습니다" : "보냈습니다", receiveMode ? NearbyUi.ShortFolder(server.Settings.SavePath) + "에 저장했습니다" : "이 링크는 이제 사용할 수 없습니다");
			caption = "";
			status = "";
			break;
		case "ended":
			PaintBox(g, true);
			PaintCentered(g, t?.State == "declined" ? "링크를 닫았습니다" : "링크가 만료되었습니다", "새 링크를 만들어 다시 보여 주세요", null);
			break;
		case "nas":
			PaintBox(g, true);
			PaintCentered(g, "서버 설정이 필요합니다", "QR 링크는 서버 중계로 주고받습니다", null);
			caption = "옵션 › 서버에서 주소와 연결 키를 입력하세요";
			break;
		case "creating":
			PaintBox(g, true);
			PaintCentered(g, "링크를 만드는 중…", "폴더는 ZIP으로 압축합니다", null);
			break;
		case "pick":
			PaintBox(g, true);
			PaintCentered(g, "보낼 파일을 고르세요", "고른 파일을 QR 링크로 한 번 보냅니다", null);
			caption = "받는 사람은 앱 없이 브라우저로 받습니다";
			break;
		default:
			PaintBox(g, true);
			PaintCentered(g, "링크를 만들지 못했습니다", error ?? "다시 시도하세요", null);
			break;
		}
		TextRenderer.DrawText(g, caption, mediumFont, captionRect, palette.Text, NearbyUi.CenterFlags);
		if (copyButton.Visible)
		{
			string url = t == null ? "" : Url(t);
			NearbyUi.FillRound(g, new RectangleF(linkRect.X + 0.5f, linkRect.Y + 0.5f, linkRect.Width - 1f, linkRect.Height - 1f), S(9), palette.Subtle, palette.Border);
			TextRenderer.DrawText(g, url, smallFont, new Rectangle(linkRect.X + S(12), linkRect.Y, linkRect.Width - S(24), linkRect.Height), palette.Muted, NearbyUi.LineFlags | TextFormatFlags.PathEllipsis);
		}
		if (DateTime.UtcNow < copiedUntil)
		{
			status = "링크를 복사했습니다";
		}
		TextRenderer.DrawText(g, status, smallBoldFont, statusRect, statusColor, NearbyUi.CenterFlags);
	}

	private static string Remaining(TransferServer.GuestTicket? t)
	{
		TimeSpan left = t?.Remaining ?? TimeSpan.Zero;
		int seconds = Math.Max(0, (int)Math.Ceiling(left.TotalSeconds));
		return $"{seconds / 60}:{seconds % 60:00}";
	}

	private void PaintBox(Graphics g, bool dashed)
	{
		RectangleF r = new RectangleF(boxRect.X + 0.75f, boxRect.Y + 0.75f, boxRect.Width - 1.5f, boxRect.Height - 1.5f);
		using GraphicsPath path = RoundRect(r, S(16));
		using (SolidBrush brush = new SolidBrush(palette.Subtle))
		{
			g.FillPath(brush, path);
		}
		using Pen pen = new Pen(dashed ? palette.BorderStrong : palette.Border, Math.Max(1f, S(1.5f)));
		if (dashed)
		{
			pen.DashStyle = DashStyle.Dash;
		}
		g.DrawPath(pen, path);
	}

	private void PaintCentered(Graphics g, string title, string detail, string? code)
	{
		int titleHeight = LineHeight(titleFont);
		int detailHeight = LineHeight(smallFont);
		int top = boxRect.Y + S(56);
		TextRenderer.DrawText(g, title, titleFont, new Rectangle(boxRect.X + S(16), top, boxRect.Width - S(32), titleHeight), palette.Text, NearbyUi.CenterFlags);
		TextRenderer.DrawText(g, detail, smallFont, new Rectangle(boxRect.X + S(16), top + titleHeight + S(6), boxRect.Width - S(32), detailHeight * 2), palette.Faint, TextFormatFlags.HorizontalCenter | TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding);
		if (!string.IsNullOrEmpty(code))
		{
			int w = S(40);
			int h = S(48);
			int gap = S(6);
			int left = boxRect.X + (boxRect.Width - code.Length * w - (code.Length - 1) * gap) / 2;
			int y = top + titleHeight + S(6) + detailHeight * 2 + S(14);
			for (int i = 0; i < code.Length; i++)
			{
				RectangleF box = new RectangleF(left + i * (w + gap) + 0.5f, y + 0.5f, w - 1f, h - 1f);
				NearbyUi.FillRound(g, box, S(9), palette.Surface, palette.Border);
				TextRenderer.DrawText(g, code[i].ToString(), digitFont, Rectangle.Round(box), palette.Text, NearbyUi.CenterFlags);
			}
		}
	}

	private void PaintDone(Graphics g, string title, string detail)
	{
		int circle = S(52);
		RectangleF c = new RectangleF(boxRect.X + (boxRect.Width - circle) / 2f, boxRect.Y + S(48), circle, circle);
		using (SolidBrush brush = new SolidBrush(palette.AccentSoft))
		{
			g.FillEllipse(brush, c);
		}
		NearbyUi.DrawCheck(g, new RectangleF(c.X + S(13), c.Y + S(13), S(26), S(26)), palette.Accent, Math.Max(2f, S(2.4f)));
		int titleHeight = LineHeight(titleFont);
		int top = (int)c.Bottom + S(12);
		TextRenderer.DrawText(g, title, titleFont, new Rectangle(boxRect.X + S(16), top, boxRect.Width - S(32), titleHeight), palette.Text, NearbyUi.CenterFlags);
		TextRenderer.DrawText(g, detail, smallFont, new Rectangle(boxRect.X + S(16), top + titleHeight + S(4), boxRect.Width - S(32), LineHeight(smallFont)), palette.Faint, NearbyUi.CenterFlags);
	}

	private void PaintQr(Graphics g)
	{
		// QR은 다크 모드에서도 흰 바탕 · 검은 칸 (카메라가 잘 읽도록)
		RectangleF r = new RectangleF(boxRect.X + 0.5f, boxRect.Y + 0.5f, boxRect.Width - 1f, boxRect.Height - 1f);
		NearbyUi.FillRound(g, r, S(16), Color.White, palette.Border);
		bool[,]? m = matrix;
		if (m == null)
		{
			TextRenderer.DrawText(g, "QR을 만들지 못했습니다 · 링크를 복사해 보내세요", smallFont, boxRect, Hex(0x5b636e), NearbyUi.CenterFlags);
			return;
		}
		int n = m.GetLength(0);
		int inner = boxRect.Width - S(12);
		int module = Math.Max(1, inner / n);
		int size = module * n;
		int left = boxRect.X + (boxRect.Width - size) / 2;
		int top = boxRect.Y + (boxRect.Height - size) / 2;
		SmoothingMode previous = g.SmoothingMode;
		g.SmoothingMode = SmoothingMode.None;
		g.PixelOffsetMode = PixelOffsetMode.Half;
		using (SolidBrush ink = new SolidBrush(Hex(0x1f2328)))
		{
			for (int y = 0; y < n; y++)
			{
				for (int x = 0; x < n; x++)
				{
					if (m[y, x])
					{
						g.FillRectangle(ink, left + x * module, top + y * module, module, module);
					}
				}
			}
		}
		g.SmoothingMode = previous;
		g.PixelOffsetMode = PixelOffsetMode.HighQuality;
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
					palette = dark ? DarkPalette : LightPalette;
					BackColor = palette.Surface;
					SetDarkTitleBar(Handle, dark);
					Invalidate(invalidateChildren: true);
				}
			});
		}
		catch
		{
		}
	}

	protected override void OnFormClosed(FormClosedEventArgs e)
	{
		// 아직 쓰지 않은 링크는 닫습니다. 주고받는 중인 링크는 끝까지 둡니다.
		foreach (TransferServer.GuestTicket? t in new[] { sendTicket, receiveTicket })
		{
			if (t != null && t.State is "ready" or "waiting")
			{
				server.CancelTicket(t.Token);
			}
		}
		base.OnFormClosed(e);
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
			bodyFont.Dispose();
			boldFont.Dispose();
			mediumFont.Dispose();
			titleFont.Dispose();
			smallFont.Dispose();
			smallBoldFont.Dispose();
			digitFont.Dispose();
		}
	}
}
