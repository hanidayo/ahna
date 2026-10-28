package me.ahna;

import android.app.Dialog;
import android.bluetooth.BluetoothAdapter;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.provider.OpenableColumns;
import android.provider.Settings;
import android.view.Gravity;
import android.view.HapticFeedbackConstants;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * 아나 1.2 근처 기기 · QR (ios/Ahna/Nearby.swift NearbyCenter + NearbyViews.swift와 같은 동작과 문구).
 * 받는 쪽: '10분 동안 모두'일 때 광고 → 상대가 inbox에 제안을 쓰면 확인 창(30초 자동 거절) → 받기면 상대 서버의 게스트 주소에서 info → file/{i}.
 * 보내는 쪽: 근처 기기를 고르면 이 기기 서버에 1회용 티켓(kind=send)을 만들고 상대 inbox에 제안을 씁니다.
 * QR: 같은 티켓을 QR로 보여 줍니다(받는 사람은 앱이 없어도 됨). QR로 받기는 웹 페이지가 올리기 전에 이 기기 주인에게 묻습니다.
 * 모든 메서드는 화면 스레드에서 부릅니다(라디오·서버 알림은 runOnUiThread로 옮겨 옴).
 */
final class NearbyUi implements NearbyRadio.Listener, Protocol.GuestListener {
    static final long EVERYONE = 600_000L;
    static final int PERMISSION_REQUEST = 7;

    final MainActivity a;
    final SharedPreferences prefs;
    final NearbyRadio radio;
    final ExecutorService work = Executors.newFixedThreadPool(2);
    String mode;
    long everyoneUntil;
    NearbyRadio.State bt = NearbyRadio.State.UNKNOWN;
    List<NearbyRadio.Device> devices = new ArrayList<>();
    boolean foreground, closed;

    // 화면(MainActivity.buildUI가 다시 만들 때마다 새로 붙임)
    LinearLayout nearBox, optionsBox;
    String nearPrint = "", optionsPrint = "";

    final Runnable ticker = new Runnable() { public void run() {
        if (closed) return;
        tick();
        a.handler.postDelayed(this, 500);
    } };

    NearbyUi(MainActivity activity) {
        a = activity;
        prefs = activity.prefs;
        radio = new NearbyRadio(activity, this);
        String saved = prefs.getString("nearbyReceiveMode", "registered");
        long until = prefs.getLong("nearbyEveryoneUntil", 0);
        if (!saved.equals("off") && !saved.equals("everyone")) saved = "registered";
        if (saved.equals("everyone") && until <= System.currentTimeMillis()) { saved = "registered"; prefs.edit().putString("nearbyReceiveMode", saved).apply(); }
        mode = saved; everyoneUntil = saved.equals("everyone") ? until : 0;
    }

    // ---------- 색 (근처 기기 보라) ----------
    int near() { return a.ui.dark ? 0xffa78bfa : 0xff7c3aed; }
    int soft() { return a.ui.dark ? 0xff2b2140 : 0xfff1ebfe; }
    int nearText() { return a.ui.dark ? 0xffc4b5fd : 0xff6d28d9; }
    int dp(float v) { return a.ui.dp(v); }

    // ---------- 상태 ----------

    String deviceName() { return Protocol.cleanName(a.deviceName(), "Android"); }
    byte[] card() {
        try { return new JSONObject().put("v", 1).put("name", deviceName()).put("platform", "Android").toString().getBytes(StandardCharsets.UTF_8); }
        catch (Exception e) { return new byte[0]; }
    }
    /** 근처 기기 목록을 보여 줄 수 있는지(Bluetooth 켜짐 · 권한 있음 · 앱이 화면에 있음) */
    boolean available() { return bt == NearbyRadio.State.ON && foreground; }
    void applyRadio() { radio.update(foreground, foreground && mode.equals("everyone"), card()); }

    void setForeground(boolean value) {
        foreground = value;
        a.handler.removeCallbacks(ticker);
        if (value) { a.handler.post(ticker); maybeAskPermission(); }
        else { devices = new ArrayList<>(); }
        applyRadio();
        renderAll();
    }
    /** 이 기기 이름을 바꾼 뒤 근처에 보이는 이름도 바꿉니다. */
    void refreshName() { applyRadio(); optionsPrint = ""; renderOptions(); }

    void setMode(String value) {
        mode = value;
        everyoneUntil = value.equals("everyone") ? System.currentTimeMillis() + EVERYONE : 0;
        prefs.edit().putString("nearbyReceiveMode", value).putLong("nearbyEveryoneUntil", everyoneUntil).apply();
        if (value.equals("everyone") && bt == NearbyRadio.State.UNAUTHORIZED) askPermission();
        applyRadio();
        optionsPrint = ""; renderOptions();
    }
    String everyoneRemaining() {
        if (!mode.equals("everyone") || everyoneUntil == 0) return null;
        return clock(everyoneUntil - System.currentTimeMillis());
    }
    static String clock(long millis) {
        long s = Math.max(0, (millis + 999) / 1000);
        return (s / 60) + ":" + String.format(Locale.ROOT, "%02d", s % 60);
    }

    void tick() {
        long now = System.currentTimeMillis();
        if (mode.equals("everyone") && everyoneUntil != 0 && everyoneUntil <= now) setMode("registered");
        if (incoming != null) {
            if (incoming.phase.equals("asking") && now >= incoming.deadline) decline();
            else if (incoming.guest && incoming.phase.equals("receiving")) followGuest();
        }
        followOutgoing();
        renderIncoming();
        renderOutgoing();
        renderQr();
        renderOptions();
    }

    // ---------- 권한 ----------

