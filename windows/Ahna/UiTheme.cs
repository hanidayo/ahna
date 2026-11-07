using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Ahna;

/// <summary>
/// 아나 창(SendDialog · ClipboardForm)이 함께 쓰는 색 · 그리기 도구.
/// 초록 강조색 팔레트(라이트/다크), 둥근 사각형, Windows 앱 테마(AppsUseLightTheme) 읽기, 어두운 제목 표시줄.
/// </summary>
internal static class UiTheme
{
	internal sealed record Palette(Color Surface, Color Subtle, Color Border, Color BorderStrong, Color Text, Color Muted, Color Faint, Color Accent, Color AccentHover, Color OnAccent, Color AccentSoft, Color On, Color Off, Color Danger);

	internal static readonly Palette LightPalette = new(Hex(0xffffff), Hex(0xf7f8fa), Hex(0xe3e6ea), Hex(0xc5cad1), Hex(0x1f2328), Hex(0x5b636e), Hex(0x6b7280), Hex(0x005fb8), Hex(0x1a6fc2), Hex(0xffffff), Hex(0xe5eff9), Hex(0x1e7a48), Hex(0x9aa1ab), Hex(0xb42318));

	internal static readonly Palette DarkPalette = new(Hex(0x272727), Hex(0x2e2e2e), Hex(0x3a3a3a), Hex(0x555555), Hex(0xe8eaed), Hex(0xa7aeb8), Hex(0x9aa1ab), Hex(0x4cc2ff), Hex(0x6fd0ff), Hex(0x002033), Hex(0x16303f), Hex(0x4ade80), Hex(0x8b929c), Hex(0xf97066));

	/// <summary>받을 기기 목록(SendTargets)에서 오프라인 기기 이름 뒤에 붙는 표시.</summary>
	internal const string OfflineSuffix = " (오프라인)";

	internal static Color Hex(int rgb)
	{
		return Color.FromArgb(255, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
	}

	internal static Color Mix(Color a, Color b, float t)
	{
		return Color.FromArgb(255, (int)Math.Round(a.R + (b.R - a.R) * t), (int)Math.Round(a.G + (b.G - a.G) * t), (int)Math.Round(a.B + (b.B - a.B) * t));
	}

	internal static GraphicsPath RoundRect(RectangleF r, float radius)
	{
		GraphicsPath path = new GraphicsPath();
		float d = Math.Min(radius * 2f, Math.Min(r.Width, r.Height));
		if (d <= 0.5f)
		{
			path.AddRectangle(r);
			return path;
		}
		path.AddArc(r.X, r.Y, d, d, 180f, 90f);
		path.AddArc(r.Right - d, r.Y, d, d, 270f, 90f);
		path.AddArc(r.Right - d, r.Bottom - d, d, d, 0f, 90f);
		path.AddArc(r.X, r.Bottom - d, d, d, 90f, 90f);
		path.CloseFigure();
		return path;
	}

	internal static void Smooth(Graphics g)
	{
		g.SmoothingMode = SmoothingMode.AntiAlias;
		g.PixelOffsetMode = PixelOffsetMode.HighQuality;
	}

	internal static int LineHeight(Font font)
	{
		return TextRenderer.MeasureText("가Ag", font, default(Size), TextFormatFlags.SingleLine | TextFormatFlags.NoPadding).Height;
	}

	internal static bool IsOffline(string name)
	{
		return name.EndsWith(OfflineSuffix, StringComparison.Ordinal);
	}

	internal static string DisplayName(string name)
	{
		return IsOffline(name) ? name.Substring(0, name.Length - OfflineSuffix.Length) : name;
	}

	// 웹 화면 로고와 같은 종이비행기 (24 단위 아이콘을 타일 크기에 맞춤)
	internal static void DrawPlane(Graphics g, Rectangle tile, Color color)
	{
		float size = tile.Width * 0.5f;
		float scale = size / 24f;
		float left = tile.X + (tile.Width - size) / 2f;
		float top = tile.Y + (tile.Height - size) / 2f;
		PointF P(float x, float y) => new PointF(left + x * scale, top + y * scale);
		using Pen pen = new Pen(color, Math.Max(1.5f, 2f * scale))
		{
			StartCap = LineCap.Round,
			EndCap = LineCap.Round,
			LineJoin = LineJoin.Round
		};
		g.DrawLine(pen, P(22f, 2f), P(11f, 13f));
		g.DrawPolygon(pen, new PointF[4] { P(22f, 2f), P(15f, 22f), P(11f, 13f), P(2f, 9f) });
	}

	// Windows 설정 › 개인 설정 › 색 › ‘앱 모드’ (0 = 어둡게)
	internal static bool ReadDarkMode()
	{
		try
		{
			if (SystemInformation.HighContrast)
			{
				return false;
			}
			using RegistryKey? key = Registry.CurrentUser.OpenSubKey("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
			return key?.GetValue("AppsUseLightTheme") is int value && value == 0;
		}
		catch
		{
			return false;
		}
	}

	[DllImport("dwmapi.dll")]
	private static extern int DwmSetWindowAttribute(nint window, int attribute, ref int value, int size);

	[DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
	internal static extern int SetWindowTheme(nint window, string? subAppName, string? subIdList);

	internal static void SetDarkTitleBar(nint window, bool on)
	{
		int value = on ? 1 : 0;
		try
		{
			// DWMWA_USE_IMMERSIVE_DARK_MODE = 20 (Windows 10 20H1 이후), 그 이전 빌드는 19
			if (DwmSetWindowAttribute(window, 20, ref value, sizeof(int)) != 0)
			{
				DwmSetWindowAttribute(window, 19, ref value, sizeof(int));
			}
		}
		catch
		{
		}
	}

	/// <summary>스크롤 막대 등 기본 컨트롤 부분을 라이트/다크 Explorer 테마로 그립니다.</summary>
	internal static void ApplyControlTheme(Control control, bool dark)
	{
		if (!control.IsHandleCreated)
		{
			return;
		}
		try
		{
			SetWindowTheme(control.Handle, dark ? "DarkMode_Explorer" : "Explorer", null);
		}
		catch
		{
		}
	}
}
