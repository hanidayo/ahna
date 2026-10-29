package me.ahna;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.ContentValues;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.res.Configuration;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.provider.DocumentsContract;
import android.provider.MediaStore;
import android.provider.OpenableColumns;
import android.text.InputFilter;
import android.text.InputType;
import android.text.SpannableStringBuilder;
import android.text.Spanned;
import android.text.style.StyleSpan;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class MainActivity extends Activity {
    static final String DEFAULT_NAS = Brand.SERVER;

    final ExecutorService jobs = Executors.newFixedThreadPool(4);
    final Handler handler = new Handler(Looper.getMainLooper());
    final List<Client> clients = new CopyOnWriteArrayList<>();
    final List<Target> targets = new ArrayList<>();
    final List<Uri> pending = new ArrayList<>();
    final Map<Uri, String[]> pendingMeta = new HashMap<>();
    /** Received-text previews from paired hosts: "<computer>:<id>" → text ("" when it could not be read). */
    final Map<String, String> clipCache = new ConcurrentHashMap<>();
    final Set<String> receiptPending = new HashSet<>();
    Protocol server;
    RelayBridge relay;
    /** 아나 1.2 근처 기기(Bluetooth LE) · QR */
    NearbyUi nearby;
    SharedPreferences prefs;
    Ui ui;
    volatile boolean busy, closed, polling;
    volatile String relayText;
    String targetKey = "", version = "";
    int activeTab = 0;
    /** 태블릿 머리글·크기(2열·3열 공통). columns: 1 = 휴대폰 배치, 2 = 태블릿 세로(2열), 3 = 태블릿 가로(3열). */
    boolean tablet;
    int columns = 1;

    // views (rebuilt by buildUI)
    FrameLayout root;
    View homePage, optionsPage;
    LinearLayout tabBar, targetBox, nearBox, pendingBox, inbox, historyBox, connections;
    LinearLayout[] tabItems;
    Button sendButton;
    EditText draft, pin;
    TextView snack, codeView, deviceLine, nameValue, nasValue, folderValue, updateValue, historyFolder;
    final List<LinearLayout> nasPills = new ArrayList<>();
    final List<View> headers = new ArrayList<>(), bodies = new ArrayList<>();
    String targetPrint = "", connectionPrint = "", inboxPrint = "";
    int insetBottom, imeBottom;

    /**
     * One row per device: a device this app added (connection) merged with that device's pairings to this
     * app's receiver (peerIDs). Sending uses client when set, otherwise this app's queue for hostPeer.
     */
    static final class Target { String id, name, platform, hostPeer; Client client, connection; boolean online; final List<String> peerIDs = new ArrayList<>(); }
    /** Every device for the 연결된 기기 list (targets only shows the ones that can be chosen). */
    final List<Target> linked = new ArrayList<>();

    final Runnable poll = new Runnable() { public void run() {
        if (closed) return;
        if (!busy && !polling) {
            polling = true;
            jobs.execute(() -> {
                try {
                    for (Client c : new ArrayList<>(clients)) {
                        if (closed) break;
                        try { c.refresh(deviceName(), identity()); rememberPlatform(c); receive(c); prefetchClips(c); }
                        catch (Exception e) {
                            c.state = null;
                            // 상대 기기가 이 연결을 해제했고 그 기기가 이 기기에 연결한 쪽이 남아 있으면, 죽은 연결만 조용히 지우고 그쪽으로 주고받습니다.
                            if (c.revoked && hasInbound(c)) clients.remove(c);
                        }
                    }
                    saveClients();
                } catch (Exception e) { status(e.getMessage()); }
                finally { polling = false; runOnUiThread(() -> { if (!closed) { updateTargets(); updateInbox(); } }); }
            });
        }
        handler.postDelayed(this, 3000);
    } };
    final Runnable hideSnack = () -> {
        if (snack == null) return;
        final TextView s = snack;
        s.animate().alpha(0f).setDuration(250).withEndAction(() -> s.setVisibility(View.GONE)).start();
    };
    final SharedPreferences.OnSharedPreferenceChangeListener prefsListener = (p, key) -> {
        if ("updateLatest".equals(key)) runOnUiThread(this::updateSettingsValues);
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state); // 테마(AhnaTheme)는 res/values(-night)에서 시스템 다크 모드를 따릅니다.
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        prefs = getSharedPreferences("아나", MODE_PRIVATE);
        prefs.registerOnSharedPreferenceChangeListener(prefsListener);
        try { String v = getPackageManager().getPackageInfo(getPackageName(), 0).versionName; version = v == null ? "" : v; } catch (Exception ignored) {}
        nearby = new NearbyUi(this);
        buildUI();
        UpdateCheck.run(this, prefs, false);
        try {
            JSONArray saved = new JSONArray(decrypt(prefs.getString("connections", "")));
            for (int i = 0; i < saved.length(); i++) clients.add(new Client(saved.getJSONObject(i)));
            String identity = prefs.getString("identity", null);
            if (identity == null) { identity = Protocol.uuid(); prefs.edit().putString("identity", identity).apply(); }
            server = new Protocol(new File(getFilesDir(), "receiver"), identity, deviceName(), new Protocol.Store() {
                public String load() { try { return decrypt(prefs.getString("sessions", "")); } catch (Exception e) { return "[]"; } }
                public void save(String text) { try { prefs.edit().putString("sessions", encrypt(text)).commit(); } catch (Exception e) { throw new IllegalStateException(e); } }
            }, new Protocol.Listener() {
                public void received(File file, String display) throws Exception { export(file, display, null); status(display + " · 저장 완료"); }
                public void changed() { runOnUiThread(() -> { updateTargets(); updateInbox(); if (server != null) showAddresses(); }); }
            });
            // 한 번의 코드 입력으로 양쪽 연결: 다른 기기가 이 기기와 연결하며 넘겨준 그 기기 쪽 연결을 추가한 기기로 저장합니다.
            server.reverseListener = credential -> { addReverse(credential); return true; };
            // 근처 기기 · QR: 게스트 티켓(/s/…)의 웹 페이지와 알림
            server.guestHtml = asset("guest.html");
            server.guestGoneHtml = asset("guest-gone.html");
            server.guestListener = nearby;
            server.start(45851);
            showAddresses();
            if (!prefs.getString("nasKey", "").isEmpty()) try { startRelay(); } catch (Exception e) { setRelayText(e.getMessage()); }
            else handler.postDelayed(this::editNas, 400);   // 처음 실행: 초대 코드로 가입
            handler.post(poll);
            handleIntent(getIntent());
        } catch (Exception e) { status("시작 실패 · " + e.getMessage()); }
    }

    String deviceName() { return prefs.getString("name", "나의 Android"); }
    String asset(String name) {
        try (InputStream in = getAssets().open(name)) { java.io.ByteArrayOutputStream b = new java.io.ByteArrayOutputStream(); byte[] buf = new byte[8192]; int n; while ((n = in.read(buf)) >= 0) b.write(buf, 0, n); return b.toString("UTF-8"); }
        catch (Exception e) { return "<!doctype html><meta charset=utf-8><title>아나</title><p>아나</p>"; }
    }
    /** 근처 기기 · QR 공유는 상대가 이 기기 서버 주소로 받아 가므로 서버 수신이 연결돼 있어야 합니다. */
    boolean guestReady() { String t = relayText; return server != null && relay != null && !prefs.getString("nasKey", "").isEmpty() && t != null && t.startsWith("서버 연결됨"); }
    /** 게스트 URL: https://<서버>/s/<이 기기 ID>/<토큰> */
    String guestURL(String token) { return Brand.SERVER + "/s/" + server.identity + "/" + token; }
    /** This app's receiver identity; sent when pairing and polling so other hosts list this device once. */
    String identity() { return prefs.getString("identity", null); }
    /** 아나: 서버는 고정입니다. */
    String nasAddress() { return Brand.SERVER; }
    int dp(float v) { return ui.dp(v); }

    void status(String text) { runOnUiThread(() -> showSnack(text == null ? "전송하지 못했습니다." : text)); }
    void showSnack(String message) {
        if (snack == null || message.isEmpty()) return;
        snack.animate().cancel();
        snack.setText(message);
        snack.setContentDescription(message);
        if (snack.getVisibility() != View.VISIBLE) { snack.setAlpha(0f); snack.setVisibility(View.VISIBLE); }
        snack.animate().alpha(1f).setDuration(150).start();
        snack.announceForAccessibility(message);
        handler.removeCallbacks(hideSnack);
        handler.postDelayed(hideSnack, 3500);
    }

    // =====================================================================================
    // Layout
    // =====================================================================================

    void buildUI() {
        String previousDraft = draft == null ? "" : draft.getText().toString();
        String previousPin = pin == null ? "" : pin.getText().toString();
        ui = new Ui(this);
        columns = columnsFor(prefs.getString("layoutMode", "auto"), getResources().getConfiguration().screenWidthDp);
        tablet = columns >= 2;
        nasPills.clear(); headers.clear(); bodies.clear();
        deviceLine = null; nearBox = null;
        if (nearby != null) { nearby.nearBox = null; nearby.optionsBox = null; }
        targetPrint = ""; connectionPrint = ""; inboxPrint = "";

        root = new FrameLayout(this);
        root.setBackgroundColor(ui.bg);
        getWindow().setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(ui.bg));
        homePage = page(true);
        optionsPage = page(false);
        root.addView(homePage, new FrameLayout.LayoutParams(-1, -1));
        root.addView(optionsPage, new FrameLayout.LayoutParams(-1, -1));

        snack = ui.text("", 13, ui.dark ? ui.bg : 0xffffffff, Ui.MEDIUM);
        snack.setBackground(ui.round(ui.dark ? 0xffe8eaed : 0xff1f2328, 12));
        snack.setPadding(dp(16), dp(10), dp(16), dp(10));
        snack.setGravity(Gravity.CENTER);
        snack.setMaxWidth(dp(440));
        snack.setElevation(dp(6));
        snack.setVisibility(View.GONE);
        snack.setOnClickListener(v -> handler.post(hideSnack));
        FrameLayout.LayoutParams sl = new FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        sl.setMargins(dp(16), 0, dp(16), 0);
        root.addView(snack, sl);

        tabBar = buildTabs();
        root.addView(tabBar, new FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL));

        root.setOnApplyWindowInsetsListener((v, in) -> {
            int l, t, r, b, ime;
            if (Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets bars = in.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                android.graphics.Insets keyboard = in.getInsets(WindowInsets.Type.ime());
                l = bars.left; t = bars.top; r = bars.right; b = bars.bottom; ime = keyboard.bottom;
            } else {
                l = in.getSystemWindowInsetLeft(); t = in.getSystemWindowInsetTop(); r = in.getSystemWindowInsetRight();
                int all = in.getSystemWindowInsetBottom();
                b = Math.min(all, in.getStableInsetBottom());
                ime = all > b + dp(80) ? all : 0;
            }
            applyInsets(l, t, r, b, ime);
            return in;
        });

        if (nearby != null) { nearby.nearBox = nearBox; nearby.nearPrint = ""; }
        selectTab(activeTab);
        setContentView(root);
        ui.edgeToEdge(this);
        root.requestApplyInsets();

        draft.setText(previousDraft);
        pin.setText(previousPin);
        renderPending();
        updateHistory();
        updateTargets();
        updateInbox();
        showAddresses();
        updateNasViews();
        updateSettingsValues();
    }

    /**
     * 화면 구성: 지금 창의 너비(dp)로 열 수를 고릅니다. 자동 = 700 미만 1열(휴대폰 배치) · 700~999 2열 · 1000 이상 3열.
     * 휴대폰 = 늘 1열, 태블릿 = 너비에 따라 2열 또는 3열(1열은 쓰지 않음). 회전·분할 화면 크기가 바뀌면 다시 계산합니다.
     */
    static int columnsFor(String mode, int widthDp) {
        int byWidth = widthDp >= 1000 ? 3 : widthDp >= 700 ? 2 : 1;
        if ("phone".equals(mode)) return 1;
        if ("tablet".equals(mode)) return Math.max(2, byWidth);
        return byWidth;
    }

    void applyInsets(int l, int t, int r, int b, int ime) {
        insetBottom = b; imeBottom = ime;
        root.setPadding(l, 0, r, ime > 0 ? ime : 0);
        for (View h : headers) h.setPadding(h.getPaddingLeft(), t, h.getPaddingRight(), h.getPaddingBottom());
        for (View body : bodies) padBody(body);
        FrameLayout.LayoutParams tl = (FrameLayout.LayoutParams) tabBar.getLayoutParams();
        tl.bottomMargin = dp(24) + b;
        tabBar.setLayoutParams(tl);
        tabBar.setVisibility(ime > 0 ? View.GONE : View.VISIBLE);
        FrameLayout.LayoutParams sl = (FrameLayout.LayoutParams) snack.getLayoutParams();
        sl.bottomMargin = ime > 0 ? dp(12) : dp(24 + 70 + 12) + b;
        snack.setLayoutParams(sl);
    }

    void padBody(View body) {
        int bottom = (tablet ? dp(108) : dp(112)) + insetBottom;
        if (imeBottom > 0) bottom = dp(16);
        if (tablet) body.setPadding(dp(24), dp(4), dp(24), bottom);
        else body.setPadding(dp(16), dp(16), dp(16), bottom);
    }

    /** One tab: a fixed header and a scrolling body. */
    View page(boolean home) {
        LinearLayout page = ui.column();
        page.addView(header(home), new LinearLayout.LayoutParams(-1, -2));
        if (!tablet) page.addView(ui.divider());
        ScrollView scroll = new ScrollView(this);
        scroll.setClipToPadding(false);
        scroll.setFillViewport(true);
        LinearLayout body = ui.column();
        bodies.add(body);
        padBody(body);
        scroll.addView(body, new FrameLayout.LayoutParams(-1, -2));
        page.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        if (home) { if (columns >= 3) homeTablet(body); else if (columns == 2) homeTwoColumns(body); else homePhone(body); }
        else { if (columns >= 3) optionsTablet(body); else if (columns == 2) optionsTwoColumns(body); else optionsPhone(body); }
        return page;
    }

    View header(boolean home) {
        LinearLayout outer = ui.column();
        if (!tablet) outer.setBackgroundColor(ui.surface);
        headers.add(outer);
        LinearLayout row = ui.row();
        row.setPadding(dp(tablet ? 24 : 16), 0, dp(tablet ? 24 : 16), 0);
        outer.addView(row, new LinearLayout.LayoutParams(-1, dp(tablet ? 68 : 60)));
        int gap = tablet ? 12 : 10;
        if (home || tablet) {
            float box = tablet ? 36 : 32;
            row.addView(ui.tile("send", tablet ? 10 : 9, tablet ? 20 : 18, ui.accent, ui.onAccent), ui.lp(box, box, 0, 0, gap, 0));
        }
        TextView title = ui.text(home ? "아나" : "옵션", tablet ? 22 : 19, ui.text, Ui.BOLD);
        title.setLetterSpacing(-0.015f);
        title.setAccessibilityHeading(true);
        row.addView(title, ui.lp(-2, -2, 0, 0, gap, 0));
        if (home && !version.isEmpty()) {
            TextView v = ui.text("v" + version, 12, ui.faint, Ui.REGULAR);
            v.setFontFeatureSettings("tnum");
            row.addView(v, ui.lp(-2, -2, 0, 0, gap, 0));
        }
        if (!tablet) row.addView(ui.space(0, 0), ui.flex(1));
        row.addView(nasPill(), ui.lp(-2, 28));
        if (tablet) {
            row.addView(ui.space(0, 0), ui.flex(1));
            if (home) {
                deviceLine = Ui.oneLine(ui.text("", 13, ui.faint, Ui.REGULAR));
                row.addView(deviceLine, ui.lp(-2, -2, 12, 0, 0, 0));
            }
        }
        return outer;
    }

    LinearLayout nasPill() {
        LinearLayout p = ui.row();
        p.setPadding(dp(10), 0, dp(10), 0);
        p.addView(new View(this), ui.lp(8, 8, 0, 0, 6, 0));
        p.addView(ui.text("", 12, ui.on, Ui.MEDIUM));
        p.setClickable(true); p.setFocusable(true);
        p.setOnClickListener(v -> {
            if (nasState() == 0) { editNas(); return; }
            String t = relayText;
            status(t == null ? "서버에 연결하는 중입니다." : t);
        });
        nasPills.add(p);
        return p;
    }

    /** 0 = 설정 필요, 1 = 연결 중, 2 = 연결됨, 3 = 재연결 대기 */
    int nasState() {
        if (prefs.getString("nasKey", "").isEmpty()) return 0;
        String t = relayText;
        if (t != null && t.startsWith("서버 연결됨")) return 2;
        // 받는 통로가 아직 안 붙었어도, 추가한 기기와 NAS로 주고받는 중이면 연결된 것입니다.
        for (Client c : clients) if (c.state != null) return 2;
        return t == null ? 1 : 3;
    }

    void setRelayText(String text) { relayText = text; runOnUiThread(() -> { updateNasViews(); updateSettingsValues(); }); }

    void updateNasViews() {
        int s = nasState();
        String label = s == 0 ? "서버 설정 필요" : s == 1 ? "서버 연결 중" : s == 2 ? "서버 연결됨" : "서버 재연결 대기";
        for (LinearLayout p : nasPills) {
            boolean ok = s == 2;
            p.setBackground(ui.pressable(ok ? ui.round(ui.accentSoft, 14) : ui.round(ui.subtle, 14, ui.border, 1), 14));
            p.getChildAt(0).setBackground(ok ? ui.oval(ui.on) : ui.ring(ui.off, 1.5f));
            TextView t = (TextView) p.getChildAt(1);
            t.setText(label);
            t.setTextColor(ok ? ui.on : ui.faint);
            p.setContentDescription(relayText == null ? label : relayText);
        }
    }

    LinearLayout buildTabs() {
        LinearLayout bar = ui.row();
        bar.setPadding(dp(5), dp(5), dp(5), dp(5));
        bar.setBackground(ui.round(ui.pill, 36, ui.pillLine, 1));
        ui.roundOutline(bar, 36);
        bar.setElevation(dp(10));
        String[] labels = {"주고받기", "옵션"};
        tabItems = new LinearLayout[2];
        for (int i = 0; i < 2; i++) {
            final int tab = i;
            LinearLayout item = ui.column();
            item.setGravity(Gravity.CENTER);
            item.addView(new ImageView(this), ui.lp(22, 22, 0, 0, 0, 2));
            TextView label = ui.text(labels[i], 12, ui.text, Ui.MEDIUM);
            label.setGravity(Gravity.CENTER);
            item.addView(label);
            item.setClickable(true); item.setFocusable(true);
            item.setOnClickListener(v -> selectTab(tab));
            bar.addView(item, ui.lp(124, 60, i == 0 ? 0 : 4, 0, 0, 0));
            tabItems[i] = item;
        }
        return bar;
    }

    void selectTab(int tab) {
        activeTab = tab;
        homePage.setVisibility(tab == 0 ? View.VISIBLE : View.GONE);
        optionsPage.setVisibility(tab == 1 ? View.VISIBLE : View.GONE);
        String[] labels = {"주고받기", "옵션"};
        for (int i = 0; i < tabItems.length; i++) {
            boolean on = i == tab;
            LinearLayout item = tabItems[i];
            item.setBackground(ui.pressable(ui.round(on ? ui.pillOn : 0x00000000, 30), 30));
            int color = on ? ui.accent : ui.text;
            String icon = i == 0 ? "swap" : (on ? "gear_fill" : "gear");
            ((ImageView) item.getChildAt(0)).setImageDrawable(ui.iconDrawable(icon, color));
            TextView t = (TextView) item.getChildAt(1);
            t.setTextColor(color);
            Ui.weight(t, on ? Ui.BOLD : Ui.MEDIUM);
            item.setSelected(on);
            item.setContentDescription(labels[i] + (on ? ", 선택됨" : ""));
        }
    }

    // ---------- 주고받기 ----------

    void homePhone(LinearLayout body) {
        LinearLayout section = ui.column();
        section.addView(ui.text("보낼 기기", 13, ui.muted, Ui.MEDIUM), ui.lp(-1, -2, 0, 0, 0, 8));
        HorizontalScrollView chips = new HorizontalScrollView(this);
        chips.setHorizontalScrollBarEnabled(false);
        chips.setClipToPadding(false);
        targetBox = ui.row();
        chips.addView(targetBox, new FrameLayout.LayoutParams(-2, -2));
        section.addView(chips, new LinearLayout.LayoutParams(-1, -2));
        nearBox = ui.column();
        nearBox.setVisibility(View.GONE);
        section.addView(nearBox, ui.lp(-1, -2, 0, 12, 0, 0));
        body.addView(section);
        body.addView(fileCard(), ui.lp(-1, -2, 0, 14, 0, 0));
        body.addView(textCard(), ui.lp(-1, -2, 0, 14, 0, 0));
        body.addView(inboxCard(), ui.lp(-1, -2, 0, 14, 0, 0));
        body.addView(historyCard(), ui.lp(-1, -2, 0, 14, 0, 0));
    }

    void homeTablet(LinearLayout body) {
        LinearLayout grid = ui.row();
        grid.setGravity(Gravity.TOP);
        LinearLayout a = ui.column(), b = ui.column(), c = ui.column();
        grid.addView(a, ui.flex(1));
        LinearLayout.LayoutParams mid = ui.flex(1); mid.setMargins(dp(16), 0, dp(16), 0);
        grid.addView(b, mid);
        grid.addView(c, ui.flex(1));
        body.addView(grid, new LinearLayout.LayoutParams(-1, -2));

        LinearLayout targetsCard = ui.card();
        targetsCard.addView(ui.heading("보낼 기기"), ui.lp(-1, -2, 0, 0, 0, 4));
        targetBox = ui.column();
        targetsCard.addView(targetBox, new LinearLayout.LayoutParams(-1, -2));
        nearBox = ui.column();
        nearBox.setVisibility(View.GONE);
        targetsCard.addView(nearBox, ui.lp(-1, -2, 0, 12, 0, 0));
        a.addView(targetsCard, new LinearLayout.LayoutParams(-1, -2));
        a.addView(fileCard(), ui.lp(-1, -2, 0, 16, 0, 0));
        b.addView(textCard(), new LinearLayout.LayoutParams(-1, -2));
        b.addView(inboxCard(), ui.lp(-1, -2, 0, 16, 0, 0));
        c.addView(historyCard(), new LinearLayout.LayoutParams(-1, -2));
    }

    /** 태블릿 세로(2열): 왼쪽 보낼 기기 · 파일 보내기 · 글자 보내기, 오른쪽 받은 글자 · 받은 파일. */
    void homeTwoColumns(LinearLayout body) {
        LinearLayout grid = ui.row();
        grid.setGravity(Gravity.TOP);
        LinearLayout a = ui.column(), b = ui.column();
        grid.addView(a, ui.flex(1));
        LinearLayout.LayoutParams right = ui.flex(1); right.setMargins(dp(16), 0, 0, 0);
        grid.addView(b, right);
        body.addView(grid, new LinearLayout.LayoutParams(-1, -2));

        LinearLayout targetsCard = ui.card();
        targetsCard.addView(ui.heading("보낼 기기"), ui.lp(-1, -2, 0, 0, 0, 4));
        targetBox = ui.column();
        targetsCard.addView(targetBox, new LinearLayout.LayoutParams(-1, -2));
        nearBox = ui.column();
        nearBox.setVisibility(View.GONE);
        targetsCard.addView(nearBox, ui.lp(-1, -2, 0, 12, 0, 0));
        a.addView(targetsCard, new LinearLayout.LayoutParams(-1, -2));
        a.addView(fileCard(), ui.lp(-1, -2, 0, 16, 0, 0));
        a.addView(textCard(), ui.lp(-1, -2, 0, 16, 0, 0));
        b.addView(inboxCard(), new LinearLayout.LayoutParams(-1, -2));
        b.addView(historyCard(), ui.lp(-1, -2, 0, 16, 0, 0));
    }

    LinearLayout fileCard() {
        LinearLayout card = ui.card();
        LinearLayout top = ui.row();
        top.addView(ui.heading("파일 보내기"), ui.flex(1));
        // QR로 보내기 / 받기 (앱이 없는 상대와 서버를 거쳐 주고받기)
        Button qr = ui.soft("QR");
        ui.leadingIcon(qr, "qr", 15, ui.accent);
        qr.setPadding(dp(12), 0, dp(14), 0);
        qr.setContentDescription("QR로 보내기 또는 받기");
        qr.setOnClickListener(v -> { if (nearby != null) nearby.showQr(); });
        top.addView(qr, ui.lp(-2, 34));
        card.addView(top);
        LinearLayout drop = ui.column();
        drop.setGravity(Gravity.CENTER_HORIZONTAL);
        drop.setPadding(dp(12), dp(tablet ? 24 : 22), dp(12), dp(tablet ? 24 : 22));
        drop.setBackground(ui.pressable(ui.dashed(ui.subtle, 12, ui.borderStrong, 1.5f), 12));
        float circle = tablet ? 48 : 44;
        drop.addView(ui.tile("upload", -1, 22, ui.accentSoft, ui.accent), ui.lp(circle, circle, 0, 0, 0, 6));
        drop.addView(ui.text("파일 선택", 14, ui.text, Ui.MEDIUM), ui.lp(-2, -2, 0, 0, 0, 6));
        TextView hint = ui.text("사진 · 문서 · 동영상 / 파일당 최대 4 GiB", 12, ui.faint, Ui.REGULAR);
        hint.setGravity(Gravity.CENTER);
        drop.addView(hint);
        drop.setClickable(true); drop.setFocusable(true);
        drop.setContentDescription("파일 선택. 사진, 문서, 동영상, 파일당 최대 4 GiB");
        drop.setOnClickListener(v -> pickFiles());
        card.addView(drop, ui.lp(-1, -2, 0, 12, 0, 0));
        pendingBox = ui.column();
        card.addView(pendingBox, new LinearLayout.LayoutParams(-1, -2));
        sendButton = ui.primary("보내기");
        sendButton.setOnClickListener(v -> sendFiles());
        card.addView(sendButton, ui.lp(-1, 50, 0, 12, 0, 0));
        return card;
    }

    LinearLayout textCard() {
        LinearLayout card = ui.card();
        LinearLayout top = ui.row();
        top.addView(ui.heading("글자 보내기"), ui.flex(1));
        Button paste = ui.plain("붙여넣기");
        ui.leadingIcon(paste, "clipboard", 15, ui.text);
        paste.setOnClickListener(v -> {
            ClipboardManager cb = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
            if (cb != null && cb.hasPrimaryClip() && cb.getPrimaryClip() != null && cb.getPrimaryClip().getItemCount() > 0)
                draft.setText(cb.getPrimaryClip().getItemAt(0).coerceToText(this));
        });
        top.addView(paste, ui.lp(-2, 36));
        card.addView(top);
        draft = ui.field("보낼 글자를 입력하거나 붙여넣으세요");
        draft.setSingleLine(false);
        draft.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE | InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        draft.setGravity(Gravity.TOP | Gravity.START);
        draft.setMinHeight(dp(tablet ? 120 : 92));
        draft.setMaxLines(8);
        draft.setContentDescription("보낼 글자");
        card.addView(draft, ui.lp(-1, -2, 0, 12, 0, 0));
        Button send = ui.outline("글자 보내기");
        send.setOnClickListener(v -> sendDraft());
        card.addView(send, ui.lp(-1, 46, 0, 12, 0, 0));
        return card;
    }

    LinearLayout inboxCard() {
        LinearLayout card = ui.card();
        card.setPadding(dp(16), dp(16), dp(16), dp(12));
        card.addView(ui.heading("받은 글자"), ui.lp(-1, -2, 0, 0, 0, 6));
        inbox = ui.column();
        card.addView(inbox, new LinearLayout.LayoutParams(-1, -2));
        return card;
    }

    LinearLayout historyCard() {
        LinearLayout card = ui.card();
        card.setPadding(dp(16), dp(16), dp(16), dp(8));
        LinearLayout top = ui.row();
        top.addView(ui.heading("받은 파일"), ui.flex(1));
        historyFolder = Ui.oneLine(ui.text("", 12, ui.faint, Ui.REGULAR));
        top.addView(historyFolder, ui.lp(-2, -2, 8, 0, 0, 0));
        card.addView(top, ui.lp(-1, -2, 0, 0, 0, 6));
        historyBox = ui.column();
        card.addView(historyBox, new LinearLayout.LayoutParams(-1, -2));
        Button clear = ui.button("목록 초기화", 0x00000000, ui.muted, 0, 10, 13, Ui.REGULAR);
        clear.setOnClickListener(v -> {
            prefs.edit().putString("receivedHistory060", "[]").apply();
            updateHistory();
            status("목록만 초기화했습니다. 저장된 파일은 유지됩니다.");
        });
        card.addView(clear, ui.lp(-2, 36, 0, 4, 0, 0));
        return card;
    }

    // ---------- 옵션 ----------

    /** 옵션 맨 위: 이름 풀이 */
    LinearLayout meaningCard() {
        LinearLayout card = ui.row();
        card.setGravity(Gravity.CENTER_VERTICAL);
        card.setBackground(ui.round(ui.surface, 14, ui.border, 1));
        card.setPadding(dp(14), dp(12), dp(14), dp(12));
        android.widget.ImageView logo = new android.widget.ImageView(this);
        logo.setImageResource(getResources().getIdentifier("ahna", "drawable", getPackageName()));
        card.addView(logo, new LinearLayout.LayoutParams(dp(36), dp(36)));
        LinearLayout t = ui.column();
        t.addView(ui.text("아나", 16, ui.text, Ui.BOLD));
        t.addView(ui.text("경상도 말로 “옛다, 받아라”", 12, ui.muted, Ui.REGULAR));
        t.addView(ui.text("— 툭 건네듯 주고받으세요", 12, ui.muted, Ui.REGULAR));
        LinearLayout.LayoutParams tp = ui.flex(1); tp.setMargins(dp(12), 0, 0, 0);
        card.addView(t, tp);
        return card;
    }

    void optionsPhone(LinearLayout body) {
        body.addView(meaningCard(), ui.lp(-1, -2, 0, 0, 0, 14));
        body.addView(codeCard());
        body.addView(connectionsCard(), ui.lp(-1, -2, 0, 14, 0, 0));
        body.addView(addCard(), ui.lp(-1, -2, 0, 14, 0, 0));
        body.addView(nearby.optionsCard(), ui.lp(-1, -2, 0, 14, 0, 0));
        body.addView(nearby.sendInfoCard(), ui.lp(-1, -2, 0, 14, 0, 0));
        body.addView(settingsCard(), ui.lp(-1, -2, 0, 14, 0, 0));
    }

    void optionsTablet(LinearLayout body) {
        body.addView(meaningCard(), ui.lp(-1, -2, 0, 0, 0, 16));
        LinearLayout grid = ui.row();
        grid.setGravity(Gravity.TOP);
        LinearLayout a = ui.column();
        grid.addView(a, ui.flex(1));
        LinearLayout.LayoutParams mid = ui.flex(1); mid.setMargins(dp(16), 0, dp(16), 0);
        LinearLayout b = ui.column();
        b.addView(connectionsCard(), new LinearLayout.LayoutParams(-1, -2));
        b.addView(nearby.optionsCard(), ui.lp(-1, -2, 0, 16, 0, 0));
        grid.addView(b, mid);
        LinearLayout c = ui.column();
        c.addView(settingsCard(), new LinearLayout.LayoutParams(-1, -2));
        c.addView(nearby.sendInfoCard(), ui.lp(-1, -2, 0, 16, 0, 0));
        grid.addView(c, ui.flex(1));
        a.addView(codeCard(), new LinearLayout.LayoutParams(-1, -2));
        a.addView(addCard(), ui.lp(-1, -2, 0, 16, 0, 0));
        body.addView(grid, new LinearLayout.LayoutParams(-1, -2));
    }

    /** 태블릿 세로(2열): 왼쪽 연결 코드 · 기기 추가 · 연결된 기기, 오른쪽 설정. */
    void optionsTwoColumns(LinearLayout body) {
        body.addView(meaningCard(), ui.lp(-1, -2, 0, 0, 0, 16));
        LinearLayout grid = ui.row();
        grid.setGravity(Gravity.TOP);
        LinearLayout a = ui.column();
        grid.addView(a, ui.flex(1));
        LinearLayout.LayoutParams right = ui.flex(1); right.setMargins(dp(16), 0, 0, 0);
        LinearLayout b = ui.column();
        b.addView(nearby.optionsCard(), new LinearLayout.LayoutParams(-1, -2));
        b.addView(settingsCard(), ui.lp(-1, -2, 0, 16, 0, 0));
        b.addView(nearby.sendInfoCard(), ui.lp(-1, -2, 0, 16, 0, 0));
        grid.addView(b, right);
        a.addView(codeCard(), new LinearLayout.LayoutParams(-1, -2));
        a.addView(addCard(), ui.lp(-1, -2, 0, 16, 0, 0));
        a.addView(connectionsCard(), ui.lp(-1, -2, 0, 16, 0, 0));
        body.addView(grid, new LinearLayout.LayoutParams(-1, -2));
    }

    LinearLayout codeCard() {
        LinearLayout card = ui.column();
        int pad = dp(tablet ? 20 : 18);
        card.setPadding(pad, pad, pad, pad);
        card.setBackground(ui.round(ui.accent, 16));
        TextView label = ui.text("이 기기의 연결 코드", 13, ui.onAccent, Ui.MEDIUM);
        label.setAlpha(0.9f);
        card.addView(label);
        LinearLayout row = ui.row();
        codeView = ui.text("------", tablet ? 40 : 36, ui.onAccent, Ui.BOLD);
        codeView.setLetterSpacing(0.17f);
        codeView.setFontFeatureSettings("tnum");
        row.addView(codeView, ui.flex(1));
        FrameLayout copy = ui.iconButton("copy", 18, ui.onAccent, "코드 복사");
        copy.setBackground(ui.pressable(ui.round(0x00000000, 12, ui.onAccentLine, 1), 12));
        copy.setOnClickListener(v -> {
            if (server == null) return;
            ClipboardManager cb = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
            if (cb != null) cb.setPrimaryClip(ClipData.newPlainText("아나", server.pin));
            status("연결 코드를 복사했습니다.");
        });
        row.addView(copy, ui.lp(44, 44, 10, 0, 0, 0));
        card.addView(row, ui.lp(-1, -2, 0, tablet ? 8 : 6, 0, tablet ? 8 : 6));
        String before = "다른 기기의 아나에서 ", bold = "기기 추가", after = "를 누르고 이 코드를 입력하세요. 받는 동안 앱을 열어 두세요.";
        SpannableStringBuilder note = new SpannableStringBuilder(before + bold + after);
        note.setSpan(new StyleSpan(android.graphics.Typeface.BOLD), before.length(), before.length() + bold.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        TextView p = ui.text(note, 12, ui.onAccent, Ui.REGULAR);
        p.setAlpha(0.9f);
        card.addView(p);
        return card;
    }

    LinearLayout connectionsCard() {
        LinearLayout card = ui.card();
        card.setPadding(dp(16), dp(6), dp(16), dp(6));
        card.addView(ui.heading("연결된 기기"), ui.lp(-1, -2, 0, 10, 0, 4));
        connections = ui.column();
        card.addView(connections, new LinearLayout.LayoutParams(-1, -2));
        return card;
    }

    LinearLayout addCard() {
        LinearLayout card = ui.card();
        card.addView(ui.heading("기기 추가"));
        card.addView(ui.text("상대 기기에 ‘서버 연결됨’이 보이는지 확인하고, 그 기기의 연결 코드를 입력하세요.", 12, ui.faint, Ui.REGULAR), ui.lp(-1, -2, 0, 10, 0, 0));
        card.addView(ui.text("상대 기기의 6자리 코드", 12, ui.muted, Ui.REGULAR), ui.lp(-1, -2, 0, 10, 0, 0));
        LinearLayout row = ui.row();
        pin = ui.field("000000");
        pin.setInputType(InputType.TYPE_CLASS_NUMBER);
        pin.setFilters(new InputFilter[]{new InputFilter.LengthFilter(6)});
        pin.setTextSize(22);
        pin.setLetterSpacing(0.36f);
        pin.setGravity(Gravity.CENTER);
        pin.setSingleLine(true);
        pin.setPadding(dp(14), 0, dp(14), 0);
        pin.setContentDescription("상대 기기의 6자리 코드");
        row.addView(pin, new LinearLayout.LayoutParams(0, dp(50), 1));
        Button add = ui.primary("추가");
        add.setTextSize(14);
        add.setOnClickListener(v -> addDevice());
        row.addView(add, ui.lp(88, 50, 8, 0, 0, 0));
        card.addView(row, ui.lp(-1, -2, 0, 6, 0, 0));
        return card;
    }

    LinearLayout settingsCard() {
        LinearLayout card = ui.column();
        card.setBackground(ui.round(ui.surface, 16, ui.border, 1));
        card.setPadding(0, 0, 0, dp(1));
        TextView h = ui.heading("설정");
        h.setPadding(dp(16), dp(14), dp(16), dp(6));
        card.addView(h);
        nameValue = settingRow(card, "이 기기의 이름", ui.text, this::editName, null);
        nasValue = settingRow(card, "서버", ui.text, this::editNas, null);
        folderValue = settingRow(card, "받은 파일 저장 위치", ui.text, this::chooseFolder, null);
        card.addView(ui.divider());
        LinearLayout layoutRow = ui.row();
        layoutRow.setMinimumHeight(dp(60));
        layoutRow.setPadding(dp(16), dp(8), dp(16), dp(8));
        layoutRow.addView(ui.text("화면 구성", 14, ui.text, Ui.REGULAR), ui.flex(1));
        layoutRow.addView(segmented());
        card.addView(layoutRow, new LinearLayout.LayoutParams(-1, -2));
        updateValue = settingRow(card, "앱 업데이트", ui.text, () -> UpdateCheck.run(this, prefs, true), "확인");
        TextView revoke = settingRow(card, "모든 기기 해제 · 코드 새로 만들기", ui.danger, this::confirmRevoke, "");
        revoke.setText("이 기기에 연결한 모든 기기가 다시 코드를 입력해야 합니다");
        return card;
    }

    /** A settings row (divider above). trailing: null = chevron, "" = nothing, other = accent text. Returns the value line. */
    TextView settingRow(LinearLayout card, String label, int color, Runnable action, String trailing) {
        card.addView(ui.divider());
        LinearLayout row = ui.row();
        row.setMinimumHeight(dp(60));
        row.setPadding(dp(16), dp(8), dp(16), dp(8));
        row.setBackground(ui.pressable(null, 0));
        LinearLayout texts = ui.column();
        texts.addView(ui.text(label, 14, color, Ui.REGULAR));
        TextView value = ui.text("", 12, ui.faint, Ui.REGULAR);
        texts.addView(value);
        row.addView(texts, ui.flex(1));
        if (trailing == null) row.addView(ui.icon("chevron", ui.faint), ui.lp(16, 16, 12, 0, 0, 0));
        else if (!trailing.isEmpty()) row.addView(ui.text(trailing, 13, ui.accent, Ui.MEDIUM), ui.lp(-2, -2, 12, 0, 0, 0));
        row.setClickable(true); row.setFocusable(true);
        row.setOnClickListener(v -> action.run());
        card.addView(row, new LinearLayout.LayoutParams(-1, -2));
        return value;
    }

    View segmented() {
        final String[] modes = {"auto", "phone", "tablet"}, labels = {"자동", "휴대폰", "태블릿"};
        String mode = prefs.getString("layoutMode", "auto");
        LinearLayout group = ui.row();
        group.setPadding(dp(3), dp(3), dp(3), dp(3));
        group.setBackground(ui.round(ui.subtle, 10, ui.border, 1));
        group.setContentDescription("화면 구성");
        for (int i = 0; i < modes.length; i++) {
            final String value = modes[i];
            boolean on = value.equals(mode);
            TextView b = ui.text(labels[i], 13, on ? ui.text : ui.muted, on ? Ui.MEDIUM : Ui.REGULAR);
            b.setGravity(Gravity.CENTER);
            b.setPadding(dp(12), 0, dp(12), 0);
            b.setBackground(on ? ui.round(ui.surface, 8) : ui.pressable(null, 8));
            if (on) { b.setElevation(dp(1)); }
            b.setClickable(true); b.setFocusable(true);
            b.setSelected(on);
            b.setContentDescription(labels[i] + (on ? ", 선택됨" : ""));
            b.setOnClickListener(v -> {
                if (prefs.getString("layoutMode", "auto").equals(value)) return;
                prefs.edit().putString("layoutMode", value).apply();
                handler.post(this::buildUI);
            });
            group.addView(b, ui.lp(-2, 32));
        }
        return group;
    }

    // =====================================================================================
    // Options actions
    // =====================================================================================

    void editName() {
        EditText e = ui.field("이 기기의 이름");
        e.setSingleLine(true);
        e.setText(deviceName());
        e.setSelection(e.getText().length());
        AlertDialog d = ui.dialog().setTitle("이 기기의 이름").setView(ui.dialogBody(e))
                .setPositiveButton("저장", null).setNegativeButton("취소", null).create();
        ui.show(d, false);
        d.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            String value = e.getText().toString().trim();
            if (value.isEmpty() || value.length() > 40 || value.matches(".*[\\p{Cntrl}].*")) { e.setError("이름은 1~40자로 입력하세요."); return; }
            prefs.edit().putString("name", value).apply();
            if (server != null) server.name = value;
            if (nearby != null) nearby.refreshName();
            d.dismiss();
            updateSettingsValues();
            showAddresses();
            status("이름을 저장했습니다.");
        });
    }

    /** 아나 서버 가입: 초대 코드 → 이 기기 전용 토큰 (POST /_ahna/join) */
    String join(String invite) throws Exception {
        java.net.HttpURLConnection c = (java.net.HttpURLConnection) new java.net.URL(Brand.SERVER + "/_ahna/join").openConnection();
        c.setConnectTimeout(15000); c.setReadTimeout(20000); c.setRequestMethod("POST"); c.setDoOutput(true);
        c.setRequestProperty("Content-Type", "application/json");
        byte[] body = new org.json.JSONObject().put("invite", invite.trim()).put("computer", identity()).put("name", deviceName()).put("platform", "Android").toString().getBytes(java.nio.charset.StandardCharsets.UTF_8);
        c.setFixedLengthStreamingMode(body.length);
        try (java.io.OutputStream o = c.getOutputStream()) { o.write(body); }
        int code = c.getResponseCode();
        java.io.InputStream in = code < 400 ? c.getInputStream() : c.getErrorStream();
        String text = "";
        if (in != null) try (java.io.InputStream s = in) { java.io.ByteArrayOutputStream b = new java.io.ByteArrayOutputStream(); byte[] buf = new byte[4096]; int n; while ((n = s.read(buf)) > 0 && b.size() < 65536) b.write(buf, 0, n); text = b.toString("UTF-8"); }
        org.json.JSONObject r; try { r = new org.json.JSONObject(text); } catch (Exception e) { r = new org.json.JSONObject(); }
        if (code == 404) throw new IOException("서버에 초대 코드가 설정되지 않았습니다. 서버 관리자에게 알려 주세요.");
        if (code == 429) throw new IOException("초대 코드를 너무 많이 시도했습니다. 10분 뒤에 다시 시도하세요.");
        if (code != 200) throw new IOException(r.optString("error", "연결하지 못했습니다 (" + code + ")."));
        String token = r.optString("token");
        if (!Brand.isMemberToken(token)) throw new IOException("서버 응답이 올바르지 않습니다.");
        return token;
    }

    /** 아나: 서버 주소는 고정, 초대 코드로 가입합니다. 처음 실행하면 자동으로 열립니다. */
    void editNas() {
        boolean joined = !prefs.getString("nasKey", "").isEmpty();
        EditText invite = ui.field(joined ? "새 초대 코드 · 다시 연결할 때만" : "초대 코드");
        invite.setSingleLine(true);
        invite.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS);
        String now = relayText == null ? (joined ? "서버에 연결하는 중입니다." : "받은 초대 코드를 입력하세요.") : relayText;
        TextView state = ui.text(now, 12, nasState() == 2 ? ui.on : ui.faint, Ui.REGULAR);
        TextView note = ui.text("연결하면 앱이 열려 있는 동안 자동으로 서버에 연결됩니다.", 12, ui.faint, Ui.REGULAR);
        AlertDialog d = ui.dialog().setTitle(joined ? "서버" : "아나 시작하기").setView(ui.dialogBody(invite, state, note))
                .setPositiveButton("연결", null).setNegativeButton(joined ? "닫기" : "나중에", null).create();
        ui.show(d, false);
        d.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            String code = invite.getText().toString().trim();
            if (code.isEmpty()) { invite.requestFocus(); return; }
            d.dismiss();
            work(() -> {
                String k = join(code);
                RelayBridge.validate(Brand.SERVER, k, false);
                prefs.edit().putString("nasKey", encrypt(k)).putBoolean("nasEnabled", true).commit();
                startRelay();
                runOnUiThread(() -> { updateSettingsValues(); showAddresses(); });
                status("서버에 연결했습니다.");
            });
        });
    }

    void editNasLegacy() {
        EditText address = ui.field("서버 HTTPS 주소");
        address.setSingleLine(true);
        address.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        address.setText(nasAddress());
        EditText key = ui.field(prefs.getString("nasKey", "").isEmpty() ? "연결 키" : "연결 키 · 바꿀 때만 입력");
        key.setSingleLine(true);
        key.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        String now = relayText == null ? (prefs.getString("nasKey", "").isEmpty() ? "연결 키를 처음 한 번 입력하세요." : "서버에 연결하는 중입니다.") : relayText;
        TextView state = ui.text(now, 12, nasState() == 2 ? ui.on : ui.faint, Ui.REGULAR);
        TextView note = ui.text("설정 후 자동으로 서버에 연결됩니다. 기기간 직접 연결은 사용하지 않습니다.", 12, ui.faint, Ui.REGULAR);
        AlertDialog d = ui.dialog().setTitle("서버").setView(ui.dialogBody(address, key, state, note))
                .setPositiveButton("저장", null).setNegativeButton("취소", null).create();
        ui.show(d, false);
        d.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            String url = address.getText().toString(), input = key.getText().toString();
            d.dismiss();
            work(() -> {
                String k = input.isEmpty() ? keyFromSaved() : input;
                RelayBridge.validate(url, k, false);
                prefs.edit().putString("nasKey", encrypt(k)).putString("nasAddress", url).putBoolean("nasEnabled", true).commit();
                startRelay();
                runOnUiThread(() -> { updateSettingsValues(); showAddresses(); });
                status("서버 설정을 저장했습니다.");
            });
        });
    }

    void chooseFolder() {
        String[] items = {"폴더 선택…", "기본 위치 (Downloads/Ahna)"};
        AlertDialog d = ui.dialog().setTitle("받은 파일 저장 위치").setItems(items, (dialog, which) -> {
            if (which == 0) {
                try {
                    startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION | Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION), 2);
                } catch (Exception e) { status("폴더를 고를 수 있는 앱이 없습니다."); }
            } else {
                prefs.edit().remove("folder").apply();
                updateSettingsValues();
                status("Downloads/Ahna에 저장합니다.");
            }
        }).setNegativeButton("취소", null).create();
        ui.show(d, false);
    }

    void confirmRevoke() {
        AlertDialog d = ui.dialog().setTitle("모든 기기를 해제할까요?")
                .setMessage("이 기기에 연결한 모든 기기가 다시 코드를 입력해야 합니다. 이 기기의 연결 코드도 새로 만들어집니다.")
                .setPositiveButton("해제", (dialog, w) -> work(() -> {
                    if (server == null) throw new IOException("수신 기능이 준비되지 않았습니다.");
                    server.revoke();
                    if (!prefs.getString("nasKey", "").isEmpty()) startRelay();
                    runOnUiThread(this::showAddresses);
                    status("모든 기기를 해제했습니다. 새 코드: " + Ui.code(server.pin));
                }))
                .setNegativeButton("취소", null).create();
        ui.show(d, true);
    }

    void addDevice() {
        String url = nasAddress(), code = pin.getText().toString();
        work(() -> {
            Client c = new Client(new JSONObject().put("address", url));
            // 한 번의 코드 입력으로 양쪽 연결: 이 기기 쪽 연결을 함께 보내고, 상대가 저장했다고 답하면 유지합니다.
            JSONObject offer = null;
            if (server != null && !prefs.getString("nasKey", "").isEmpty()) try { offer = server.reverseOffer(url); } catch (Exception ignored) {}
            boolean accepted = false, paired = false;
            try { accepted = c.pair(code, deviceName(), identity(), offer); paired = true; }
            finally { if (offer != null && server != null) server.completeReverse(offer.optString("token"), paired && accepted, c.profile.optString("hostName", ""), c.profile.optString("computerID", "")); }
            rememberPlatform(c);
            clients.removeIf(old -> old.profile.optString("address").equals(url) && old.profile.optString("computerID").equals(c.profile.optString("computerID")));
            clients.add(c);
            saveClients();
            runOnUiThread(() -> { pin.setText(""); updateTargets(); });
            status("기기를 추가했습니다. 공유 메뉴에서도 바로 선택할 수 있습니다.");
        });
    }

    /** 그 기기가 이 기기에 연결한 쪽(수신 세션)이 남아 있는지. */
    boolean hasInbound(Client c) {
        try { if (server == null) return false; JSONArray a = server.peers(); for (int i = 0; i < a.length(); i++) if (sameDevice(a.getJSONObject(i), c)) return true; }
        catch (Exception ignored) {}
        return false;
    }

    /**
     * 다른 기기가 이 기기의 연결 코드로 연결하면서 넘겨준 그 기기 쪽 연결을, 그 기기를 직접 추가한 것과 같게 저장합니다.
     * 같은 기기(수신 ID)가 이미 있으면 주소·인증 값만 바꿉니다. 공유 창(ShareActivity)도 같은 저장소를 읽습니다.
     */
    void addReverse(JSONObject credential) throws Exception {
        String cid = credential.getString("computerID");
        synchronized (clients) {
            int index = -1;
            for (int i = 0; i < clients.size(); i++) if (clients.get(i).profile.optString("computerID", "").equalsIgnoreCase(cid)) { index = i; break; }
            JSONObject next = index >= 0 ? new JSONObject(clients.get(index).profile.toString()) : new JSONObject();
            next.put("address", credential.getString("address")).put("computerID", cid).put("token", credential.getString("token"));
            if (next.optString("hostName", "").isEmpty()) next.put("hostName", credential.getString("name"));
            if (index >= 0) clients.set(index, new Client(next)); else clients.add(new Client(next));
            saveClients();
        }
        runOnUiThread(() -> { if (!closed) updateTargets(); });
    }

    void updateSettingsValues() {
        if (nameValue == null) return;
        nameValue.setText(deviceName());
        boolean key = !prefs.getString("nasKey", "").isEmpty();
        nasValue.setText(key ? "연결됨" : "초대 코드 필요");
        folderValue.setText(folderLabel());
        if (historyFolder != null) historyFolder.setText(folderLabel());
        String latest = prefs.getString("updateLatest", "");
        String v = version.isEmpty() ? "" : "v" + version;
        String state = latest.isEmpty() ? "" : UpdateCheck.newer(latest, version) ? "새 버전 v" + latest.replaceFirst("^[vV]", "") + " 있음" : "최신 버전입니다";
        updateValue.setText(v.isEmpty() ? state : state.isEmpty() ? v : v + " · " + state);
        updateValue.setTextColor(state.startsWith("새 버전") ? ui.accent : ui.faint);
    }

    String folderLabel() {
        String folder = prefs.getString("folder", null);
        if (folder == null) return "Downloads/Ahna";
        try {
            String id = DocumentsContract.getTreeDocumentId(Uri.parse(folder));
            int colon = id.indexOf(':');
            String path = colon >= 0 ? id.substring(colon + 1) : id;
            return path.isEmpty() ? "선택한 폴더" : path;
        } catch (Exception e) { return "선택한 폴더"; }
    }

    // =====================================================================================
    // Lists
    // =====================================================================================

    static String clientKey(Client c) { return c.profile.optString("computerID", c.profile.optString("address")); }
    static String platformOf(Client c) {
        JSONObject s = c.state;
        String p = s == null ? "" : s.optString("platform", "");
        return p.isEmpty() ? c.profile.optString("platform", "") : p;
    }
    void rememberPlatform(Client c) {
        try { JSONObject s = c.state; String p = s == null ? "" : s.optString("platform", ""); if (!p.isEmpty()) c.profile.put("platform", p); } catch (Exception ignored) {}
    }
    void prefetchClips(Client c) {
        try {
            JSONObject s = c.state;
            JSONArray a = s == null ? null : s.optJSONArray("clipboard");
            if (a == null) return;
            for (int i = 0; i < a.length(); i++) {
                JSONObject item = a.optJSONObject(i);
                if (item == null) continue;
                String id = item.optString("id"), key = clientKey(c) + ":" + id;
                if (clipCache.containsKey(key)) continue;
                String value;
                try { value = c.clipboard(id); } catch (Exception e) { value = null; }
                clipCache.put(key, value == null ? "" : value);
            }
        } catch (Exception ignored) {}
    }

    /** 보낼 기기로 근처 기기를 골랐으면 그 기기 */
    NearbyRadio.Device nearTarget() {
        if (nearby == null || !targetKey.startsWith("near:") || !nearby.available()) return null;
        return nearby.device(targetKey.substring(5));
    }

    Target selectedTarget() {
        for (Target t : targets) if (t.id.equals(targetKey)) return t;
        return null;
    }

    static String trimName(String value) { return value == null ? "" : value.trim(); }
    /** Same device: by the identity the device reported, or by name for 1.0.x apps that report none. */
    static boolean sameDevice(JSONObject peer, Client c) {
        String cid = peer.optString("computerID", "");
        if (!cid.isEmpty()) return cid.equalsIgnoreCase(c.profile.optString("computerID", ""));
        return trimName(peer.optString("name", "")).equals(trimName(c.profile.optString("hostName", "")));
    }

    void updateTargets() {
        updateNasViews();
        if (targetBox == null) return;
        List<Target> all = new ArrayList<>();
        try {
            List<JSONObject> peers = new ArrayList<>();
            if (server != null) { JSONArray a = server.peers(); for (int i = 0; i < a.length(); i++) peers.add(a.getJSONObject(i)); }
            Set<String> claimed = new HashSet<>();
            for (Client c : new ArrayList<>(clients)) {
                Target t = new Target();
                t.connection = c; t.id = "client:" + clientKey(c); t.name = c.profile.optString("hostName", "기기");
                t.platform = platformOf(c);
                String live = null;
                for (JSONObject p : peers) if (sameDevice(p, c)) { claimed.add(p.optString("id")); t.peerIDs.add(p.optString("id")); if (live == null && p.optBoolean("online")) live = p.optString("id"); }
                boolean up = c.state != null;
                t.online = up || live != null;
                // 추가한 연결이 기본. 그쪽이 오프라인인데 상대가 이 기기에서 받는 중이면 이 기기의 전송 대기열로 보냅니다.
                if (!up && live != null) t.hostPeer = live; else t.client = c;
                all.add(t);
            }
            Map<String, List<JSONObject>> groups = new java.util.LinkedHashMap<>();
            for (JSONObject p : peers) {
                String cid = p.optString("computerID", "");
                if (claimed.contains(p.optString("id")) || cid.isEmpty()) continue;
                groups.computeIfAbsent("c:" + cid.toLowerCase(java.util.Locale.ROOT), k -> new ArrayList<>()).add(p);
            }
            for (JSONObject p : peers) {
                if (claimed.contains(p.optString("id")) || !p.optString("computerID", "").isEmpty()) continue;
                String key = "n:" + trimName(p.optString("name", ""));
                for (Map.Entry<String, List<JSONObject>> e : groups.entrySet()) if (trimName(e.getValue().get(0).optString("name", "")).equals(trimName(p.optString("name", "")))) { key = e.getKey(); break; }
                groups.computeIfAbsent(key, k -> new ArrayList<>()).add(p);
            }
            for (List<JSONObject> members : groups.values()) {
                Target t = new Target();
                JSONObject live = null;
                for (JSONObject p : members) { t.peerIDs.add(p.optString("id")); if (live == null && p.optBoolean("online")) live = p; }
                Collections.sort(t.peerIDs);
                JSONObject shown = live != null ? live : members.get(0);
                t.id = "host:" + t.peerIDs.get(0); t.name = shown.optString("name", "기기"); t.platform = ""; t.online = live != null; t.hostPeer = shown.optString("id");
                all.add(t);
            }
        } catch (Exception ignored) {}
        linked.clear();
        linked.addAll(all);
        // 보낼 기기: 추가한 기기는 늘, 이 기기에만 연결한 기기는 지금 받을 수 있을 때만 보입니다.
        List<Target> next = new ArrayList<>();
        for (Target t : all) if (t.connection != null || t.online) next.add(t);
        targets.clear();
        targets.addAll(next);
        boolean nearSelected = targetKey.startsWith("near:") && nearby != null && nearby.available() && nearby.device(targetKey.substring(5)) != null;
        if (selectedTarget() == null && !nearSelected) {
            targetKey = "";
            for (Target t : targets) if (t.online) { targetKey = t.id; break; }
            if (targetKey.isEmpty() && !targets.isEmpty()) targetKey = targets.get(0).id;
        }
        StringBuilder print = new StringBuilder(targetKey);
        for (Target t : targets) print.append('|').append(t.id).append('/').append(t.name).append('/').append(t.online).append('/').append(t.platform);
        if (!print.toString().equals(targetPrint)) { targetPrint = print.toString(); renderTargets(); }
        renderSendButton();
        renderConnections();
        if (nearby != null) nearby.renderTargets();
    }

    void renderTargets() {
        targetBox.removeAllViews();
        if (targets.isEmpty()) {
            Button add = ui.button("옵션에서 기기 추가", ui.surface, ui.muted, ui.border, 12, 14, Ui.REGULAR);
            add.setBackground(ui.pressable(ui.dashed(ui.surface, 12, ui.borderStrong, 1), 12));
            add.setPadding(dp(14), 0, dp(14), 0);
            add.setOnClickListener(v -> selectTab(1));
            targetBox.addView(add, tablet ? ui.lp(-1, 56, 0, 4, 0, 0) : ui.lp(-2, 48));
            return;
        }
        for (int i = 0; i < targets.size(); i++) {
            final Target t = targets.get(i);
            boolean selected = t.id.equals(targetKey);
            LinearLayout item = ui.row();
            int fg = t.online ? ui.text : ui.muted;
            if (selected) item.setBackground(ui.pressable(ui.round(ui.accentSoft, 12, ui.accent, 2), 12));
            else item.setBackground(ui.pressable(ui.round(ui.surface, 12, ui.border, 1), 12));
            String icon = Ui.deviceIcon(t.platform);
            if (tablet) {
                item.setPadding(dp(12), dp(8), dp(12), dp(8));
                item.setMinimumHeight(dp(56));
                item.addView(ui.icon(icon, selected ? ui.accent : t.online ? ui.muted : ui.faint), ui.lp(20, 20, 0, 0, 12, 0));
                item.addView(Ui.oneLine(ui.text(t.name, 14, fg, Ui.MEDIUM)), ui.flex(1));
                item.addView(ui.dot(t.online), ui.lp(7, 7, 8, 0, 5, 0));
                item.addView(ui.text(t.online ? "연결됨" : "오프라인", 12, t.online ? ui.on : ui.faint, t.online ? Ui.MEDIUM : Ui.REGULAR));
                targetBox.addView(item, ui.lp(-1, -2, 0, i == 0 ? 4 : 8, 0, 0));
            } else {
                item.setPadding(dp(14), 0, dp(14), 0);
                item.addView(ui.icon(icon, fg), ui.lp(18, 18, 0, 0, 8, 0));
                TextView name = ui.text(t.name, 14, fg, selected ? Ui.MEDIUM : Ui.REGULAR);
                name.setMaxWidth(dp(180));
                item.addView(Ui.oneLine(name));
                item.addView(ui.dot(t.online), ui.lp(8, 8, 8, 0, 0, 0));
                targetBox.addView(item, ui.lp(-2, 48, i == 0 ? 0 : 8, 0, 0, 0));
            }
            item.setClickable(true); item.setFocusable(true);
            item.setSelected(selected);
            item.setContentDescription(t.name + ", " + (t.online ? "연결됨" : "오프라인") + (selected ? ", 선택됨" : ""));
            item.setOnClickListener(v -> { targetKey = t.id; targetPrint = ""; updateTargets(); });
        }
    }

    void renderSendButton() {
        if (sendButton == null) return;
        Target t = selectedTarget();
        NearbyRadio.Device near = nearTarget();
        String label;
        if (near != null) {
            label = pending.isEmpty() ? Ui.toward(near.name) + " 보내기" : Ui.toward(near.name) + " " + pending.size() + "개 보내기";
            sendButton.setText(label);
            sendButton.setAlpha(pending.isEmpty() ? 0.55f : 1f);
            return;
        }
        if (t == null) label = "받을 기기를 먼저 추가하세요";
        else if (pending.isEmpty()) label = Ui.toward(t.name) + " 보내기";
        else label = Ui.toward(t.name) + " " + pending.size() + "개 보내기";
        sendButton.setText(label);
        sendButton.setAlpha(t == null || pending.isEmpty() ? 0.55f : 1f);
    }

    void renderConnections() {
        if (connections == null) return;
        StringBuilder print = new StringBuilder();
        for (Target t : linked) print.append('|').append(t.id).append('/').append(t.name).append('/').append(t.online).append('/').append(t.platform).append('/').append(t.peerIDs).append('/').append(t.connection != null && t.connection.revoked);
        if (print.toString().equals(connectionPrint)) return;
        connectionPrint = print.toString();
        connections.removeAllViews();
        List<Target> list = new ArrayList<>(linked);
        if (list.isEmpty()) {
            connections.addView(ui.divider());
            TextView empty = ui.text("아직 연결한 기기가 없습니다. 기기 추가에서 상대 기기의 코드를 입력하세요.", 13, ui.faint, Ui.REGULAR);
            empty.setPadding(0, dp(12), 0, dp(12));
            connections.addView(empty);
            return;
        }
        for (int i = 0; i < list.size(); i++) {
            final Target t = list.get(i);
            final Client c = t.connection;
            boolean online = t.online;
            String name = c != null ? c.profile.optString("hostName", c.profile.optString("address")) : t.name;
            String platform = t.platform;
            if (tablet || i > 0) connections.addView(ui.divider());
            LinearLayout row = ui.row();
            row.setPadding(0, dp(12), 0, dp(12));
            row.addView(ui.tile(Ui.deviceIcon(platform), 10, 20, online ? ui.accentSoft : ui.subtle, online ? ui.accent : ui.faint), ui.lp(40, 40, 0, 0, 12, 0));
            LinearLayout texts = ui.column();
            texts.addView(Ui.oneLine(ui.text(name, 14, online ? ui.text : ui.muted, Ui.MEDIUM)));
            LinearLayout state = ui.row();
            state.addView(ui.dot(online), ui.lp(7, 7, 0, 0, 5, 0));
            // 이름과 상태만: 오프라인이고 상대가 연결을 해제했을 때만 그 이유 한 줄.
            String detail = online ? "연결됨" + (platform.isEmpty() ? "" : " · " + platform) : c != null && c.revoked ? Client.REVOKED : "오프라인";
            state.addView(Ui.oneLine(ui.text(detail, 12, online ? ui.on : ui.faint, online ? Ui.MEDIUM : Ui.REGULAR)));
            texts.addView(state);
            row.addView(texts, ui.flex(1));
            FrameLayout delete = new FrameLayout(this);
            delete.addView(ui.tile("close_bold", -1, 12, ui.dangerSoft, ui.danger), new FrameLayout.LayoutParams(dp(26), dp(26), Gravity.CENTER));
            delete.setBackground(ui.pressable(null, 22));
            delete.setClickable(true); delete.setFocusable(true);
            delete.setContentDescription(name + " 연결 삭제");
            delete.setOnClickListener(v -> {
                AlertDialog d = ui.dialog().setTitle(name + " 연결 삭제").setMessage("이 기기의 연결을 삭제할까요? 다시 연결하려면 상대 기기의 코드를 입력해야 합니다.")
                        .setPositiveButton("삭제", (dialog, w) -> work(() -> {
                            // 이 기기가 추가한 연결과, 그 기기가 이 기기에 연결한 세션을 함께 지웁니다.
                            if (c != null) {
                                try { c.request("/api/logout", new JSONObject()); } catch (Exception ignored) {}
                                clients.remove(c);
                                saveClients();
                            }
                            if (server != null && !t.peerIDs.isEmpty()) server.forget(new ArrayList<>(t.peerIDs));
                        }))
                        .setNegativeButton("취소", null).create();
                ui.show(d, true);
            });
            row.addView(delete, ui.lp(44, 44));
            connections.addView(row, new LinearLayout.LayoutParams(-1, -2));
        }
    }

    static final class ClipEntry { String sender, key; long at; String preview; TextWork fetch; }

    void updateInbox() {
        if (inbox == null) return;
        List<ClipEntry> entries = new ArrayList<>();
        Set<String> live = new HashSet<>();
        try {
            if (server != null) {
                JSONArray a = server.clipboard();
                for (int i = 0; i < a.length(); i++) {
                    JSONObject item = a.getJSONObject(i);
                    final String id = item.getString("id");
                    ClipEntry e = new ClipEntry();
                    e.sender = item.optString("sender"); e.key = "host:" + id; e.at = parseTime(item.optString("created"));
                    String text = server.clipboardText(id);
                    e.preview = text == null ? "" : text;
                    e.fetch = () -> server.clipboardText(id);
                    entries.add(e);
                }
            }
            for (Client c : new ArrayList<>(clients)) {
                JSONObject s = c.state;
                if (s == null) continue;
                JSONArray a = s.optJSONArray("clipboard");
                if (a == null) continue;
                for (int i = 0; i < a.length(); i++) {
                    JSONObject item = a.getJSONObject(i);
                    final String id = item.getString("id");
                    ClipEntry e = new ClipEntry();
                    e.sender = item.optString("sender"); e.key = clientKey(c) + ":" + id; e.at = parseTime(item.optString("created"));
                    String cached = clipCache.get(e.key);
                    e.preview = cached == null ? "" : cached;
                    e.fetch = () -> c.clipboard(id);
                    live.add(e.key);
                    entries.add(e);
                }
            }
        } catch (Exception ignored) {}
        clipCache.keySet().retainAll(live);
        Collections.sort(entries, (x, y) -> Long.compare(y.at, x.at));
        StringBuilder print = new StringBuilder();
        for (ClipEntry e : entries) print.append('|').append(e.key).append('/').append(e.preview.length()).append('/').append(Ui.ago(e.at));
        if (print.toString().equals(inboxPrint)) return;
        inboxPrint = print.toString();
        inbox.removeAllViews();
        if (entries.isEmpty()) {
            TextView empty = ui.text("아직 받은 글자가 없습니다. 다른 기기에서 글자를 보내면 여기에 나타납니다.", 13, ui.faint, Ui.REGULAR);
            empty.setPadding(0, dp(6), 0, dp(6));
            inbox.addView(empty);
            return;
        }
        for (int i = 0; i < entries.size(); i++) {
            ClipEntry e = entries.get(i);
            if (i > 0) inbox.addView(ui.divider());
            LinearLayout row = ui.row();
            row.setPadding(0, dp(10), 0, dp(10));
            LinearLayout texts = ui.column();
            String when = Ui.ago(e.at);
            texts.addView(Ui.oneLine(ui.text(e.sender + (when.isEmpty() ? "" : " · " + when), 12, ui.faint, Ui.REGULAR)));
            String preview = e.preview.replace('\n', ' ').trim();
            texts.addView(Ui.oneLine(ui.text(preview.isEmpty() ? "받은 글자" : preview, 14, ui.text, Ui.REGULAR)));
            row.addView(texts, ui.flex(1));
            Button copy = ui.soft("복사");
            copy.setPadding(dp(14), 0, dp(14), 0);
            copy.setContentDescription(e.sender + "에게서 받은 글자 복사");
            final TextWork fetch = e.fetch;
            copy.setOnClickListener(v -> copyReceived(fetch));
            row.addView(copy, ui.lp(-2, 36, 10, 0, 0, 0));
            inbox.addView(row, new LinearLayout.LayoutParams(-1, -2));
        }
    }

    static long parseTime(String iso) {
        if (iso == null || iso.isEmpty()) return 0;
        try { return Instant.parse(iso).toEpochMilli(); } catch (Exception ignored) {}
        try { return java.time.OffsetDateTime.parse(iso).toInstant().toEpochMilli(); } catch (Exception ignored) {}
        return 0;
    }

    interface TextWork { String run() throws Exception; }

    void copyReceived(TextWork fetch) {
        work(() -> {
            String value = fetch.run();
            if (value == null) throw new IOException("보관 기간이 지났습니다.");
            runOnUiThread(() -> {
                ClipboardManager cb = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
                if (cb != null) cb.setPrimaryClip(ClipData.newPlainText("아나", value));
                status("복사했습니다.");
            });
        });
    }

    synchronized void rememberReceived(String display, Uri uri, String from, long bytes) {
        try {
            JSONArray old = new JSONArray(prefs.getString("receivedHistory060", "[]")), next = new JSONArray();
            JSONObject entry = new JSONObject().put("name", display).put("uri", uri.toString()).put("at", System.currentTimeMillis()).put("bytes", bytes);
            if (from != null && !from.isEmpty()) entry.put("from", from);
            next.put(entry);
            for (int j = 0; j < old.length() && next.length() < 10; j++) next.put(old.getJSONObject(j));
            prefs.edit().putString("receivedHistory060", next.toString()).apply();
            runOnUiThread(this::updateHistory);
        } catch (Exception ignored) {}
    }

    static boolean isImageName(String name) {
        String n = name.toLowerCase(java.util.Locale.ROOT);
        for (String ext : new String[]{".jpg", ".jpeg", ".png", ".gif", ".heic", ".heif", ".webp", ".bmp", ".dng"}) if (n.endsWith(ext)) return true;
        return false;
    }

    void updateHistory() {
        if (historyBox == null) return;
        historyBox.removeAllViews();
        try {
            JSONArray list = new JSONArray(prefs.getString("receivedHistory060", "[]"));
            for (int j = 0; j < list.length() && j < 10; j++) {
                JSONObject item = list.getJSONObject(j);
                String name = item.optString("name", "파일");
                if (j > 0) historyBox.addView(ui.divider());
                LinearLayout row = ui.row();
                row.setPadding(0, dp(8), 0, dp(8));
                float box = tablet ? 36 : 34;
                row.addView(ui.tile(isImageName(name) ? "image" : "file", tablet ? 9 : 8, 16, ui.subtle, ui.muted), ui.lp(box, box, 0, 0, 10, 0));
                LinearLayout texts = ui.column();
                texts.addView(Ui.oneLine(ui.text(name, 13, ui.text, Ui.MEDIUM)));
                List<String> meta = new ArrayList<>();
                if (!item.optString("from").isEmpty()) meta.add(item.optString("from"));
                String when = Ui.ago(item.optLong("at", 0));
                if (!when.isEmpty()) meta.add(when);
                String size = Ui.size(item.optLong("bytes", -1));
                if (!size.isEmpty()) meta.add(size);
                if (!meta.isEmpty()) texts.addView(Ui.oneLine(ui.text(String.join(" · ", meta), 12, ui.faint, Ui.REGULAR)));
                row.addView(texts, ui.flex(1));
                Button open = ui.plain("열기");
                open.setContentDescription(name + " 열기");
                open.setOnClickListener(v -> {
                    try { startActivity(new Intent(Intent.ACTION_VIEW).setDataAndType(Uri.parse(item.optString("uri")), "*/*").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)); }
                    catch (Exception ex) { status("파일 앱에서 저장한 파일을 확인하세요."); }
                });
                row.addView(open, ui.lp(-2, 36, 10, 0, 0, 0));
                historyBox.addView(row, new LinearLayout.LayoutParams(-1, -2));
            }
            if (list.length() == 0) {
                TextView empty = ui.text("아직 받은 파일 기록이 없습니다.", 13, ui.faint, Ui.REGULAR);
                empty.setPadding(0, dp(6), 0, dp(6));
                historyBox.addView(empty);
            }
        } catch (Exception ignored) {}
    }

    /** name, size text, "image" or "file" */
    String[] meta(Uri uri) {
        String[] m = pendingMeta.get(uri);
        if (m != null) return m;
        String name = "파일", size = "";
        try (Cursor cursor = getContentResolver().query(uri, new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                if (!cursor.isNull(0)) name = cursor.getString(0);
                if (!cursor.isNull(1)) size = Ui.size(cursor.getLong(1));
            }
        } catch (Exception ignored) {}
        String type = null;
        try { type = getContentResolver().getType(uri); } catch (Exception ignored) {}
        boolean image = type != null ? type.startsWith("image/") : isImageName(name);
        m = new String[]{name, size, image ? "image" : "file"};
        pendingMeta.put(uri, m);
        return m;
    }

    void renderPending() {
        if (pendingBox == null) return;
        pendingBox.removeAllViews();
        pendingMeta.keySet().retainAll(pending);
        for (int i = 0; i < pending.size(); i++) {
            final Uri uri = pending.get(i);
            String[] m = meta(uri);
            if (i > 0) pendingBox.addView(ui.divider());
            LinearLayout row = ui.row();
            row.setPadding(0, dp(4), 0, dp(4));
            row.addView(ui.tile(m[2], 8, 16, ui.accentSoft, ui.accent), ui.lp(34, 34, 0, 0, 10, 0));
            LinearLayout texts = ui.column();
            texts.addView(Ui.oneLine(ui.text(m[0], 13, ui.text, Ui.MEDIUM)));
            if (!m[1].isEmpty()) texts.addView(ui.text(m[1], 12, ui.faint, Ui.REGULAR));
            row.addView(texts, ui.flex(1));
            FrameLayout remove = ui.iconButton("close", 16, ui.muted, m[0] + " 목록에서 빼기");
            remove.setOnClickListener(v -> { pending.remove(uri); renderPending(); });
            row.addView(remove, ui.lp(44, 44));
            pendingBox.addView(row, new LinearLayout.LayoutParams(-1, -2));
        }
        pendingBox.setPadding(0, pending.isEmpty() ? 0 : dp(8), 0, 0);
        renderSendButton();
    }

    void showAddresses() {
        if (server == null) return;
        if (codeView != null) { codeView.setText(Ui.code(server.pin)); codeView.setContentDescription("연결 코드 " + server.pin.replace("", " ").trim()); }
        if (deviceLine != null) deviceLine.setText("이 기기 · " + deviceName() + " · 코드 " + Ui.code(server.pin));
    }

    // =====================================================================================
    // Behaviour (unchanged logic)
    // =====================================================================================

    @Override public void onConfigurationChanged(Configuration value) { super.onConfigurationChanged(value); buildUI(); }
    @Override protected void onResume() { super.onResume(); if (nearby != null) nearby.setForeground(true); }
    @Override protected void onPause() { if (nearby != null) nearby.setForeground(false); super.onPause(); }
    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(request, permissions, results);
        if (request == NearbyUi.PERMISSION_REQUEST && nearby != null) nearby.permissionResult();
    }

    void work(Work action) {
        if (busy) { status("다른 작업이 진행 중입니다. 잠시 후 다시 누르세요."); return; }
        busy = true;
        status("처리 중…");
        jobs.execute(() -> {
            try { action.run(); }
            catch (Exception e) {
                status(e.getMessage());
                runOnUiThread(() -> {
                    if (!closed && activeTab == 1)
                        ui.show(ui.dialog().setTitle("요청을 완료하지 못했습니다").setMessage(e.getMessage() == null ? "서버 연결 상태와 상대 기기의 코드를 확인하세요." : e.getMessage()).setPositiveButton("확인", null).create(), false);
                });
            } finally { busy = false; runOnUiThread(() -> { updateTargets(); updateInbox(); }); }
        });
    }
    interface Work { void run() throws Exception; }

    String keyFromSaved() throws Exception { return decrypt(prefs.getString("nasKey", "")); }
    void startRelay() throws Exception {
        if (server == null) throw new IOException("수신 기능이 준비되지 않았습니다.");
        if (relay != null) relay.close();
        setRelayText(null);
        relay = new RelayBridge(server, nasAddress(), keyFromSaved(), this::setRelayText);
        relay.notice = (action, text) -> runOnUiThread(() -> serverNotice(action, text));
    }
    /** 서버 관리자 알림. 초기화·차단이면 연결 키를 지우고 초대 코드 입력 창을 띄웁니다. */
    void serverNotice(String action, String text) {
        boolean rejoin = "rejoin".equals(action) || "blocked".equals(action);
        if (rejoin) {
            if (relay != null) { relay.close(); relay = null; }
            prefs.edit().remove("nasKey").commit();
            setRelayText(text);
        }
        try {
            new android.app.AlertDialog.Builder(this).setTitle("아나 · 서버 알림").setMessage(text)
                .setPositiveButton(rejoin ? "초대 코드 입력" : "확인", (d, w) -> { if (rejoin) editNas(); }).show();
        } catch (Exception ignored) { status(text); }
    }
    void saveClients() throws Exception { JSONArray a = new JSONArray(); for (Client c : clients) a.put(c.profile); prefs.edit().putString("connections", encrypt(a.toString())).commit(); }

    void pickFiles() {
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        try { startActivityForResult(i, 1); } catch (Exception e) { status("파일을 고를 수 있는 앱이 없습니다."); }
    }

    void sendDraft() {
        String value = draft.getText().toString();
        if (nearTarget() != null) { status("근처 기기로는 파일만 보낼 수 있습니다. 글자는 등록한 기기로 보내세요."); return; }
        Target t = selectedTarget();
        if (t == null) { status("받을 기기를 연결하세요."); return; }
        Client c = t.client; String id = t.hostPeer;
        work(() -> { if (c == null) server.sendClipboard(value, id); else c.sendClipboard(value); status("글자를 보냈습니다. 받은 기기에서 복사하세요."); });
    }

    void showSharePicker() {
        updateTargets();
        if (targets.isEmpty()) { status("옵션에서 받을 기기를 먼저 추가하세요."); return; }
        final List<Target> list = new ArrayList<>(targets);
        String[] labels = new String[list.size()];
        for (int j = 0; j < labels.length; j++) labels[j] = list.get(j).name + (list.get(j).online ? " · 연결됨" : " · 오프라인");
        AlertDialog d = ui.dialog().setTitle("아나 · 보낼 기기").setItems(labels, (dialog, index) -> {
            targetKey = list.get(index).id; targetPrint = ""; updateTargets();
            if (pending.isEmpty()) sendDraft(); else sendFiles();
        }).setNegativeButton("취소", null).create();
        ui.show(d, false);
    }

    @Override protected void onNewIntent(Intent intent) { super.onNewIntent(intent); setIntent(intent); handleIntent(intent); }
    void handleIntent(Intent i) {
        if (Intent.ACTION_SEND.equals(i.getAction())) {
            Uri u = i.getParcelableExtra(Intent.EXTRA_STREAM);
            if (u != null) { pending.clear(); pending.add(u); }
            else if (i.hasExtra(Intent.EXTRA_TEXT)) draft.setText(i.getCharSequenceExtra(Intent.EXTRA_TEXT));
        } else if (Intent.ACTION_SEND_MULTIPLE.equals(i.getAction())) {
            ArrayList<Uri> uris = i.getParcelableArrayListExtra(Intent.EXTRA_STREAM);
            if (uris != null) { pending.clear(); pending.addAll(uris); }
        }
        renderPending();
        boolean shared = Intent.ACTION_SEND.equals(i.getAction()) || Intent.ACTION_SEND_MULTIPLE.equals(i.getAction());
        if (shared && i.getBooleanExtra(ShareActivity.EXTRA_NEARBY, false)) {
            // 공유 창의 [근처 기기 · QR]: 파일만 받아 두고 근처 기기나 QR을 고르게 합니다.
            selectTab(0);
            i.removeExtra(ShareActivity.EXTRA_NEARBY);
            status(nearby != null && nearby.available() ? "근처 기기를 고르거나 QR을 누르세요." : "QR을 누르거나 옵션에서 Bluetooth를 확인하세요.");
        } else if (shared) { selectTab(0); handler.post(this::showSharePicker); }
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (result != RESULT_OK || data == null) return;
        try {
            if (request == 2 && data.getData() != null) {
                getContentResolver().takePersistableUriPermission(data.getData(), data.getFlags() & (Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION));
                prefs.edit().putString("folder", data.getData().toString()).apply();
                updateSettingsValues();
                status("다음 파일부터 선택한 폴더에 저장합니다.");
            } else if (request == 1) {
                List<Uri> picked = new ArrayList<>();
                if (data.getClipData() != null) for (int j = 0; j < data.getClipData().getItemCount(); j++) picked.add(data.getClipData().getItemAt(j).getUri());
                else if (data.getData() != null) picked.add(data.getData());
                for (Uri u : picked) if (u != null && !pending.contains(u)) pending.add(u);
                renderPending();
            }
        } catch (Exception e) { status(e.getMessage()); }
    }

    void sendFiles() {
        NearbyRadio.Device near = nearTarget();
        if (near != null) { if (pending.isEmpty()) status("보낼 파일을 선택하세요."); else nearby.send(near.id, new ArrayList<>(pending)); return; }
        Target t = selectedTarget();
        if (t == null || pending.isEmpty()) { status(t == null ? "받을 기기를 먼저 추가하세요." : "보낼 파일을 선택하세요."); return; }
        String id = t.hostPeer; Client c = t.client; List<Uri> files = new ArrayList<>(pending);
        work(() -> {
            int done = 0;
            for (Uri uri : files) {
                String display = "파일";
                try (Cursor cursor = getContentResolver().query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) { if (cursor != null && cursor.moveToFirst() && cursor.getString(0) != null) display = cursor.getString(0); }
                display = Protocol.safeName(display);
                File staged = File.createTempFile("send-", ".part", getCacheDir());
                try {
                    try (InputStream in = getContentResolver().openInputStream(uri); OutputStream out = new FileOutputStream(staged)) {
                        if (in == null) throw new IOException("파일을 열 수 없습니다.");
                        byte[] buffer = new byte[65536]; long total = 0; int n;
                        while ((n = in.read(buffer)) >= 0) { total += n; if (total > Protocol.MAX) throw new IOException("파일 한 개는 최대 4 GiB입니다."); out.write(buffer, 0, n); }
                    }
                    if (c == null) server.queue(staged, display, id); else c.send(staged, display);
                    done++;
                    status(done + "/" + files.size() + "개 " + (c == null ? "전송 준비 완료 · 상대 저장 대기" : "상대 기기 저장 완료"));
                } finally { staged.delete(); }
            }
            runOnUiThread(() -> { pending.removeAll(files); renderPending(); });
        });
    }

    void receive(Client c) throws Exception {
        JSONArray a = c.state.getJSONArray("items");
        for (int i = 0; i < a.length(); i++) {
            JSONObject item = a.getJSONObject(i);
            String key = "saved:" + clientKey(c) + ":" + c.state.getString("id") + ":" + item.getString("id");
            if (!prefs.getBoolean(key, false)) {
                File temp = File.createTempFile("receive-", ".part", getCacheDir());
                try { c.download(item, temp); export(temp, Protocol.safeName(item.getString("name")), c.profile.optString("hostName", "")); prefs.edit().putBoolean(key, true).commit(); }
                finally { temp.delete(); }
            }
            if (!receiptPending.contains(key)) { try { c.receipt(item.getString("id")); receiptPending.add(key); } catch (Exception ignored) {} }
        }
    }

    synchronized void export(File file, String display, String from) throws Exception {
        Protocol.safeName(display);
        long bytes = file.length();
        Uri destination = null; String folder = prefs.getString("folder", null); boolean published = false;
        try {
            if (folder != null) {
                Uri tree = Uri.parse(folder);
                destination = DocumentsContract.createDocument(getContentResolver(), DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree)), "application/octet-stream", display);
            } else {
                ContentValues values = new ContentValues();
                values.put(MediaStore.MediaColumns.DISPLAY_NAME, display);
                values.put(MediaStore.MediaColumns.MIME_TYPE, "application/octet-stream");
                values.put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/Ahna");
                values.put(MediaStore.MediaColumns.IS_PENDING, 1);
                destination = getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
            }
            if (destination == null) throw new IOException("저장할 파일을 만들지 못했습니다.");
            try (InputStream in = new FileInputStream(file); OutputStream out = getContentResolver().openOutputStream(destination, "w")) {
                if (out == null) throw new IOException("저장 폴더에 쓸 수 없습니다.");
                Protocol.copy(in, out, file.length());
            }
            if (folder == null) { ContentValues values = new ContentValues(); values.put(MediaStore.MediaColumns.IS_PENDING, 0); getContentResolver().update(destination, values, null, null); }
            published = true;
            rememberReceived(display, destination, from, bytes);
            status(display + " · 저장 완료");
        } finally {
            if (!published && destination != null) try { if (folder == null) getContentResolver().delete(destination, null, null); else DocumentsContract.deleteDocument(getContentResolver(), destination); } catch (Exception ignored) {}
        }
    }

    String encrypt(String value) throws Exception { return Vault.encrypt(value); }
    String decrypt(String value) throws Exception { return Vault.decrypt(value); }

    @Override protected void onDestroy() {
        closed = true;
        handler.removeCallbacks(poll);
        handler.removeCallbacks(hideSnack);
        prefs.unregisterOnSharedPreferenceChangeListener(prefsListener);
        if (nearby != null) nearby.close();
        if (relay != null) relay.close();
        if (server != null) try { server.close(); } catch (Exception ignored) {}
        jobs.shutdownNow();
        super.onDestroy();
    }
}