    void maybeAskPermission() {
        // 처음 한 번만 스스로 묻습니다(아이폰이 처음 실행할 때 Bluetooth 권한을 묻는 것처럼). 가입 전에는 묻지 않습니다.
        if (prefs.getBoolean("nearbyAsked", false) || !radio.supported() || NearbyRadio.permitted(a) || prefs.getString("nasKey", "").isEmpty()) return;
        askPermission();
    }
    void askPermission() {
        boolean asked = prefs.getBoolean("nearbyAsked", false);
        boolean rationale = false;
        for (String p : NearbyRadio.permissions()) rationale |= a.shouldShowRequestPermissionRationale(p);
        if (asked && !rationale) {
            // 다시 묻지 않음으로 거절된 경우: 앱 설정을 엽니다.
            try { a.startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + a.getPackageName()))); }
            catch (Exception e) { a.status("설정 › 앱 › 아나 › 권한에서 ‘근처 기기’를 허용하세요."); }
            return;
        }
        prefs.edit().putBoolean("nearbyAsked", true).apply();
        try { a.requestPermissions(NearbyRadio.permissions(), PERMISSION_REQUEST); } catch (Exception ignored) {}
    }
    void permissionResult() { radio.refresh(); applyRadio(); }

    // ---------- 라디오 알림 (Bluetooth 스레드 → 화면) ----------

    @Override public void devices(List<NearbyRadio.Device> list) {
        a.runOnUiThread(() -> { if (closed) return; devices = foreground ? list : new ArrayList<>(); renderAll(); a.targetPrint = ""; a.updateTargets(); });
    }
    @Override public void state(NearbyRadio.State value) {
        a.runOnUiThread(() -> { if (closed) return; bt = value; renderAll(); a.targetPrint = ""; a.updateTargets(); });
    }
    @Override public void offer(NearbyRadio.Offer offer) { a.runOnUiThread(() -> received(offer)); }

    // ---------- 서버(게스트 티켓) 알림 ----------

    @Override public void ticketsChanged() { a.runOnUiThread(() -> { if (!closed) tick(); }); }
    @Override public void guestRequested(Protocol.Ticket t) { a.runOnUiThread(() -> guestRequest(t)); }
    @Override public void guestReceived(File file, String name, String sender) throws Exception { a.export(file, name, sender); }

    NearbyRadio.Device device(String id) { for (NearbyRadio.Device d : devices) if (d.id.equals(id)) return d; return null; }

    void renderAll() { nearPrint = ""; optionsPrint = ""; renderTargets(); renderOptions(); }

    // =====================================================================================
    // 보낼 기기: 근처 기기 (NearbyPhone)
    // =====================================================================================

    void renderTargets() {
        if (nearBox == null) return;
        Ui ui = a.ui;
        boolean unauthorized = bt == NearbyRadio.State.UNAUTHORIZED && radio.supported();
        StringBuilder print = new StringBuilder(bt + "/" + foreground + "/" + a.targetKey);
        for (NearbyRadio.Device d : devices) print.append('|').append(d.print());
        if (print.toString().equals(nearPrint)) return;
        nearPrint = print.toString();
        nearBox.removeAllViews();
        if (!available() && !unauthorized) { nearBox.setVisibility(View.GONE); return; }
        nearBox.setVisibility(View.VISIBLE);
        nearBox.addView(ui.divider(), ui.lp(-1, 1, 0, 0, 0, 10));
        LinearLayout head = ui.row();
        head.addView(ui.tile("bluetooth", 8, 15, soft(), near()), ui.lp(26, 26, 0, 0, 8, 0));
        TextView title = ui.text("근처 기기", 13, ui.text, Ui.BOLD);
        title.setAccessibilityHeading(true);
        head.addView(title, ui.lp(-2, -2, 0, 0, 8, 0));
        head.addView(Ui.oneLine(ui.text("Bluetooth · 가까운 기기만 보입니다", 12, ui.faint, Ui.REGULAR)), ui.flex(1));
        nearBox.addView(head, new LinearLayout.LayoutParams(-1, -2));
        if (unauthorized) {
            LinearLayout row = ui.row();
            row.addView(ui.text("근처 기기를 찾으려면 ‘근처 기기’ 권한이 필요합니다", 12, ui.faint, Ui.REGULAR), ui.flex(1));
            Button allow = ui.soft("허용");
            allow.setPadding(dp(14), 0, dp(14), 0);
            allow.setOnClickListener(v -> askPermission());
            row.addView(allow, ui.lp(-2, 34, 8, 0, 0, 0));
            nearBox.addView(row, ui.lp(-1, -2, 0, 8, 0, 0));
            return;
        }
        for (NearbyRadio.Device d : devices) {
            boolean selected = ("near:" + d.id).equals(a.targetKey);
            LinearLayout row = ui.row();
            row.setMinimumHeight(dp(58));
            row.setPadding(dp(12), dp(6), dp(12), dp(6));
            row.setBackground(ui.pressable(selected ? ui.round(soft(), 12, near(), 2) : ui.round(ui.surface, 12, ui.border, 1), 12));
            row.addView(avatar(d.name, 38, selected), ui.lp(38, 38, 0, 0, 12, 0));
            LinearLayout texts = ui.column();
            texts.addView(Ui.oneLine(ui.text(d.name, 14, ui.text, Ui.MEDIUM)));
            if (!d.platform.isEmpty()) texts.addView(Ui.oneLine(ui.text(d.platform, 12, ui.faint, Ui.REGULAR)));
            row.addView(texts, ui.flex(1));
            row.addView(badge(d), ui.lp(-2, 24, 4, 0, 0, 0));
            row.setClickable(true); row.setFocusable(true); row.setSelected(selected);
            row.setContentDescription(d.name + ", 근처 기기, " + d.proximity() + (selected ? ", 선택됨" : ""));
            row.setOnClickListener(v -> { a.targetKey = "near:" + d.id; a.targetPrint = ""; a.updateTargets(); });
            nearBox.addView(row, ui.lp(-1, -2, 0, 8, 0, 0));
        }
        LinearLayout foot = ui.row();
        View dot = new View(a); dot.setBackground(ui.oval(near())); dot.setAlpha(0.6f);
        foot.addView(dot, ui.lp(8, 8, 0, 0, 8, 0));
        foot.addView(ui.text(devices.isEmpty() ? "근처 기기를 찾는 중… 상대도 아나를 열어 두어야 보입니다" : "상대도 아나를 열어 두어야 보입니다", 12, ui.faint, Ui.REGULAR), ui.flex(1));
        nearBox.addView(foot, ui.lp(-1, -2, 0, 8, 0, 0));
    }

    View avatar(String name, float size, boolean strong) {
        Ui ui = a.ui;
        String trimmed = name == null ? "" : name.trim();
        String letter = trimmed.isEmpty() ? "?" : new String(Character.toChars(trimmed.codePointAt(0))).toUpperCase(Locale.ROOT);
        TextView t = ui.text(letter, size * 0.4f, strong ? Color.WHITE : ui.muted, Ui.BOLD);
        t.setGravity(Gravity.CENTER);
        t.setBackground(ui.oval(strong ? near() : ui.subtle));
        t.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        t.setIncludeFontPadding(false);
        return t;
    }
    View badge(NearbyRadio.Device d) {
        Ui ui = a.ui;
        TextView t = ui.text(d.proximity(), 12, d.near ? nearText() : ui.muted, Ui.MEDIUM);
        t.setGravity(Gravity.CENTER);
        t.setPadding(dp(8), 0, dp(8), 0);
        t.setBackground(ui.round(d.near ? soft() : ui.subtle, 12));
        t.setSingleLine(true);
        return t;
    }
    /** 확인 숫자 "47" → 두 칸 */
    View digits(String code, boolean big) {
        Ui ui = a.ui;
        LinearLayout row = ui.row();
        for (int i = 0; i < code.length(); i++) {
            TextView t = ui.text(String.valueOf(code.charAt(i)), big ? 34 : 26, ui.text, Ui.BOLD);
            t.setGravity(Gravity.CENTER);
            t.setFontFeatureSettings("tnum");
            t.setIncludeFontPadding(false);
            t.setBackground(ui.round(big ? ui.subtle : Color.TRANSPARENT, big ? 12 : 10, ui.border, 1));
            row.addView(t, ui.lp(big ? 52 : 40, big ? 64 : 48, i == 0 ? 0 : (big ? 8 : 6), 0, 0, 0));
        }
        row.setContentDescription("확인 숫자 " + String.join(" ", code.split("")));
        return row;
    }

    // =====================================================================================
    // 옵션: 근처 기기에서 받기 (NearbyOptions)
    // =====================================================================================

    LinearLayout optionsCard() {
        Ui ui = a.ui;
        LinearLayout card = ui.card();
        LinearLayout head = ui.row();
        head.addView(ui.tile("bluetooth", 10, 17, soft(), near()), ui.lp(34, 34, 0, 0, 10, 0));
        LinearLayout titles = ui.column();
        titles.addView(ui.heading("근처 기기에서 받기"));
        titles.addView(ui.text("등록하지 않은 사람이 가까이에서 보낼 수 있습니다", 12, ui.faint, Ui.REGULAR));
        head.addView(titles, ui.flex(1));
        card.addView(head);
        optionsBox = ui.column();
        card.addView(optionsBox, new LinearLayout.LayoutParams(-1, -2));
        optionsPrint = "";
        renderOptions();
        return card;
    }

    void renderOptions() {
        if (optionsBox == null) return;
        Ui ui = a.ui;
        String left = everyoneRemaining();
        String print = mode + "/" + left + "/" + bt + "/" + deviceName();
        if (print.equals(optionsPrint)) return;
        optionsPrint = print;
        optionsBox.removeAllViews();
        // 끔 · 등록된 기기만 · 10분 동안 모두 (segmented)
        final String[] modes = {"off", "registered", "everyone"}, labels = {"끔", "등록된 기기만", "10분 동안 모두"};
        LinearLayout group = ui.row();
        group.setPadding(dp(3), dp(3), dp(3), dp(3));
        group.setBackground(ui.round(ui.subtle, 10, ui.border, 1));
        for (int i = 0; i < modes.length; i++) {
            final String value = modes[i];
            boolean on = value.equals(mode);
            TextView b = Ui.oneLine(ui.text(labels[i], 13, on ? (value.equals("everyone") ? nearText() : ui.text) : ui.muted, on ? Ui.MEDIUM : Ui.REGULAR));
            b.setGravity(Gravity.CENTER);
            b.setPadding(dp(6), 0, dp(6), 0);
            b.setBackground(on ? ui.round(value.equals("everyone") ? soft() : ui.surface, 8, value.equals("everyone") ? near() : ui.border, 1) : ui.pressable(null, 8));
            b.setClickable(true); b.setFocusable(true); b.setSelected(on);
            b.setContentDescription("근처 기기에서 받기 " + labels[i] + (on ? ", 선택됨" : ""));
            b.setOnClickListener(v -> { if (!mode.equals(value) || value.equals("everyone")) setMode(value); });
            group.addView(b, new LinearLayout.LayoutParams(0, dp(36), i == 2 ? 1.3f : 1f));
        }
        optionsBox.addView(group, ui.lp(-1, -2, 0, 12, 0, 0));
        String hint = mode.equals("off") ? "근처 기기에 이 기기가 보이지 않습니다"
                : mode.equals("registered") ? "내가 등록한 기기에게만 보입니다 (기본값)"
                : "근처의 누구나 보낼 수 있고, 매번 받을지 묻습니다";
        LinearLayout hintRow = ui.row();
        hintRow.addView(ui.text(hint, 12, ui.faint, Ui.REGULAR), ui.flex(1));
        if (left != null) {
            TextView remain = ui.text(left + " 남음", 13, nearText(), Ui.BOLD);
            remain.setFontFeatureSettings("tnum");
            hintRow.addView(remain, ui.lp(-2, -2, 8, 0, 0, 0));
        }
        optionsBox.addView(hintRow, ui.lp(-1, -2, 0, 8, 0, 0));
        if (mode.equals("everyone") && bt == NearbyRadio.State.ON && !radio.canAdvertise())
            optionsBox.addView(ui.text("이 기기는 Bluetooth 광고를 지원하지 않아 근처 기기에 보이지 않습니다 · 보내기와 QR은 쓸 수 있습니다", 12, ui.danger, Ui.REGULAR), ui.lp(-1, -2, 0, 6, 0, 0));
        LinearLayout nameRow = ui.row();
        nameRow.setPadding(dp(12), dp(10), dp(12), dp(10));
        nameRow.setBackground(ui.round(ui.subtle, 12));
        nameRow.addView(ui.text("근처에 보이는 이름", 13, ui.muted, Ui.REGULAR), ui.flex(1));
        nameRow.addView(Ui.oneLine(ui.text(deviceName(), 13, ui.text, Ui.MEDIUM)), ui.lp(-2, -2, 8, 0, 0, 0));
        optionsBox.addView(nameRow, ui.lp(-1, -2, 0, 12, 0, 0));
        LinearLayout status = ui.row();
        status.setGravity(Gravity.CENTER_VERTICAL);
        String text; int color; String action = null;
        switch (bt) {
            case ON: text = "Bluetooth 켜짐 · 받는 동안 아나를 열어 두세요"; color = ui.on; break;
            case OFF: text = "Bluetooth가 꺼져 있습니다 · 켜면 근처 기기를 쓸 수 있습니다"; color = ui.off; action = "켜기"; break;
            case LOCATION_OFF: text = "위치가 꺼져 있습니다 · 이 Android 버전은 근처 기기를 찾을 때 위치를 켜야 합니다"; color = ui.off; action = "설정"; break;
            case UNAUTHORIZED: text = "‘근처 기기’ 권한이 없습니다 · 허용하면 근처 기기를 쓸 수 있습니다"; color = ui.danger; action = "허용"; break;
            case UNSUPPORTED: text = "이 기기는 Bluetooth LE를 지원하지 않아 근처 기기를 쓸 수 없습니다 · QR은 쓸 수 있습니다"; color = ui.off; break;
            default: text = "Bluetooth 확인 중…"; color = ui.off; break;
        }
        View dot = new View(a); dot.setBackground(ui.oval(color));
        status.addView(dot, ui.lp(8, 8, 0, 0, 8, 0));
        status.addView(ui.text(text, 12, ui.faint, Ui.REGULAR), ui.flex(1));
        if (action != null) {
            Button b = ui.soft(action);
            b.setPadding(dp(12), 0, dp(12), 0);
            final String which = action;
            b.setOnClickListener(v -> {
                if (which.equals("허용")) askPermission();
                else if (which.equals("켜기")) { try { a.startActivity(new Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)); } catch (Exception e) { openSettings(Settings.ACTION_BLUETOOTH_SETTINGS); } }
                else openSettings(Settings.ACTION_LOCATION_SOURCE_SETTINGS);
            });
            status.addView(b, ui.lp(-2, 32, 8, 0, 0, 0));
        }
        optionsBox.addView(status, ui.lp(-1, -2, 0, 12, 0, 0));
    }
    void openSettings(String action) { try { a.startActivity(new Intent(action)); } catch (Exception e) { a.status("설정 앱에서 켜 주세요."); } }

    /** 옵션: 근처 기기로 보낼 때 안내 */
    LinearLayout sendInfoCard() {
        Ui ui = a.ui;
        LinearLayout card = ui.card();
        card.setPadding(dp(16), dp(14), dp(16), dp(14));
        TextView h = ui.text("보낼 때", 14, ui.text, Ui.BOLD);
        h.setAccessibilityHeading(true);
        card.addView(h);
        card.addView(ui.text("근처 기기나 QR로 보내면 파일은 내 서버를 거쳐 갑니다. 상대는 그 파일만 받을 수 있고, 다 받으면 접근 권한이 바로 없어집니다. 이 기기는 아나가 화면에 열려 있는 동안만 보내고 받을 수 있습니다.", 13, ui.muted, Ui.REGULAR), ui.lp(-1, -2, 0, 6, 0, 0));
        return card;
    }

    // =====================================================================================
    // 공통: 창 (휴대폰: 아래에서 올라오는 시트, 태블릿: 가운데 창)
    // =====================================================================================

    Dialog sheet(View content, boolean modal) {
        Ui ui = a.ui;
        boolean wide = a.getResources().getConfiguration().screenWidthDp >= 600;
        ScrollView scroll = new ScrollView(a);
        LinearLayout box = ui.column();
        if (wide) {
            box.setBackground(ui.round(ui.surface, 24));
            box.setPadding(dp(22), dp(22), dp(22), dp(22));
        } else {
            GradientDrawable d = new GradientDrawable();
            d.setColor(ui.surface);
            float r = dp(24);
            d.setCornerRadii(new float[]{r, r, r, r, 0, 0, 0, 0});
            box.setBackground(d);
            box.setPadding(dp(16), dp(10), dp(16), dp(24));
            View handle = new View(a);
            handle.setBackground(ui.round(ui.border, 2));
            LinearLayout.LayoutParams hl = ui.lp(36, 4, 0, 0, 0, 14);
            hl.gravity = Gravity.CENTER_HORIZONTAL;
            box.addView(handle, hl);
        }
        box.addView(content, new LinearLayout.LayoutParams(-1, -2));
        scroll.addView(box, new FrameLayout.LayoutParams(-1, -2));
        Dialog dialog = new Dialog(a, ui.dark ? android.R.style.Theme_Material_Dialog_NoActionBar : android.R.style.Theme_Material_Light_Dialog_NoActionBar);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        dialog.setContentView(scroll);
        dialog.setCanceledOnTouchOutside(!modal);
        dialog.setCancelable(!modal);
        Window w = dialog.getWindow();
        if (w != null) {
            w.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            w.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            w.setDimAmount(0.5f);
            if (!wide) w.setWindowAnimations(android.R.style.Animation_InputMethod);
        }
        dialog.show();
        if (w != null) {
            if (wide) { w.setLayout(Math.min(dp(520), a.getResources().getDisplayMetrics().widthPixels - dp(32)), WindowManager.LayoutParams.WRAP_CONTENT); w.setGravity(Gravity.CENTER); }
            else { w.setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.WRAP_CONTENT); w.setGravity(Gravity.BOTTOM); }
        }
        return dialog;
    }
    Button button(String label, boolean primary) {
        Ui ui = a.ui;
        return primary ? ui.primary(label) : ui.button(label, ui.subtle, ui.text, 0, 12, 14, Ui.MEDIUM);
    }
    View result(boolean positive, String title, String detail) {
        Ui ui = a.ui;
        LinearLayout box = ui.column();
        box.setGravity(Gravity.CENTER_HORIZONTAL);
        box.addView(ui.tile(positive ? "check" : "close_bold", -1, positive ? 26 : 20, positive ? ui.accentSoft : ui.subtle, positive ? ui.accent : ui.muted), ui.lp(56, 56, 0, 6, 0, 8));
        TextView t = ui.text(title, 17, ui.text, Ui.BOLD); t.setGravity(Gravity.CENTER);
        box.addView(t, ui.lp(-1, -2, 0, 0, 0, 4));
        TextView d = ui.text(detail, 12, ui.faint, Ui.REGULAR); d.setGravity(Gravity.CENTER);
        box.addView(d, ui.lp(-1, -2));
        return box;
    }
    static String summary(List<String> names) {
        int images = 0, movies = 0;
        for (String n : names) {
            String x = n.toLowerCase(Locale.ROOT);
            if (x.matches(".*\\.(jpe?g|png|gif|heic|heif|webp|bmp|dng|avif)$")) images++;
            else if (x.matches(".*\\.(mp4|mov|m4v|3gp|webm|mkv|avi)$")) movies++;
        }
        int n = names.size();
        if (n > 0 && images == n) return "사진 " + n + "장";
        if (n > 0 && movies == n) return "동영상 " + n + "개";
        if (n > 0 && images + movies == n) return "사진·동영상 " + n + "개";
        return "파일 " + n + "개";
    }
    static String code() { return String.valueOf(10 + new SecureRandom().nextInt(90)); }

    /** 고른 파일을 이 앱 안(게스트 티켓 자리)에 복사합니다. names에 안전한 이름을 채웁니다. */
    List<File> stage(List<Uri> uris, List<String> names) throws Exception {
        List<File> staged = new ArrayList<>();
        try {
            for (Uri uri : uris) {
                String display = "파일";
                try (Cursor cursor = a.getContentResolver().query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
                    if (cursor != null && cursor.moveToFirst() && cursor.getString(0) != null) display = cursor.getString(0);
                } catch (Exception ignored) {}
                display = Protocol.safeName(display);
                File f = a.server.guestStaging();
                staged.add(f);
                try (InputStream in = a.getContentResolver().openInputStream(uri); OutputStream out = new FileOutputStream(f)) {
                    if (in == null) throw new IOException("파일을 열 수 없습니다.");
                    byte[] buffer = new byte[65536]; long total = 0; int n;
                    while ((n = in.read(buffer)) >= 0) { total += n; if (total > Protocol.MAX) throw new IOException("파일 한 개는 최대 4 GiB입니다."); out.write(buffer, 0, n); }
                }
                names.add(display);
            }
            return staged;
        } catch (Exception e) {
            for (File f : staged) f.delete();
            throw e;
        }
    }
    List<String> pendingNames(List<Uri> uris) {
        List<String> names = new ArrayList<>();
        for (Uri u : uris) names.add(a.meta(u)[0]);
        return names;
    }

    // =====================================================================================
    // 받는 쪽 확인 창 (NearbyRequest)
    // =====================================================================================

    static final class Incoming {
        boolean guest; NearbyRadio.Offer offer; String token;
        String sender, detail, code, summary, firstName; int count; long bytes, deadline;
        /** asking · receiving · done · failed */
        String phase = "asking", text = "";
    }
    Incoming incoming;
    Dialog incomingDialog;
    String incomingPrint = "";
    LinearLayout incomingBody;

    void received(NearbyRadio.Offer offer) {
        if (closed || !foreground || !mode.equals("everyone")) return;
        if (incoming != null && (incoming.phase.equals("asking") || incoming.phase.equals("receiving"))) return;
        Incoming r = new Incoming();
        r.offer = offer; r.sender = offer.name; r.detail = "등록하지 않은 기기 · Bluetooth" + (offer.platform.isEmpty() ? "" : " · " + offer.platform);
        r.code = offer.code; r.count = offer.count; r.bytes = offer.bytes; r.summary = offer.summary; r.deadline = System.currentTimeMillis() + 30_000;
        showIncoming(r);
    }
    void guestRequest(Protocol.Ticket t) {
        if (closed) return;
        if (incoming != null && (incoming.phase.equals("asking") || incoming.phase.equals("receiving"))) { a.server.answerGuest(t.token, false); return; }
        Incoming r = new Incoming();
        r.guest = true; r.token = t.token; r.sender = t.sender; r.detail = "QR로 연 웹 페이지 · 등록하지 않은 기기";
        r.code = t.code == null ? "" : t.code; r.count = t.files.size(); r.bytes = t.total();
        List<String> names = new ArrayList<>(); for (Protocol.GuestFile f : t.files) names.add(f.name);
        r.summary = summary(names); r.firstName = names.isEmpty() ? null : names.get(0);
        r.deadline = System.currentTimeMillis() + 30_000;
        showIncoming(r);
    }
    void showIncoming(Incoming r) {
        incoming = r;
        if (incomingDialog != null) incomingDialog.dismiss();
        incomingBody = a.ui.column();
        incomingPrint = "";
        incomingDialog = sheet(incomingBody, true);
        renderIncoming();
        try { incomingBody.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS); } catch (Exception ignored) {}
        incomingBody.announceForAccessibility(r.sender + (r.guest ? "이 QR로 연 페이지에서 보내려고 합니다" : "이 근처에서 보내려고 합니다"));
    }
    void renderIncoming() {
        Incoming r = incoming;
        if (r == null || incomingBody == null) return;
        long seconds = Math.max(0, (r.deadline - System.currentTimeMillis() + 999) / 1000);
        String print = r.phase + "/" + r.text + "/" + (r.phase.equals("asking") ? seconds : 0);
        if (print.equals(incomingPrint)) return;
        incomingPrint = print;
        Ui ui = a.ui;
        LinearLayout b = incomingBody;
        b.removeAllViews();
        LinearLayout tag = ui.row();
        tag.addView(ui.icon(r.guest ? "qr" : "bluetooth", nearText()), ui.lp(14, 14, 0, 0, 8, 0));
        tag.addView(ui.text(r.guest ? "QR로 연 페이지에서 보내려고 합니다" : "근처 기기에서 보내려고 합니다", 12, nearText(), Ui.MEDIUM));
        b.addView(tag, ui.lp(-1, -2, 0, 0, 0, 14));
        LinearLayout who = ui.row();
        who.addView(avatar(r.sender, 52, true), ui.lp(52, 52, 0, 0, 12, 0));
        LinearLayout names = ui.column();
        names.addView(Ui.oneLine(ui.text(r.sender, 18, ui.text, Ui.BOLD)));
        TextView detail = ui.text(r.detail, 12, ui.muted, Ui.REGULAR); detail.setMaxLines(2);
        names.addView(detail);
        who.addView(names, ui.flex(1));
        b.addView(who, ui.lp(-1, -2, 0, 0, 0, 14));
        LinearLayout file = ui.row();
        file.setPadding(dp(12), dp(12), dp(12), dp(12));
        file.setBackground(ui.round(ui.subtle, 14));
        file.addView(ui.tile(r.summary.startsWith("사진") ? "image" : "file", 9, 18, ui.surface, ui.muted), ui.lp(44, 44, 0, 0, 12, 0));
        LinearLayout ft = ui.column();
        ft.addView(ui.text(r.summary, 14, ui.text, Ui.BOLD));
        List<String> parts = new ArrayList<>();
        if (r.firstName != null) parts.add(r.count > 1 ? r.firstName + " 외 " + (r.count - 1) + "개" : r.firstName);
        else if (r.count > 0) parts.add(r.count + "개");
        if (r.bytes > 0) parts.add(Ui.size(r.bytes));
        if (!parts.isEmpty()) ft.addView(Ui.oneLine(ui.text(String.join(" · ", parts), 12, ui.faint, Ui.REGULAR)));
        file.addView(ft, ui.flex(1));
        b.addView(file, ui.lp(-1, -2, 0, 0, 0, 14));
        switch (r.phase) {
            case "asking": {
                LinearLayout ask = ui.row();
                ask.addView(ui.text("보내는 사람 화면의 숫자와 같나요?", 13, ui.muted, Ui.REGULAR), ui.flex(1));
                ask.addView(digits(r.code, false), ui.lp(-2, -2, 4, 0, 0, 0));
                b.addView(ask, ui.lp(-1, -2, 0, 0, 0, 14));
                LinearLayout buttons = ui.row();
                Button no = button("거절", false); no.setOnClickListener(v -> decline());
                Button yes = button("받기", true); yes.setOnClickListener(v -> accept());
                buttons.addView(no, new LinearLayout.LayoutParams(0, dp(52), 1));
                LinearLayout.LayoutParams yl = new LinearLayout.LayoutParams(0, dp(52), 1); yl.leftMargin = dp(10);
                buttons.addView(yes, yl);
                b.addView(buttons, new LinearLayout.LayoutParams(-1, -2));
                TextView note = ui.text("받은 파일은 평소처럼 저장됩니다 · " + seconds + "초 뒤 자동 거절", 12, ui.faint, Ui.REGULAR);
                note.setGravity(Gravity.CENTER);
                b.addView(note, ui.lp(-1, -2, 0, 12, 0, 0));
                break;
            }
            case "receiving": {
                LinearLayout row = ui.row();
                ProgressBar spin = new ProgressBar(a);
                spin.setIndeterminate(true);
                spin.setIndeterminateTintList(android.content.res.ColorStateList.valueOf(ui.accent));
                row.addView(spin, ui.lp(22, 22, 0, 0, 10, 0));
                TextView t = ui.text(r.text, 13, ui.muted, Ui.REGULAR); t.setMaxLines(2);
                row.addView(t, ui.flex(1));
                b.addView(row, ui.lp(-1, -2, 0, 0, 0, 8));
                b.addView(ui.text("다 받을 때까지 아나를 열어 두세요", 12, ui.faint, Ui.REGULAR), ui.lp(-1, -2, 0, 0, 0, 12));
                Button close = button("창 닫기", false); close.setOnClickListener(v -> dismissIncoming());
                b.addView(close, ui.lp(-1, 48));
                break;
            }
            case "done": {
                LinearLayout row = ui.row();
                row.addView(ui.tile("check", -1, 12, ui.accent, ui.onAccent), ui.lp(20, 20, 0, 0, 8, 0));
                row.addView(ui.text(r.text, 14, ui.accent, Ui.MEDIUM), ui.flex(1));
                b.addView(row, ui.lp(-1, -2, 0, 0, 0, 12));
                Button close = button("닫기", false); close.setOnClickListener(v -> dismissIncoming());
                b.addView(close, ui.lp(-1, 48));
                break;
            }
            default: {
                b.addView(ui.text(r.text, 13, ui.danger, Ui.REGULAR), ui.lp(-1, -2, 0, 0, 0, 12));
                Button close = button("닫기", false); close.setOnClickListener(v -> dismissIncoming());
                b.addView(close, ui.lp(-1, 48));
                break;
            }
        }
    }
    void accept() {
        Incoming r = incoming;
        if (r == null || !r.phase.equals("asking")) return;
        if (r.guest) {
            a.server.answerGuest(r.token, true);
            r.phase = "receiving"; r.text = "받는 중 · 0/" + r.count;
        } else {
            r.phase = "receiving"; r.text = "받을 파일을 확인하는 중…";
            final NearbyRadio.Offer offer = r.offer;
            work.execute(() -> download(offer, r));
        }
        renderIncoming();
    }
    void decline() {
        Incoming r = incoming;
        if (r == null) return;
        if (r.phase.equals("asking")) {
            if (r.guest) a.server.answerGuest(r.token, false);
            else {
                final String url = r.offer.url + "/decline";
                work.execute(() -> {
                    try {
                        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
                        c.setInstanceFollowRedirects(false); c.setConnectTimeout(15000); c.setReadTimeout(20000); c.setUseCaches(false);
                        c.setRequestMethod("POST"); c.setDoOutput(true); c.setFixedLengthStreamingMode(0);
                        c.getOutputStream().close(); c.getResponseCode(); c.disconnect();
                    } catch (Exception ignored) {}
                });
            }
        }
        dismissIncoming();
    }
    /** 받는 중 창을 닫기만 합니다(받기는 계속). */
    void dismissIncoming() {
        incoming = null;
        if (incomingDialog != null) { try { incomingDialog.dismiss(); } catch (Exception ignored) {} }
        incomingDialog = null; incomingBody = null;
    }
    void setPhase(Incoming r, String phase, String text) {
        a.runOnUiThread(() -> {
            r.phase = phase; r.text = text;
            if (incoming == r) renderIncoming();
            if (phase.equals("done")) a.handler.postDelayed(() -> { if (incoming == r) dismissIncoming(); }, 2500);
        });
    }
    void followGuest() {
        Incoming r = incoming;
        Protocol.Ticket t = a.server == null ? null : a.server.ticket(r.token);
        String phase = r.phase, text = r.text;
        if (t == null) { phase = "failed"; text = "전송이 중단되었습니다."; }
        else if (t.state.equals("done")) { phase = "done"; text = t.files.size() + "개를 받았습니다 · " + a.folderLabel(); }
        else if (t.state.equals("declined") || t.state.equals("expired")) { phase = "failed"; text = "전송이 중단되었습니다. 받은 파일은 그대로 남습니다."; }
        else text = "받는 중 · " + t.completed() + "/" + t.files.size();
        if (!phase.equals(r.phase) || !text.equals(r.text)) {
            boolean done = phase.equals("done");
            r.phase = phase; r.text = text;
            if (done) a.handler.postDelayed(() -> { if (incoming == r) dismissIncoming(); }, 2500);
        }
    }

    /** [받기]: 보낸 쪽 서버의 게스트 주소에서 info → file/{i}를 차례로 받아 평소 수신처럼 저장합니다. (작업 스레드) */
    void download(NearbyRadio.Offer offer, Incoming r) {
        try {
            JSONObject info;
            try {
                HttpURLConnection c = open(offer.url + "/info");
                try {
                    if (c.getResponseCode() != 200) throw new IOException();
                    info = new JSONObject(Protocol.strictUTF8(read(c.getInputStream(), 2 * 1024 * 1024)));
                } finally { c.disconnect(); }
            } catch (Exception e) { throw new IOException("보낸 기기에 연결하지 못했습니다. 보낸 사람의 아나가 열려 있는지 확인하세요."); }
            String state = info.optString("state", "");
            if (!"send".equals(info.optString("kind")) || state.equals("done") || state.equals("declined") || state.equals("expired")) throw new IOException("이미 끝난 전송입니다.");
            if (!info.isNull("code") && !info.optString("code", "").equals(offer.code)) throw new IOException("확인 숫자가 맞지 않아 받지 않았습니다.");
            JSONArray list = info.optJSONArray("files");
            List<Object[]> files = new ArrayList<>();
            if (list != null) for (int i = 0; i < list.length(); i++) {
                JSONObject item = list.optJSONObject(i);
                if (item == null) continue;
                try { files.add(new Object[]{item.getInt("i"), Protocol.safeName(item.getString("name")), item.getLong("bytes")}); } catch (Exception ignored) {}
            }
            if (files.isEmpty()) throw new IOException("받을 파일이 없습니다.");
            for (int k = 0; k < files.size(); k++) {
                int index = (Integer) files.get(k)[0]; String name = (String) files.get(k)[1]; long bytes = (Long) files.get(k)[2];
                setPhase(r, "receiving", "받는 중 · " + name + " (" + (k + 1) + "/" + files.size() + ")");
                File temp = File.createTempFile("nearby-", ".part", a.getCacheDir());
                try {
                    HttpURLConnection c = open(offer.url + "/file/" + index);
                    try {
                        if (c.getResponseCode() != 200) throw new IOException(name + "을(를) 받지 못했습니다.");
                        long length = c.getContentLengthLong();
                        if (length >= 0 && length != bytes) throw new IOException(name + "의 크기가 다릅니다.");
                        try (InputStream in = c.getInputStream(); OutputStream out = new FileOutputStream(temp)) {
                            byte[] buffer = new byte[65536]; long total = 0; int n;
                            while ((n = in.read(buffer)) >= 0) { total += n; if (total > Protocol.MAX) throw new IOException("파일이 너무 큽니다."); out.write(buffer, 0, n); }
                            if (total != bytes) throw new IOException(name + "을(를) 끝까지 받지 못했습니다.");
                        }
                    } finally { c.disconnect(); }
                    a.export(temp, name, offer.name);
                } finally { temp.delete(); }
            }
            setPhase(r, "done", files.size() + "개를 받았습니다 · " + a.folderLabel());
        } catch (Exception e) {
            setPhase(r, "failed", e.getMessage() == null ? "받지 못했습니다." : e.getMessage());
        }
    }
    static HttpURLConnection open(String url) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setInstanceFollowRedirects(false); c.setConnectTimeout(15000); c.setReadTimeout(60000); c.setUseCaches(false);
        return c;
    }
    static byte[] read(InputStream in, int max) throws IOException {
        try (InputStream s = in) {
            ByteArrayOutputStream b = new ByteArrayOutputStream(); byte[] buffer = new byte[8192]; int n;
            while ((n = s.read(buffer)) >= 0) { if (b.size() + n > max) throw new IOException("응답이 너무 큽니다."); b.write(buffer, 0, n); }
            return b.toByteArray();
        }
    }

    // =====================================================================================
    // 보내는 쪽 창 (NearbySheet)
    // =====================================================================================

    static final class Outgoing {
        String deviceName, code, token, summary;
        /** preparing · waiting · sending · done · declined · failed */
        String phase = "preparing", error = "";
        int done, total; long started;
        List<Uri> files;
    }
    Outgoing outgoing;
    Dialog outgoingDialog;
    LinearLayout outgoingBody;
    String outgoingPrint = "";

    /** 근처 기기로 보내기: 내 서버에 1회용 티켓(kind=send) → 상대 inbox에 제안 쓰기 → 수락 대기 */
    void send(String deviceId, List<Uri> uris) {
        NearbyRadio.Device device = device(deviceId);
        if (device == null) { a.status("근처에서 그 기기를 찾을 수 없습니다. 상대 아나가 열려 있는지 확인하세요."); return; }
        if (uris.isEmpty()) { a.status("보낼 파일을 선택하세요."); return; }
        if (!a.guestReady()) { a.status("서버 설정이 필요합니다. 서버에 연결된 뒤 다시 보내 주세요."); return; }
        if (outgoing != null) closeOutgoing();
        final Outgoing o = new Outgoing();
        o.deviceName = device.name; o.code = code(); o.files = new ArrayList<>(uris);
        o.summary = summary(pendingNames(uris));
        outgoing = o;
        outgoingBody = a.ui.column();
        outgoingPrint = "";
        outgoingDialog = sheet(outgoingBody, false);
        outgoingDialog.setOnCancelListener(d -> closeOutgoing());
        renderOutgoing();
        final String name = deviceName();
        work.execute(() -> {
            try {
                List<String> names = new ArrayList<>();
                List<File> staged = stage(o.files, names);
                long total = 0; for (File f : staged) total += f.length();
                Protocol.Ticket ticket = a.server.createTicket("send", staged, names, o.code);
                String url = a.guestURL(ticket.token);
                byte[] data = new NearbyRadio.Offer(name, "Android", o.code, staged.size(), total, summary(names), url).json();
                a.runOnUiThread(() -> {
                    if (outgoing != o) { a.server.cancelTicket(ticket.token, "expired"); return; }
                    o.token = ticket.token;
                    radio.send(data, deviceId, error -> a.runOnUiThread(() -> {
                        if (outgoing != o) return;
                        if (error != null) { a.server.cancelTicket(ticket.token, "expired"); o.phase = "failed"; o.error = error; }
                        else { o.phase = "waiting"; o.started = System.currentTimeMillis(); }
                        renderOutgoing();
                    }));
                });
            } catch (Exception e) {
                a.runOnUiThread(() -> { if (outgoing != o) return; o.phase = "failed"; o.error = e.getMessage() == null ? "보내지 못했습니다." : e.getMessage(); renderOutgoing(); });
            }
        });
    }
    void followOutgoing() {
        Outgoing o = outgoing;
        if (o == null || o.token == null || !(o.phase.equals("waiting") || o.phase.equals("sending"))) return;
        Protocol.Ticket t = a.server.ticket(o.token);
        String state = t == null ? "missing" : t.state;
        switch (state) {
            case "transferring": o.phase = "sending"; o.done = t.completed(); o.total = t.files.size(); break;
            case "done":
                o.phase = "done";
                a.pending.removeAll(o.files); a.renderPending();
                break;
            case "declined": o.phase = "declined"; break;
            case "expired": case "missing":
                if (o.phase.equals("waiting")) o.phase = "declined"; else { o.phase = "failed"; o.error = "전송이 중단되었습니다."; }
                break;
            default:
                // 30초 안에 받지 않으면 자동으로 취소
                if (o.phase.equals("waiting") && System.currentTimeMillis() - o.started > 30_000) { a.server.cancelTicket(o.token, "expired"); o.phase = "declined"; }
        }
    }
    /** 보내기 취소 · 창 닫기. 아직 받는 중이 아니면 티켓도 지웁니다. */
    void closeOutgoing() {
        Outgoing o = outgoing;
        if (o != null && o.token != null && (o.phase.equals("preparing") || o.phase.equals("waiting"))) a.server.cancelTicket(o.token, "expired");
        outgoing = null;
        if (outgoingDialog != null) { try { outgoingDialog.dismiss(); } catch (Exception ignored) {} }
        outgoingDialog = null; outgoingBody = null;
    }
    void renderOutgoing() {
        Outgoing o = outgoing;
        if (o == null || outgoingBody == null) return;
        String print = o.phase + "/" + o.done + "/" + o.total + "/" + o.error;
        if (print.equals(outgoingPrint)) return;
        outgoingPrint = print;
        Ui ui = a.ui;
        LinearLayout b = outgoingBody;
        b.removeAllViews();
        LinearLayout head = ui.row();
        head.addView(ui.tile("send", 11, 22, ui.accent, ui.onAccent), ui.lp(40, 40, 0, 0, 12, 0));
        LinearLayout titles = ui.column();
        TextView title = ui.text("아나로 보내기", 17, ui.text, Ui.BOLD); title.setAccessibilityHeading(true);
        titles.addView(title);
        titles.addView(Ui.oneLine(ui.text(o.summary, 12, ui.faint, Ui.REGULAR)));
        head.addView(titles, ui.flex(1));
        b.addView(head, ui.lp(-1, -2, 0, 0, 0, 14));
        LinearLayout box = ui.column();
        box.setGravity(Gravity.CENTER_HORIZONTAL);
        switch (o.phase) {
            case "preparing": {
                box.addView(avatar(o.deviceName, 64, false), ui.lp(64, 64, 0, 0, 0, 10));
                ProgressBar spin = new ProgressBar(a);
                spin.setIndeterminateTintList(android.content.res.ColorStateList.valueOf(near()));
                box.addView(spin, ui.lp(28, 28, 0, 0, 0, 10));
                box.addView(center(ui.text(o.deviceName + "에 알리는 중…", 17, ui.text, Ui.BOLD)), ui.lp(-1, -2, 0, 0, 0, 4));
                box.addView(center(ui.text("파일을 준비하고 근처 기기에 보내기 요청을 전하는 중입니다", 13, ui.muted, Ui.REGULAR)), ui.lp(-1, -2));
                box.addView(cancel("보내기 취소"), ui.lp(-1, 48, 0, 16, 0, 0));
                break;
            }
            case "waiting": {
                String trimmed = o.deviceName.trim();
                TextView letter = ui.text(trimmed.isEmpty() ? "?" : new String(Character.toChars(trimmed.codePointAt(0))).toUpperCase(Locale.ROOT), 24, near(), Ui.BOLD);
                letter.setGravity(Gravity.CENTER); letter.setBackground(ui.oval(soft()));
                letter.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
                box.addView(letter, ui.lp(64, 64, 0, 0, 0, 10));
                box.addView(center(ui.text(o.deviceName + "에서 수락을 기다리는 중", 17, ui.text, Ui.BOLD)), ui.lp(-1, -2, 0, 0, 0, 4));
                box.addView(center(ui.text("상대 화면에 같은 확인 숫자가 보이는지 확인해 달라고 하세요", 13, ui.muted, Ui.REGULAR)), ui.lp(-1, -2, 0, 0, 0, 12));
                box.addView(digits(o.code, true), ui.lp(-2, -2, 0, 0, 0, 12));
                box.addView(center(ui.text("30초 안에 받지 않으면 자동으로 취소됩니다", 12, ui.faint, Ui.REGULAR)), ui.lp(-1, -2));
                box.addView(cancel("보내기 취소"), ui.lp(-1, 48, 0, 16, 0, 0));
                break;
            }
            case "sending": {
                box.addView(avatar(o.deviceName, 64, true), ui.lp(64, 64, 0, 0, 0, 10));
                box.addView(center(ui.text(o.deviceName + "에서 받는 중", 17, ui.text, Ui.BOLD)), ui.lp(-1, -2, 0, 0, 0, 10));
                ProgressBar bar = new ProgressBar(a, null, android.R.attr.progressBarStyleHorizontal);
                bar.setMax(Math.max(o.total, 1)); bar.setProgress(o.done);
                bar.setProgressTintList(android.content.res.ColorStateList.valueOf(near()));
                box.addView(bar, ui.lp(-1, -2, 0, 0, 0, 8));
                box.addView(center(ui.text(o.done + "/" + o.total + "개 보냄 · 끝날 때까지 아나를 열어 두세요", 12, ui.faint, Ui.REGULAR)), ui.lp(-1, -2));
                box.addView(cancel("닫기"), ui.lp(-1, 48, 0, 16, 0, 0));
                break;
            }
            case "done":
                box.addView(result(true, o.deviceName + "에 보냈습니다", "상대가 모두 받았습니다. 공유 링크는 이제 사용할 수 없습니다."), new LinearLayout.LayoutParams(-1, -2));
                box.addView(cancel("닫기"), ui.lp(-1, 48, 0, 16, 0, 0));
                break;
            case "declined":
                box.addView(result(false, o.deviceName + "에서 받지 않았습니다", "상대가 거절했거나 응답이 없었습니다"), new LinearLayout.LayoutParams(-1, -2));
                box.addView(cancel("닫기"), ui.lp(-1, 48, 0, 16, 0, 0));
                break;
            default:
                box.addView(result(false, "보내지 못했습니다", o.error), new LinearLayout.LayoutParams(-1, -2));
                box.addView(cancel("닫기"), ui.lp(-1, 48, 0, 16, 0, 0));
                break;
        }
        b.addView(box, new LinearLayout.LayoutParams(-1, -2));
    }
    TextView center(TextView t) { t.setGravity(Gravity.CENTER); return t; }
    Button cancel(String label) { Button c = button(label, false); c.setOnClickListener(v -> closeOutgoing()); return c; }

    // =====================================================================================
    // QR로 보내기 / 받기 (QrShow)
    // =====================================================================================

    Dialog qrDialog;
    LinearLayout qrBody;
    String qrMode = "send", qrToken, qrLink, qrMessage, qrPrint = "";
    Bitmap qrBitmap;
    boolean qrWorking, qrReported, qrCopied;
    List<Uri> qrFiles = new ArrayList<>();
    int qrAttempt;

    void showQr() {
        if (qrDialog != null) return;
        qrFiles = new ArrayList<>(a.pending);
        qrMode = qrFiles.isEmpty() ? "receive" : "send";
        qrBody = a.ui.column();
        qrPrint = "";
        qrDialog = sheet(qrBody, false);
        qrDialog.setOnDismissListener(d -> { releaseQr(); qrDialog = null; qrBody = null; });
        makeQr();
    }
    void makeQr() {
        if (qrWorking) return;
        qrMessage = null; qrBitmap = null; qrLink = null; qrToken = null; qrReported = false;
        final String kind = qrMode;
        final int attempt = ++qrAttempt;
        if (kind.equals("send") && qrFiles.isEmpty()) { qrMessage = "보낼 파일을 먼저 고르세요. ‘파일 보내기’에서 사진이나 파일을 고른 뒤 QR을 누르세요."; renderQr(); return; }
        if (!a.guestReady()) { qrMessage = "서버 설정이 필요합니다.\n옵션 › 서버에서 초대 코드로 연결하고 ‘서버 연결됨’이 보이면 QR로 주고받을 수 있습니다."; renderQr(); return; }
        qrWorking = true;
        renderQr();
        final List<Uri> files = new ArrayList<>(qrFiles);
        final int size = dp(216);
        work.execute(() -> {
            Protocol.Ticket created = null;
            try {
                List<String> names = new ArrayList<>();
                List<File> staged = kind.equals("send") ? stage(files, names) : new ArrayList<>();
                created = a.server.createTicket(kind, staged, names, null);
                String url = a.guestURL(created.token);
                Bitmap bitmap = qrBitmap(url, size);
                final Protocol.Ticket t = created;
                a.runOnUiThread(() -> {
                    qrWorking = false;
                    // 만드는 사이 보내기/받기를 바꿨거나 창을 닫았으면 지우고 지금 고른 쪽으로 다시 만듭니다.
                    if (qrDialog == null || attempt != qrAttempt || !kind.equals(qrMode)) { a.server.cancelTicket(t.token, "expired"); if (qrDialog != null && !kind.equals(qrMode)) makeQr(); return; }
                    qrToken = t.token; qrLink = url; qrBitmap = bitmap; qrPrint = ""; renderQr();
                });
            } catch (Exception e) {
                final Protocol.Ticket t = created;
                a.runOnUiThread(() -> {
                    if (t != null) a.server.cancelTicket(t.token, "expired");
                    qrWorking = false; qrMessage = e.getMessage() == null ? "QR을 만들지 못했습니다." : e.getMessage(); qrPrint = ""; renderQr();
                });
            }
        });
    }
    static Bitmap qrBitmap(String text, int size) {
        boolean[][] m = Qr.encode(text);
        int n = m.length, quiet = 2, scale = Math.max(1, size / (n + quiet * 2)), side = (n + quiet * 2) * scale;
        int[] pixels = new int[side * side];
        java.util.Arrays.fill(pixels, Color.WHITE);
        for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) if (m[y][x])
            for (int dy = 0; dy < scale; dy++) java.util.Arrays.fill(pixels, ((y + quiet) * scale + dy) * side + (x + quiet) * scale, ((y + quiet) * scale + dy) * side + (x + quiet + 1) * scale, Color.BLACK);
        return Bitmap.createBitmap(pixels, side, side, Bitmap.Config.ARGB_8888);
    }
    /** 아직 아무도 쓰지 않은 링크는 창을 닫거나 바꿀 때 지웁니다. 받는 중·확인 대기 중이면 그대로 둡니다. */
    void releaseQr() {
        if (qrToken != null && a.server != null) { Protocol.Ticket t = a.server.ticket(qrToken); if (t != null && t.state.equals("ready")) a.server.cancelTicket(qrToken, "expired"); }
        qrToken = null; qrLink = null; qrBitmap = null; qrAttempt++;
    }
    void renderQr() {
        if (qrBody == null) return;
        Protocol.Ticket t = qrToken == null || a.server == null ? null : a.server.ticket(qrToken);
        boolean send = qrMode.equals("send");
        if (t != null && t.state.equals("done") && send && !qrReported) { qrReported = true; a.pending.removeAll(qrFiles); a.renderPending(); }
        long left = t == null ? 0 : t.expires - System.currentTimeMillis();
        String print = qrMode + "/" + qrWorking + "/" + qrMessage + "/" + (qrBitmap != null) + "/" + (t == null ? "-" : t.state + t.completed() + "/" + t.files.size() + "/" + clock(left)) + "/" + qrCopied;
        if (print.equals(qrPrint)) return;
        qrPrint = print;
        Ui ui = a.ui;
        LinearLayout b = qrBody;
        b.removeAllViews();
        LinearLayout head = ui.row();
        head.addView(ui.tile("qr", 11, 20, ui.accent, ui.onAccent), ui.lp(40, 40, 0, 0, 12, 0));
        LinearLayout titles = ui.column();
        TextView title = ui.text(send ? "QR로 보내기" : "QR로 받기", 17, ui.text, Ui.BOLD); title.setAccessibilityHeading(true);
        titles.addView(title);
        titles.addView(Ui.oneLine(ui.text(send ? (qrFiles.isEmpty() ? "보낼 파일이 없습니다" : summary(pendingNames(qrFiles))) : "상대가 이 기기로 파일을 올릴 수 있습니다", 12, ui.faint, Ui.REGULAR)));
        head.addView(titles, ui.flex(1));
        b.addView(head, ui.lp(-1, -2, 0, 0, 0, 14));
        // 보내기 / 받기
        LinearLayout group = ui.row();
        group.setPadding(dp(3), dp(3), dp(3), dp(3));
        group.setBackground(ui.round(ui.subtle, 10, ui.border, 1));
        String[] modes = {"send", "receive"}, labels = {"보내기", "받기"};
        for (int i = 0; i < 2; i++) {
            final String value = modes[i];
            boolean on = value.equals(qrMode);
            TextView seg = ui.text(labels[i], 13, on ? ui.text : ui.muted, on ? Ui.MEDIUM : Ui.REGULAR);
            seg.setGravity(Gravity.CENTER);
            seg.setBackground(on ? ui.round(ui.surface, 8, ui.border, 1) : ui.pressable(null, 8));
            seg.setClickable(!qrWorking); seg.setFocusable(true); seg.setSelected(on);
            seg.setContentDescription("QR로 " + labels[i] + (on ? ", 선택됨" : ""));
            seg.setOnClickListener(v -> { if (qrWorking || qrMode.equals(value)) return; releaseQr(); qrMode = value; makeQr(); });
            group.addView(seg, new LinearLayout.LayoutParams(0, dp(34), 1));
        }
        b.addView(group, ui.lp(-1, -2, 0, 0, 0, 14));
        LinearLayout content = ui.column();
        content.setGravity(Gravity.CENTER_HORIZONTAL);
        if (qrMessage != null) {
            content.setPadding(0, dp(20), 0, dp(20));
            content.addView(ui.tile("close_bold", -1, 16, ui.subtle, ui.muted), ui.lp(44, 44, 0, 0, 0, 10));
            content.addView(center(ui.text(qrMessage, 14, ui.text, Ui.REGULAR)), ui.lp(-1, -2));
            if (!(send && qrFiles.isEmpty())) {
                Button retry = ui.soft("다시 시도"); retry.setPadding(dp(16), 0, dp(16), 0);
                retry.setOnClickListener(v -> { releaseQr(); makeQr(); });
                content.addView(retry, ui.lp(-2, 40, 0, 12, 0, 0));
            }
        } else if (t != null && t.finished()) {
            content.setPadding(0, dp(16), 0, dp(16));
            boolean ok = t.state.equals("done");
            content.addView(result(ok, ok ? (send ? "보냈습니다" : "받았습니다") : (t.state.equals("declined") ? "받지 않았습니다" : "링크가 만료되었습니다"),
                    ok ? (send ? "상대가 모두 받았습니다. 링크는 이제 사용할 수 없습니다." : "받은 파일은 " + a.folderLabel() + "에 있습니다.") : "새 QR을 만들어 다시 시도하세요."), new LinearLayout.LayoutParams(-1, -2));
            if (!ok) {
                Button again = ui.soft("새 QR 만들기"); again.setPadding(dp(16), 0, dp(16), 0);
                again.setOnClickListener(v -> { releaseQr(); makeQr(); });
                content.addView(again, ui.lp(-2, 40, 0, 12, 0, 0));
            }
        } else if (qrBitmap != null && t != null) {
            FrameLayout frame = new FrameLayout(a);
            frame.setPadding(dp(16), dp(16), dp(16), dp(16));
            frame.setBackground(ui.round(Color.WHITE, 20, ui.border, 1));
            ImageView image = new ImageView(a);
            BitmapDrawable drawable = new BitmapDrawable(a.getResources(), qrBitmap);
            drawable.setFilterBitmap(false);
            image.setImageDrawable(drawable);
            image.setScaleType(ImageView.ScaleType.FIT_CENTER);
            image.setContentDescription("QR 코드");
            frame.addView(image, new FrameLayout.LayoutParams(dp(216), dp(216)));
            content.addView(frame, ui.lp(-2, -2, 0, 0, 0, 14));
            String instruction;
            switch (t.state) {
                case "transferring": instruction = send ? "상대가 받는 중 · " + t.completed() + "/" + t.files.size() + "개" : "받는 중 · " + t.completed() + "/" + t.files.size() + "개"; break;
                case "waiting": instruction = "상대가 보내려고 합니다. 확인 창에서 받기를 누르세요"; break;
                case "accepted": instruction = "상대가 올리기를 시작합니다…"; break;
                default: instruction = send ? "상대에게 카메라로 이 QR을 찍게 하세요" : "상대가 찍으면 올리기 페이지가 열립니다. 받기 전에 확인 창이 뜹니다";
            }
            content.addView(center(ui.text(instruction, 15, ui.text, Ui.MEDIUM)), ui.lp(-1, -2, 0, 0, 0, 10));
            TextView pill = ui.text(clock(left) + " 남음 · 한 번만 쓸 수 있는 링크", 13, ui.accent, Ui.BOLD);
            pill.setFontFeatureSettings("tnum");
            pill.setGravity(Gravity.CENTER);
            pill.setPadding(dp(12), 0, dp(12), 0);
            pill.setBackground(ui.round(ui.accentSoft, 14));
            content.addView(pill, ui.lp(-2, 28));
        } else {
            ProgressBar spin = new ProgressBar(a);
            spin.setIndeterminateTintList(android.content.res.ColorStateList.valueOf(ui.accent));
            LinearLayout.LayoutParams sl = ui.lp(36, 36, 0, 106, 0, 106);
            content.addView(spin, sl);
        }
        b.addView(content, new LinearLayout.LayoutParams(-1, -2));
        LinearLayout buttons = ui.row();
        Button copy = ui.outline(qrCopied ? "복사했습니다" : "링크 복사");
        boolean canCopy = qrLink != null && !(t != null && t.finished());
        copy.setEnabled(canCopy); copy.setAlpha(canCopy ? 1f : 0.45f);
        copy.setOnClickListener(v -> {
            if (qrLink == null) return;
            ClipboardManager cb = (ClipboardManager) a.getSystemService(Context.CLIPBOARD_SERVICE);
            if (cb != null) cb.setPrimaryClip(ClipData.newPlainText("아나", qrLink));
            qrCopied = true; renderQr();
            a.handler.postDelayed(() -> { qrCopied = false; renderQr(); }, 1500);
        });
        buttons.addView(copy, new LinearLayout.LayoutParams(0, dp(48), 1));
        Button close = button("닫기", false);
        close.setOnClickListener(v -> { if (qrDialog != null) qrDialog.dismiss(); });
        LinearLayout.LayoutParams cl = new LinearLayout.LayoutParams(0, dp(48), 1); cl.leftMargin = dp(10);
        buttons.addView(close, cl);
        b.addView(buttons, ui.lp(-1, -2, 0, 16, 0, 0));
        TextView foot = ui.text("상대는 앱 없이 iPhone · Android 카메라로 찍기만 하면 됩니다\n이 기기에서 아나를 열어 두는 동안만 링크가 동작합니다", 12, ui.faint, Ui.REGULAR);
        foot.setGravity(Gravity.CENTER);
        b.addView(foot, ui.lp(-1, -2, 0, 12, 0, 0));
    }

    void close() {
        closed = true;
        a.handler.removeCallbacks(ticker);
        dismissIncoming();
        if (outgoingDialog != null) try { outgoingDialog.dismiss(); } catch (Exception ignored) {}
        if (qrDialog != null) try { qrDialog.dismiss(); } catch (Exception ignored) {}
        radio.close();
        work.shutdownNow();
    }
}
