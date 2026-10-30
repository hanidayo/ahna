package me.ahna;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.res.ColorStateList;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.Outline;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.InsetDrawable;
import android.graphics.drawable.RippleDrawable;
import android.graphics.drawable.StateListDrawable;
import android.os.Build;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewOutlineProvider;
import android.view.Window;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.Calendar;
import java.util.Locale;

/** Ahna 1.1 디자인의 색·모양·공통 위젯. 시스템 다크 모드를 따릅니다. */
final class Ui {
    static final int MEDIUM = 500, BOLD = 700, REGULAR = 400;

    final Context ctx;
    final boolean dark;
    final float density;
    final int bg, surface, subtle, border, borderStrong, text, muted, faint, accent, onAccent, onAccentLine,
            accentSoft, on, off, danger, dangerSoft, pill, pillLine, pillOn;

    Ui(Context ctx) {
        this.ctx = ctx;
        this.dark = isDark(ctx);
        this.density = ctx.getResources().getDisplayMetrics().density;
        if (dark) {
            bg = 0xff1c1c1c; surface = 0xff272727; subtle = 0xff2e2e2e; border = 0xff3a3a3a; borderStrong = 0xff555555;
            text = 0xffe8eaed; muted = 0xffa7aeb8; faint = 0xff9aa1ab; accent = 0xff4cc2ff; onAccent = 0xff002033;
            onAccentLine = 0x59002033; accentSoft = 0xff16303f; on = 0xff4ade80; off = 0xff8b929c;
            danger = 0xfff2786f; dangerSoft = 0xff3a2321; pill = 0xf52a2e34; pillLine = 0xff3d424a; pillOn = 0xff3d424a;
        } else {
            bg = 0xffeef1f5; surface = 0xffffffff; subtle = 0xfff7f8fa; border = 0xffe3e6ea; borderStrong = 0xffc5cad1;
            text = 0xff1f2328; muted = 0xff5b636e; faint = 0xff6b7280; accent = 0xff005fb8; onAccent = 0xffffffff;
            onAccentLine = 0x73ffffff; accentSoft = 0xffe5eff9; on = 0xff1e7a48; off = 0xff9aa1ab;
            danger = 0xffc4372f; dangerSoft = 0xfffdecea; pill = 0xf0ffffff; pillLine = 0xffdfe2e6; pillOn = 0xffe9ebef;
        }
    }

