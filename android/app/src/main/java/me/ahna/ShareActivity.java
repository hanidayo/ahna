package me.ahna;

import android.app.Activity;
import android.app.Dialog;
import android.content.Intent;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.OpenableColumns;
import android.util.Size;
import android.view.Gravity;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * 다른 앱의 [공유] → Ahna.
 * 앱 화면을 띄우지 않고 보낼 기기 시트(휴대폰: 아래에서 올라오는 시트, 태블릿: 가운데 창)만 보여 주고,
 * 같은 시트 안에서 진행 상황과 완료를 보여 준 뒤 닫힙니다 (아이폰 공유 확장과 같은 방식).
 */
public class ShareActivity extends Activity {
    /** 앱 화면에 파일만 넘기고 근처 기기 · QR로 보내게 합니다(MainActivity.handleIntent). */
    static final String EXTRA_NEARBY = "me.ahna.nearby";
    final ExecutorService jobs = Executors.newFixedThreadPool(4);
    final Handler handler = new Handler(Looper.getMainLooper());
    final List<Uri> files = new ArrayList<>();
    final List<Client> clients = new ArrayList<>();
    /** null = 확인 중, TRUE = 연결됨, FALSE = 오프라인 */
    final Map<Client, Boolean> online = new HashMap<>();
    String text;
    SharedPreferences prefs;
    Ui ui;
    boolean tablet;
    Dialog dialog;
    LinearLayout body, thumbs;
    TextView subtitle;
    String countLabel = "";
    volatile boolean sending, closed;
    boolean picking;
    // 보내는 중 화면
    TextView progressDetail, progressPercent;
    View progressFill, progressRest;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        prefs = getSharedPreferences("아나", MODE_PRIVATE);
        ui = new Ui(this);
        tablet = getResources().getConfiguration().screenWidthDp >= 600;
        read(getIntent());
        if (files.isEmpty() && (text == null || text.isEmpty())) { toastAndFinish("보낼 내용이 없습니다."); return; }
        try { clients.addAll(Vault.clients(prefs)); } catch (Exception e) { clients.clear(); }
        buildSheet();
        if (clients.isEmpty()) showNoDevices(); else showPicker();
        describe();
        String device = prefs.getString("name", "나의 Android"), own = prefs.getString("identity", null);
        for (final Client c : clients) {
            jobs.execute(() -> {
                boolean ok;
                try { c.refresh(device, own); ok = true; } catch (Exception e) { ok = false; }
                final boolean result = ok;
                runOnUiThread(() -> { if (closed) return; online.put(c, result); if (picking) showPicker(); });
            });
        }
    }

    static String name(Client c) { return c.profile.optString("hostName", "기기"); }
    static String platform(Client c) {
        String p = c.state == null ? "" : c.state.optString("platform", "");
        return p.isEmpty() ? c.profile.optString("platform", "") : p;
    }
    int dp(float v) { return ui.dp(v); }
    /** The share sheet's own "subtle" is a touch darker than the app's in light mode (시안 Share.dc). */
    int sheetSubtle() { return ui.dark ? ui.subtle : 0xffeef1f5; }

    void read(Intent i) {
        if (Intent.ACTION_SEND.equals(i.getAction())) {
            Uri u = i.getParcelableExtra(Intent.EXTRA_STREAM);
            if (u != null) files.add(u);
            else if (i.hasExtra(Intent.EXTRA_TEXT)) { CharSequence t = i.getCharSequenceExtra(Intent.EXTRA_TEXT); text = t == null ? null : t.toString(); }
        } else if (Intent.ACTION_SEND_MULTIPLE.equals(i.getAction())) {
            ArrayList<Uri> uris = i.getParcelableArrayListExtra(Intent.EXTRA_STREAM);
            if (uris != null) for (Uri u : uris) if (u != null) files.add(u);
        }
    }

    // =====================================================================================
    // Sheet
    // =====================================================================================

    void buildSheet() {
        LinearLayout sheet = ui.column();
        if (tablet) {
            sheet.setBackground(ui.round(ui.surface, 24));
            sheet.setPadding(dp(22), dp(22), dp(22), dp(22));
        } else {
            GradientDrawable d = new GradientDrawable();
            d.setColor(ui.surface);
            float r = dp(24);
            d.setCornerRadii(new float[]{r, r, r, r, 0, 0, 0, 0});
            sheet.setBackground(d);
            sheet.setPadding(dp(16), dp(10), dp(16), dp(20));
            View handle = new View(this);
            handle.setBackground(ui.round(ui.border, 2));
            LinearLayout.LayoutParams hl = ui.lp(36, 4, 0, 0, 0, 14);
            hl.gravity = Gravity.CENTER_HORIZONTAL;
            sheet.addView(handle, hl);
        }

        LinearLayout head = ui.row();
        float icon = tablet ? 44 : 40;
        head.addView(ui.tile("send", tablet ? 12 : 11, 22, ui.accent, ui.onAccent), ui.lp(icon, icon, 0, 0, 12, 0));
        LinearLayout titles = ui.column();
        TextView title = ui.text("아나로 보내기", tablet ? 18 : 17, ui.text, Ui.BOLD);
        title.setAccessibilityHeading(true);
        titles.addView(title);
        subtitle = Ui.oneLine(ui.text(files.isEmpty() ? textLabel() : "파일 " + files.size() + "개", 12, ui.faint, Ui.REGULAR));
        titles.addView(subtitle);
        head.addView(titles, ui.flex(1));
        thumbs = ui.row();
        thumbs.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        head.addView(thumbs, ui.lp(-2, -2, 8, 0, 0, 0));
        sheet.addView(head, ui.lp(-1, -2, 0, 0, 0, tablet ? 16 : 14));

        body = ui.column();
        sheet.addView(body, new LinearLayout.LayoutParams(-1, -2));

        dialog = new Dialog(this, ui.dark ? android.R.style.Theme_Material_Dialog_NoActionBar : android.R.style.Theme_Material_Light_Dialog_NoActionBar);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        dialog.setContentView(sheet);
        dialog.setCanceledOnTouchOutside(true);
        dialog.setOnCancelListener(d -> finish());
        Window w = dialog.getWindow();
        if (w != null) {
            w.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            w.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            w.setDimAmount(tablet ? 0.5f : 0.45f);
            if (!tablet) w.setWindowAnimations(android.R.style.Animation_InputMethod);
        }
        dialog.show();
        if (w != null) {
            if (tablet) {
                int width = Math.min(dp(520), getResources().getDisplayMetrics().widthPixels - dp(32));
                w.setLayout(width, WindowManager.LayoutParams.WRAP_CONTENT);
                w.setGravity(Gravity.CENTER);
            } else {
                w.setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.WRAP_CONTENT);
                w.setGravity(Gravity.BOTTOM);
            }
        }
    }

    String textLabel() { return "글자 · " + (text == null ? 0 : text.codePointCount(0, text.length())) + "자"; }

    /** "사진 3장 · 8.4 MB" and up to three small thumbnails, read off the UI thread. */
    void describe() {
        if (files.isEmpty()) { countLabel = "글자"; return; }
        countLabel = "파일 " + files.size() + "개";
        final List<Uri> list = new ArrayList<>(files);
        final int thumbSize = dp(tablet ? 40 : 36);
        jobs.execute(() -> {
            long total = 0; boolean known = true; int images = 0, videos = 0;
            List<Uri> visual = new ArrayList<>();
            for (Uri u : list) {
                String type = null;
                try { type = getContentResolver().getType(u); } catch (Exception ignored) {}
                if (type != null && type.startsWith("image/")) { images++; visual.add(u); }
                else if (type != null && type.startsWith("video/")) { videos++; visual.add(u); }
                long size = -1;
                try (Cursor cursor = getContentResolver().query(u, new String[]{OpenableColumns.SIZE}, null, null, null)) {
                    if (cursor != null && cursor.moveToFirst() && !cursor.isNull(0)) size = cursor.getLong(0);
                } catch (Exception ignored) {}
                if (size < 0) known = false; else total += size;
            }
            int n = list.size();
            final String count = images == n ? "사진 " + n + "장" : videos == n ? "동영상 " + n + "개" : "파일 " + n + "개";
            final String line = known ? count + " · " + Ui.size(total) : count;
            runOnUiThread(() -> { if (closed) return; countLabel = count; if (subtitle != null) subtitle.setText(line); });
            for (int i = 0; i < visual.size() && i < 3; i++) {
                Bitmap b = null;
                try { b = getContentResolver().loadThumbnail(visual.get(i), new Size(thumbSize * 2, thumbSize * 2), null); } catch (Exception ignored) {}
                if (b == null) continue;
                final Bitmap bitmap = b;
                runOnUiThread(() -> { if (!closed) addThumb(bitmap); });
            }
        });
    }

    void addThumb(Bitmap bitmap) {
        float size = tablet ? 40 : 36, radius = tablet ? 9 : 8;
        ImageView v = new ImageView(this);
        v.setImageBitmap(bitmap);
        v.setScaleType(ImageView.ScaleType.CENTER_CROP);
        v.setPadding(dp(2), dp(2), dp(2), dp(2));
        v.setBackground(ui.round(ui.surface, radius));
        v.setCropToPadding(true);
        ui.roundOutline(v, radius);
        v.setClipToOutline(true);
        v.setElevation(0);
        boolean first = thumbs.getChildCount() == 0;
        thumbs.addView(v, ui.lp(size, size, first ? 0 : -(tablet ? 16 : 14), 0, 0, 0));
    }

    // ---------- 기기 고르기 ----------

    void showPicker() {
        picking = true;
        body.removeAllViews();
        body.addView(ui.text("보낼 기기", 13, ui.muted, Ui.MEDIUM), ui.lp(-1, -2, 0, 0, 0, tablet ? 8 : 6));
        if (tablet) {
            LinearLayout line = null;
            for (int i = 0; i < clients.size(); i++) {
                if (i % 3 == 0) {
                    line = ui.row();
                    line.setGravity(Gravity.TOP);
                    body.addView(line, ui.lp(-1, -2, 0, i == 0 ? 0 : 10, 0, 0));
                }
                LinearLayout.LayoutParams cell = ui.flex(1);
                if (i % 3 != 0) cell.leftMargin = dp(10);
                line.addView(deviceCard(clients.get(i)), cell);
            }
            int rest = clients.size() % 3;
            if (rest != 0 && line != null) for (int i = rest; i < 3; i++) {
                LinearLayout.LayoutParams cell = ui.flex(1); cell.leftMargin = dp(10);
                line.addView(new View(this), cell);
            }
        } else {
            for (int i = 0; i < clients.size(); i++) body.addView(deviceRow(clients.get(i)), ui.lp(-1, -2, 0, i == 0 ? 0 : 8, 0, 0));
        }
        if (!files.isEmpty()) body.addView(nearbyRow(), ui.lp(-1, -2, 0, tablet ? 10 : 8, 0, 0));
        Button cancel = ui.button("취소", sheetSubtle(), ui.text, 0, 12, 14, Ui.MEDIUM);
        cancel.setOnClickListener(v -> finish());
        if (tablet) {
            cancel.setPadding(dp(22), 0, dp(22), 0);
            LinearLayout.LayoutParams lp = ui.lp(-2, 44, 0, 16, 0, 0);
            lp.gravity = Gravity.END;
            body.addView(cancel, lp);
        } else {
            body.addView(cancel, ui.lp(-1, 48, 0, 14, 0, 0));
        }
    }

    View deviceRow(Client c) {
        Boolean state = online.get(c);
        boolean off = Boolean.FALSE.equals(state), ok = Boolean.TRUE.equals(state);
        LinearLayout row = ui.row();
        row.setMinimumHeight(dp(64));
        row.setPadding(dp(14), dp(8), dp(14), dp(8));
        row.setBackground(off ? ui.dashed(sheetSubtle(), 14, ui.border, 1) : ui.pressable(ui.round(ui.surface, 14, ui.border, 1), 14));
        row.addView(ui.tile(Ui.deviceIcon(platform(c)), 10, 20, off ? ui.surface : ui.accentSoft, off ? ui.faint : ui.accent), ui.lp(40, 40, 0, 0, 12, 0));
        row.addView(Ui.oneLine(ui.text(name(c), 14, off ? ui.muted : ui.text, Ui.MEDIUM)), ui.flex(1));
        LinearLayout badge = ui.row();
        badge.setPadding(dp(9), 0, dp(9), 0);
        badge.setBackground(ok ? ui.round(ui.accentSoft, 13) : ui.round(Color.TRANSPARENT, 13, ui.border, 1));
        badge.addView(ui.dot(ok), ui.lp(7, 7, 0, 0, 5, 0));
        badge.addView(ui.text(ok ? "연결됨" : off ? "오프라인" : "확인 중…", 12, ok ? ui.on : ui.faint, ok ? Ui.MEDIUM : Ui.REGULAR));
        row.addView(badge, ui.lp(-2, 26, 10, 0, 0, 0));
        bindDevice(row, c, off, ok);
        return row;
    }

    View deviceCard(Client c) {
        Boolean state = online.get(c);
        boolean off = Boolean.FALSE.equals(state), ok = Boolean.TRUE.equals(state);
        LinearLayout card = ui.column();
        card.setGravity(Gravity.CENTER_HORIZONTAL);
        card.setPadding(dp(8), dp(16), dp(8), dp(16));
        card.setBackground(off ? ui.dashed(sheetSubtle(), 16, ui.border, 1) : ui.pressable(ui.round(ui.surface, 16, ui.border, 1), 16));
        card.addView(ui.tile(Ui.deviceIcon(platform(c)), 14, 24, off ? ui.surface : ui.accentSoft, off ? ui.faint : ui.accent), ui.lp(52, 52, 0, 0, 0, 8));
        TextView n = Ui.oneLine(ui.text(name(c), 14, off ? ui.muted : ui.text, Ui.MEDIUM));
        n.setGravity(Gravity.CENTER);
        card.addView(n, ui.lp(-1, -2, 0, 0, 0, 8));
        LinearLayout status = ui.row();
        status.addView(ui.dot(ok), ui.lp(7, 7, 0, 0, 5, 0));
        status.addView(ui.text(ok ? "연결됨" : off ? "오프라인" : "확인 중…", 12, ok ? ui.on : ui.faint, ok ? Ui.MEDIUM : Ui.REGULAR));
        card.addView(status);
        bindDevice(card, c, off, ok);
        return card;
    }

    void bindDevice(View v, Client c, boolean off, boolean ok) {
        v.setContentDescription(name(c) + ", " + (ok ? "연결됨" : off ? "오프라인" : "확인 중"));
        if (off) { v.setEnabled(false); v.setClickable(false); return; }
        v.setClickable(true); v.setFocusable(true);
        v.setOnClickListener(x -> send(c));
    }

    void showNoDevices() {
        picking = false;
        body.removeAllViews();
        TextView message = ui.text("보낼 기기가 없습니다.\nAhna 앱의 옵션에서 받을 기기를 먼저 추가하세요.", 14, ui.muted, Ui.REGULAR);
        body.addView(message, ui.lp(-1, -2, 0, 0, 0, 14));
        if (!files.isEmpty()) body.addView(nearbyRow(), ui.lp(-1, -2, 0, 0, 0, 14));
        LinearLayout buttons = ui.row();
        Button close = ui.button("닫기", sheetSubtle(), ui.text, 0, 12, 14, Ui.MEDIUM);
        close.setOnClickListener(v -> finish());
        Button open = ui.primary("앱 열기");
        open.setOnClickListener(v -> { startActivity(new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); finish(); });
        buttons.addView(close, new LinearLayout.LayoutParams(0, dp(48), 1));
        LinearLayout.LayoutParams ol = new LinearLayout.LayoutParams(0, dp(48), 1); ol.leftMargin = dp(8);
        buttons.addView(open, ol);
        body.addView(buttons, new LinearLayout.LayoutParams(-1, -2));
    }

    /** 근처 기기(Bluetooth) · QR로 보내기: 이 기기 서버가 파일을 내주므로 앱 화면에서 고릅니다. */
    View nearbyRow() {
        int near = ui.dark ? 0xffa78bfa : 0xff7c3aed, soft = ui.dark ? 0xff2b2140 : 0xfff1ebfe;
        LinearLayout row = ui.row();
        row.setMinimumHeight(dp(64));
        row.setPadding(dp(14), dp(8), dp(14), dp(8));
        row.setBackground(ui.pressable(ui.round(ui.surface, 14, ui.border, 1), 14));
        row.addView(ui.tile("bluetooth", 10, 20, soft, near), ui.lp(40, 40, 0, 0, 12, 0));
        LinearLayout texts = ui.column();
        texts.addView(Ui.oneLine(ui.text("근처 기기 · QR로 보내기", 14, ui.text, Ui.MEDIUM)));
        texts.addView(Ui.oneLine(ui.text("등록하지 않은 사람에게 · 아나 앱에서 고릅니다", 12, ui.faint, Ui.REGULAR)));
        row.addView(texts, ui.flex(1));
        row.addView(ui.icon("chevron", ui.faint), ui.lp(16, 16, 10, 0, 0, 0));
        row.setClickable(true); row.setFocusable(true);
        row.setContentDescription("근처 기기 또는 QR로 보내기, 아나 앱에서 고릅니다");
        row.setOnClickListener(v -> openNearby());
        return row;
    }
    void openNearby() {
        if (files.isEmpty() || sending) return;
        Intent i = new Intent(this, MainActivity.class);
        if (files.size() == 1) { i.setAction(Intent.ACTION_SEND); i.putExtra(Intent.EXTRA_STREAM, files.get(0)); }
        else { i.setAction(Intent.ACTION_SEND_MULTIPLE); i.putParcelableArrayListExtra(Intent.EXTRA_STREAM, new ArrayList<>(files)); }
        i.setType("*/*");
        android.content.ClipData clip = android.content.ClipData.newRawUri("", files.get(0));
        for (int j = 1; j < files.size(); j++) clip.addItem(new android.content.ClipData.Item(files.get(j)));
        i.setClipData(clip);
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
        i.putExtra(EXTRA_NEARBY, true);
        try { startActivity(i); } catch (Exception e) { toastAndFinish("앱을 열지 못했습니다."); return; }
        finish();
    }

    // ---------- 보내는 중 / 완료 / 오류 ----------

    void showSending(Client c) {
        picking = false;
        body.removeAllViews();
        LinearLayout box = ui.row();
        box.setPadding(dp(14), dp(14), dp(14), dp(14));
        box.setBackground(ui.round(ui.surface, 14, ui.border, 1));
        box.addView(ui.tile(Ui.deviceIcon(platform(c)), 10, 20, ui.accentSoft, ui.accent), ui.lp(40, 40, 0, 0, 12, 0));
        LinearLayout texts = ui.column();
        texts.addView(Ui.oneLine(ui.text(Ui.toward(name(c)) + " 보내는 중", 14, ui.text, Ui.MEDIUM)));
        progressDetail = Ui.oneLine(ui.text("준비 중…", 12, ui.faint, Ui.REGULAR));
        texts.addView(progressDetail);
        box.addView(texts, ui.flex(1));
        progressPercent = ui.text("0%", 15, ui.accent, Ui.BOLD);
        progressPercent.setFontFeatureSettings("tnum");
        box.addView(progressPercent, ui.lp(-2, -2, 10, 0, 0, 0));
        body.addView(box, ui.lp(-1, -2, 0, tablet ? 0 : 8, 0, 0));
        LinearLayout track = ui.row();
        track.setBackground(ui.round(sheetSubtle(), 3));
        track.setClipToOutline(true);
        progressFill = new View(this);
        progressFill.setBackground(ui.round(ui.accent, 3));
        progressRest = new View(this);
        track.addView(progressFill, new LinearLayout.LayoutParams(0, -1, 0f));
        track.addView(progressRest, new LinearLayout.LayoutParams(0, -1, 1f));
        track.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        body.addView(track, ui.lp(-1, 6, 0, 10, 0, 0));
        body.addView(ui.text("이 창을 닫지 마세요. 다 보내면 자동으로 닫힙니다.", 12, ui.faint, Ui.REGULAR), ui.lp(-1, -2, 0, 10, 0, tablet ? 0 : 4));
    }

    void progress(String detail, float fraction) {
        runOnUiThread(() -> {
            if (closed || progressFill == null) return;
            float f = Math.max(0f, Math.min(1f, fraction));
            progressDetail.setText(detail);
            String percent = Math.round(f * 100) + "%";
            progressPercent.setText(percent);
            progressPercent.setContentDescription(percent + " 보냄");
            ((LinearLayout.LayoutParams) progressFill.getLayoutParams()).weight = f;
            ((LinearLayout.LayoutParams) progressRest.getLayoutParams()).weight = 1f - f;
            progressFill.requestLayout();
            progressRest.requestLayout();
        });
    }

    void showDone(Client c) {
        if (closed) return;
        picking = false;
        body.removeAllViews();
        LinearLayout box = ui.column();
        box.setGravity(Gravity.CENTER_HORIZONTAL);
        box.setPadding(0, dp(tablet ? 14 : 18), 0, dp(tablet ? 6 : 8));
        box.addView(ui.tile("check", -1, 28, ui.accentSoft, ui.accent), ui.lp(56, 56, 0, 0, 0, 8));
        TextView title = ui.text(Ui.toward(name(c)) + " 보냈습니다", 17, ui.text, Ui.BOLD);
        title.setGravity(Gravity.CENTER);
        box.addView(title, ui.lp(-2, -2, 0, 0, 0, 8));
        TextView sub = ui.text(countLabel + " · 잠시 후 자동으로 닫힙니다", 12, ui.faint, Ui.REGULAR);
        sub.setGravity(Gravity.CENTER);
        box.addView(sub);
        body.addView(box, new LinearLayout.LayoutParams(-1, -2));
        body.announceForAccessibility(Ui.toward(name(c)) + " 보냈습니다");
        handler.postDelayed(this::finish, 1200);
    }

    void showError(String message) {
        if (closed) return;
        picking = false;
        sending = false;
        dialog.setCancelable(true);
        body.removeAllViews();
        LinearLayout box = ui.column();
        box.setGravity(Gravity.CENTER_HORIZONTAL);
        box.setPadding(0, dp(10), 0, 0);
        box.addView(ui.tile("close_bold", -1, 22, ui.dangerSoft, ui.danger), ui.lp(56, 56, 0, 0, 0, 8));
        TextView title = ui.text("보내지 못했습니다", 17, ui.text, Ui.BOLD);
        title.setGravity(Gravity.CENTER);
        box.addView(title, ui.lp(-2, -2, 0, 0, 0, 6));
        TextView detail = ui.text(message, 13, ui.muted, Ui.REGULAR);
        detail.setGravity(Gravity.CENTER);
        box.addView(detail, ui.lp(-1, -2));
        body.addView(box, new LinearLayout.LayoutParams(-1, -2));
        Button ok = ui.primary("확인");
        ok.setOnClickListener(v -> finish());
        if (tablet) {
            ok.setPadding(dp(22), 0, dp(22), 0);
            LinearLayout.LayoutParams lp = ui.lp(-2, 44, 0, 16, 0, 0);
            lp.gravity = Gravity.END;
            body.addView(ok, lp);
        } else {
            body.addView(ok, ui.lp(-1, 48, 0, 16, 0, 0));
        }
        body.announceForAccessibility("보내지 못했습니다. " + message);
    }

    // ---------- 전송 (기존 로직 그대로) ----------

    void send(Client c) {
        if (sending) return;
        sending = true;
        dialog.setCancelable(false);
        showSending(c);
        jobs.execute(() -> {
            try {
                if (files.isEmpty()) {
                    progress(textLabel(), 0f);
                    c.sendClipboard(text);
                    progress(textLabel(), 1f);
                    runOnUiThread(() -> showDone(c));
                    return;
                }
                int total = files.size();
                long[] sizes = new long[total];
                long all = 0; boolean known = true;
                for (int i = 0; i < total; i++) {
                    sizes[i] = -1;
                    try (Cursor cursor = getContentResolver().query(files.get(i), new String[]{OpenableColumns.SIZE}, null, null, null)) {
                        if (cursor != null && cursor.moveToFirst() && !cursor.isNull(0)) sizes[i] = cursor.getLong(0);
                    } catch (Exception ignored) {}
                    if (sizes[i] < 0) known = false; else all += sizes[i];
                }
                long doneBytes = 0;
                for (int i = 0; i < total; i++) {
                    Uri uri = files.get(i);
                    String display = "파일";
                    try (Cursor cursor = getContentResolver().query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
                        if (cursor != null && cursor.moveToFirst() && cursor.getString(0) != null) display = cursor.getString(0);
                    }
                    display = Protocol.safeName(display);
                    String label = (i + 1) + "/" + total + " · " + display;
                    progress(label, fraction(known, all, doneBytes, i, total));
                    File staged = File.createTempFile("send-", ".part", getCacheDir());
                    try {
                        long copied = 0;
                        try (InputStream in = getContentResolver().openInputStream(uri); OutputStream out = new FileOutputStream(staged)) {
                            if (in == null) throw new IOException("파일을 열 수 없습니다.");
                            byte[] buffer = new byte[65536]; int n;
                            while ((n = in.read(buffer)) >= 0) { copied += n; if (copied > Protocol.MAX) throw new IOException("파일 한 개는 최대 4 GiB입니다."); out.write(buffer, 0, n); }
                        }
                        c.send(staged, display);
                        doneBytes += known ? sizes[i] : copied;
                    } finally { staged.delete(); }
                    progress(label, fraction(known, all, doneBytes, i + 1, total));
                }
                runOnUiThread(() -> showDone(c));
            } catch (Exception e) {
                String message = e.getMessage() == null ? "보내지 못했습니다. 상대 기기와 서버 연결을 확인하세요." : e.getMessage();
                runOnUiThread(() -> showError(message));
            }
        });
    }

    /** Byte-based when every size is known, otherwise by file count. Client.send has no byte callback, so it moves per file. */
    static float fraction(boolean known, long all, long doneBytes, int doneFiles, int total) {
        if (known && all > 0) return (float) ((double) doneBytes / all);
        return total == 0 ? 0f : (float) doneFiles / total;
    }

    void toastAndFinish(String message) {
        Toast.makeText(getApplicationContext(), "아나 · " + message, Toast.LENGTH_SHORT).show();
        finish();
    }

    @Override protected void onDestroy() {
        closed = true;
        handler.removeCallbacksAndMessages(null);
        if (dialog != null) dialog.dismiss();
        jobs.shutdownNow();
        super.onDestroy();
    }
}