    static boolean isDark(Context c) {
        return (c.getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
    }

    int dp(float v) { return Math.round(v * density); }
    /** -1 / -2 stay MATCH_PARENT / WRAP_CONTENT, anything else is dp. */
    int px(float v) { return v == -1 || v == -2 ? (int) v : dp(v); }

    // ---------- drawables ----------
    GradientDrawable round(int fill, float radius) {
        GradientDrawable d = new GradientDrawable(); d.setColor(fill); d.setCornerRadius(dp(radius)); return d;
    }
    GradientDrawable round(int fill, float radius, int stroke, float width) {
        GradientDrawable d = round(fill, radius); d.setStroke(Math.max(1, dp(width)), stroke); return d;
    }
    GradientDrawable dashed(int fill, float radius, int stroke, float width) {
        GradientDrawable d = round(fill, radius); d.setStroke(Math.max(1, dp(width)), stroke, dp(6), dp(4)); return d;
    }
    GradientDrawable oval(int fill) {
        GradientDrawable d = new GradientDrawable(); d.setShape(GradientDrawable.OVAL); d.setColor(fill); return d;
    }
    GradientDrawable ring(int stroke, float width) {
        GradientDrawable d = new GradientDrawable(); d.setShape(GradientDrawable.OVAL); d.setColor(Color.TRANSPARENT);
        d.setStroke(Math.max(1, dp(width)), stroke); return d;
    }
    int rippleColor() { return dark ? 0x33ffffff : 0x1f000000; }
    /** Ripple on top of an optional shape; the mask keeps the ripple inside the rounded corners. */
    Drawable pressable(Drawable content, float radius) {
        return new RippleDrawable(ColorStateList.valueOf(rippleColor()), content, round(0xff000000, radius));
    }
    /** Shadow outline that works for translucent backgrounds too (GradientDrawable reports alpha 0 for those). */
    void roundOutline(View v, final float radius) {
        v.setOutlineProvider(new ViewOutlineProvider() {
            @Override public void getOutline(View view, Outline outline) {
                outline.setRoundRect(0, 0, view.getWidth(), view.getHeight(), dp(radius));
                outline.setAlpha(0.9f);
            }
        });
    }

    // ---------- icons ----------
    Drawable iconDrawable(String name, int color) {
        int id = ctx.getResources().getIdentifier("ic_" + name, "drawable", ctx.getPackageName());
        if (id == 0) return null;
        Drawable d = ctx.getDrawable(id);
        if (d == null) return null;
        d = d.mutate(); d.setTint(color); return d;
    }
    ImageView icon(String name, int color) {
        ImageView v = new ImageView(ctx);
        v.setImageDrawable(iconDrawable(name, color));
        v.setScaleType(ImageView.ScaleType.FIT_CENTER);
        v.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        return v;
    }
    /** Icon centred in a rounded square (radius >= 0) or a circle (radius < 0). Add it with lp(box, box). */
    FrameLayout tile(String icon, float radius, float iconSize, int fill, int fg) {
        FrameLayout f = new FrameLayout(ctx);
        f.setBackground(radius < 0 ? oval(fill) : round(fill, radius));
        f.addView(icon(icon, fg), new FrameLayout.LayoutParams(dp(iconSize), dp(iconSize), Gravity.CENTER));
        f.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        return f;
    }
    /** Online = filled dot, offline = hollow ring (shape, not only colour). */
    View dot(boolean online) {
        View v = new View(ctx); v.setBackground(online ? oval(on) : ring(off, 1.5f));
        v.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        return v;
    }

    // ---------- layout ----------
    LinearLayout column() { LinearLayout l = new LinearLayout(ctx); l.setOrientation(LinearLayout.VERTICAL); return l; }
    LinearLayout row() {
        LinearLayout l = new LinearLayout(ctx); l.setOrientation(LinearLayout.HORIZONTAL); l.setGravity(Gravity.CENTER_VERTICAL); return l;
    }
    LinearLayout.LayoutParams lp(float w, float h) { return new LinearLayout.LayoutParams(px(w), px(h)); }
    LinearLayout.LayoutParams lp(float w, float h, float l, float t, float r, float b) {
        LinearLayout.LayoutParams p = lp(w, h); p.setMargins(dp(l), dp(t), dp(r), dp(b)); return p;
    }
    LinearLayout.LayoutParams flex(float weight) { return new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, weight); }
    View space(float w, float h) { View v = new View(ctx); v.setLayoutParams(lp(w, h)); return v; }
    View divider() { View v = new View(ctx); v.setBackgroundColor(border); v.setLayoutParams(new LinearLayout.LayoutParams(-1, Math.max(1, dp(1)))); return v; }
    LinearLayout card() {
        LinearLayout c = column(); c.setBackground(round(surface, 16, border, 1)); c.setPadding(dp(16), dp(16), dp(16), dp(16)); return c;
    }

    // ---------- text ----------
    static void weight(TextView t, int w) {
        t.setTypeface(w >= BOLD ? Typeface.DEFAULT_BOLD : Typeface.create(Typeface.DEFAULT, w, false));
    }
    TextView text(CharSequence s, float sp, int color, int weight) {
        TextView t = new TextView(ctx); t.setText(s); t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp); t.setTextColor(color); weight(t, weight);
        return t;
    }
    static <T extends TextView> T oneLine(T t) { t.setSingleLine(true); t.setEllipsize(TextUtils.TruncateAt.END); return t; }
    TextView heading(String s) { TextView t = text(s, 16, text, BOLD); t.setAccessibilityHeading(true); return t; }

    // ---------- buttons ----------
    Button button(String label, int fill, int fg, int stroke, float radius, float sp, int weight) {
        Button b = new Button(ctx);
        b.setText(label); b.setAllCaps(false); b.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp); b.setTextColor(fg); weight(b, weight);
        b.setStateListAnimator(null); b.setElevation(0);
        b.setMinHeight(0); b.setMinWidth(0); b.setMinimumHeight(0); b.setMinimumWidth(0);
        b.setPadding(dp(12), 0, dp(12), 0); b.setGravity(Gravity.CENTER);
        b.setBackground(pressable(stroke == 0 ? round(fill, radius) : round(fill, radius, stroke, 1), radius));
        return b;
    }
    Button primary(String label) { return button(label, accent, onAccent, 0, 12, 15, BOLD); }
    Button outline(String label) { return button(label, surface, accent, accent, 12, 14, BOLD); }
    Button soft(String label) { return button(label, accentSoft, accent, 0, 10, 13, BOLD); }
    Button plain(String label) { return button(label, surface, text, border, 10, 13, REGULAR); }
    void leadingIcon(TextView b, String icon, float size, int color) {
        Drawable d = iconDrawable(icon, color);
        if (d == null) return;
        d.setBounds(0, 0, dp(size), dp(size));
        b.setCompoundDrawablesRelative(d, null, null, null); b.setCompoundDrawablePadding(dp(6));
    }
    /** Transparent, round-rippled icon-only button with an accessibility label. */
    FrameLayout iconButton(String icon, float iconSize, int color, String label) {
        FrameLayout f = new FrameLayout(ctx);
        f.addView(icon(icon, color), new FrameLayout.LayoutParams(dp(iconSize), dp(iconSize), Gravity.CENTER));
        f.setBackground(pressable(null, 22));
        f.setClickable(true); f.setFocusable(true); f.setContentDescription(label);
        return f;
    }

    // ---------- inputs ----------
    EditText field(String hint) {
        EditText e = new EditText(ctx);
        e.setHint(hint); e.setTextColor(text); e.setHintTextColor(faint); e.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        StateListDrawable s = new StateListDrawable();
        s.addState(new int[]{android.R.attr.state_focused}, round(subtle, 12, accent, 1.5f));
        s.addState(new int[0], round(subtle, 12, border, 1));
        e.setBackground(s);
        e.setPadding(dp(12), dp(12), dp(12), dp(12));
        e.setHighlightColor(dark ? 0x664cc2ff : 0x55005fb8);
        GradientDrawable cursor = new GradientDrawable(); cursor.setColor(accent); cursor.setSize(dp(2), dp(18));
        e.setTextCursorDrawable(cursor);
        return e;
    }

    // ---------- dialogs ----------
    AlertDialog.Builder dialog() {
        return new AlertDialog.Builder(ctx, dark ? android.R.style.Theme_Material_Dialog_Alert : android.R.style.Theme_Material_Light_Dialog_Alert);
    }
    /** Padded body for a dialog's custom view. */
    LinearLayout dialogBody(View... children) {
        LinearLayout l = column(); l.setPadding(dp(20), dp(8), dp(20), dp(4));
        for (int i = 0; i < children.length; i++) l.addView(children[i], lp(-1, -2, 0, i == 0 ? 0 : 10, 0, 0));
        return l;
    }
    /** Shows the dialog in the Ahna palette. The positive button is drawn in accent (or danger when destructive). */
    AlertDialog show(AlertDialog d, boolean destructive) {
        d.show();
        Window w = d.getWindow();
        if (w != null) w.setBackgroundDrawable(new InsetDrawable(round(surface, 20), dp(16), dp(24), dp(16), dp(24)));
        Button p = d.getButton(AlertDialog.BUTTON_POSITIVE), n = d.getButton(AlertDialog.BUTTON_NEGATIVE), m = d.getButton(AlertDialog.BUTTON_NEUTRAL);
        if (p != null) { p.setTextColor(destructive ? danger : accent); p.setAllCaps(false); weight(p, BOLD); }
        if (n != null) { n.setTextColor(muted); n.setAllCaps(false); }
        if (m != null) { m.setTextColor(muted); m.setAllCaps(false); }
        return d;
    }

    // ---------- window ----------
    /** Draw behind the system bars (Android 15 forces this for targetSdk 35 anyway) and colour the bar icons. */
    void edgeToEdge(Activity a) {
        Window w = a.getWindow();
        w.setStatusBarColor(Color.TRANSPARENT);
        w.setNavigationBarColor(Color.TRANSPARENT);
        w.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        if (Build.VERSION.SDK_INT >= 30) {
            w.setDecorFitsSystemWindows(false);
            WindowInsetsController c = w.getInsetsController();
            if (c != null) {
                int light = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
                c.setSystemBarsAppearance(dark ? 0 : light, light);
            }
        } else {
            int flags = View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION;
            if (!dark) flags |= View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR;
            w.getDecorView().setSystemUiVisibility(flags);
        }
    }

    // ---------- formatting ----------
    static String size(long bytes) {
        if (bytes < 0) return "";
        if (bytes < 1024) return bytes + " B";
        if (bytes < 1024L * 1024) return Math.max(1, Math.round(bytes / 1024.0)) + " KB";
        if (bytes < 1024L * 1024 * 1024) return String.format(Locale.ROOT, "%.1f MB", bytes / (1024.0 * 1024));
        return String.format(Locale.ROOT, "%.1f GB", bytes / (1024.0 * 1024 * 1024));
    }
    /** 2026. 10. 30. 오후 12:51 */
    static String stamp(long at) { return at <= 0 ? "" : new java.text.SimpleDateFormat("yyyy. M. d. a h:mm", Locale.KOREA).format(new java.util.Date(at)); }
    static String ago(long at) {
        if (at <= 0) return "";
        long diff = System.currentTimeMillis() - at;
        if (diff < 60_000L) return "방금";
        if (diff < 3_600_000L) return (diff / 60_000L) + "분 전";
        Calendar then = Calendar.getInstance(); then.setTimeInMillis(at);
        Calendar today = Calendar.getInstance();
        boolean sameDay = then.get(Calendar.YEAR) == today.get(Calendar.YEAR) && then.get(Calendar.DAY_OF_YEAR) == today.get(Calendar.DAY_OF_YEAR);
        if (sameDay) return (diff / 3_600_000L) + "시간 전";
        Calendar yesterday = Calendar.getInstance(); yesterday.add(Calendar.DAY_OF_YEAR, -1);
        if (then.get(Calendar.YEAR) == yesterday.get(Calendar.YEAR) && then.get(Calendar.DAY_OF_YEAR) == yesterday.get(Calendar.DAY_OF_YEAR)) return "어제";
        return (then.get(Calendar.MONTH) + 1) + "월 " + then.get(Calendar.DAY_OF_MONTH) + "일";
    }
    /** "사무실 PC" + "로", "MacBook" → "로", "갤럭시 탭" → "으로" (받침 있는 한글, ㄹ 제외). */
    static String toward(String name) {
        if (name == null || name.isEmpty()) return "로";
        char c = name.charAt(name.length() - 1);
        if (c >= 0xAC00 && c <= 0xD7A3) {
            int jong = (c - 0xAC00) % 28;
            if (jong != 0 && jong != 8) return name + "으로";
        }
        return name + "로";
    }
    static String code(String pin) {
        if (pin == null || pin.length() != 6) return pin == null ? "------" : pin;
        return pin.substring(0, 3) + " " + pin.substring(3);
    }
    static String deviceIcon(String platform) {
        if (platform == null) return "monitor";
        String p = platform.toLowerCase(Locale.ROOT);
        if (p.contains("mac")) return "laptop";
        if (p.contains("ios") || p.contains("iphone") || p.contains("ipad") || p.contains("android")) return "phone";
        return "monitor";
    }
}
