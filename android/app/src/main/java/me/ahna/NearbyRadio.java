package me.ahna;

import android.Manifest;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattServer;
import android.bluetooth.BluetoothGattServerCallback;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.le.AdvertiseCallback;
import android.bluetooth.le.AdvertiseData;
import android.bluetooth.le.AdvertiseSettings;
import android.bluetooth.le.BluetoothLeAdvertiser;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanFilter;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.location.LocationManager;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.ParcelUuid;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 아나 1.2 근처 기기(Bluetooth LE) — ios/Ahna/Nearby.swift(NearbyRadio)와 같은 규약.
 * 서비스 A4A10001-…, card(읽기) A4A10002-…, inbox(쓰기, 응답 있음, ≤512바이트) A4A10003-…
 * 받는 쪽: '10분 동안 모두'일 때만 광고하고 GATT 서비스를 엽니다(앱이 화면에 있을 때만).
 * 보내는 쪽: 앱이 화면에 있고 Bluetooth가 켜져 있으면 서비스 UUID로 찾고, 연결해 card를 읽어 이름을 보여 줍니다.
 * 모든 상태는 전용 스레드(handler) 안에서만 바꿉니다. 알림(Listener)은 그 스레드에서 부르니 화면은 runOnUiThread로 옮기세요.
 */
final class NearbyRadio {
    static final UUID SERVICE = UUID.fromString("A4A10001-4B2C-4F6D-9E3A-5C8B2D1F0A61");
    static final UUID CARD = UUID.fromString("A4A10002-4B2C-4F6D-9E3A-5C8B2D1F0A61");
    static final UUID INBOX = UUID.fromString("A4A10003-4B2C-4F6D-9E3A-5C8B2D1F0A61");
    static final int MAX_OFFER = 512;

    enum State { UNKNOWN, UNSUPPORTED, UNAUTHORIZED, OFF, LOCATION_OFF, ON }

    /** 근처에서 찾은 아나 기기(card를 읽은 기기만) */
    static final class Device {
        final String id, name, platform; final int rssi;
        /** "아주 가까움": -60 이상이면 켜지고 -66 아래로 내려가야 꺼집니다(경계에서 깜빡이지 않게). */
        final boolean near;
        Device(String id, String name, String platform, int rssi, boolean near) { this.id = id; this.name = name; this.platform = platform; this.rssi = rssi; this.near = near; }
        String proximity() { return near ? "아주 가까움" : "가까움"; }
        String print() { return id + "/" + name + "/" + platform + "/" + near; }
    }

    /** inbox에 쓰는 보내기 제안 {v,t:"offer",name,platform,code,count,bytes,summary,url} */
    static final class Offer {
        final String name, platform, code, summary, url; final int count; final long bytes;
        Offer(String name, String platform, String code, int count, long bytes, String summary, String url) {
            this.name = name; this.platform = platform; this.code = code; this.count = count; this.bytes = bytes; this.summary = summary; this.url = url;
        }
        /** 512바이트를 넘지 않게 이름·요약을 줄여 JSON으로 만듭니다. */
        byte[] json() {
            byte[] data = encode(name, summary);
            if (data.length > MAX_OFFER) data = encode(name.length() > 16 ? name.substring(0, 16) : name, summary.length() > 12 ? summary.substring(0, 12) : summary);
            return data;
        }
        private byte[] encode(String n, String s) {
            try {
                return new JSONObject().put("v", 1).put("t", "offer").put("name", n).put("platform", platform).put("code", code)
                        .put("count", count).put("bytes", bytes).put("summary", s).put("url", url).toString().getBytes(StandardCharsets.UTF_8);
            } catch (Exception e) { return new byte[0]; }
        }
        static Offer parse(byte[] data) {
            try {
                if (data == null || data.length > MAX_OFFER) return null;
                JSONObject input = new JSONObject(Protocol.strictUTF8(data));
                if (input.optInt("v", 0) != 1 || !"offer".equals(input.optString("t"))) return null;
                String code = input.optString("code", ""), url = input.optString("url", "");
                if (!code.matches("[0-9]{2}") || !validURL(url)) return null;
                int count = Math.max(0, Math.min(input.optInt("count", 0), 10000));
                long bytes = Math.max(0, input.optLong("bytes", 0));
                return new Offer(Protocol.cleanName(input.optString("name", ""), "근처 기기"), Protocol.cleanName(input.optString("platform", ""), ""), code, count, bytes,
                        Protocol.cleanName(input.optString("summary", ""), count > 0 ? "파일 " + count + "개" : "파일"), url);
            } catch (Exception e) { return null; }
        }
        /** https://<호스트>/s/<cid>/<token> 형식만 받습니다(계정·질의·조각 없음). */
        static boolean validURL(String value) {
            try {
                if (value == null || value.getBytes(StandardCharsets.UTF_8).length > 400) return false;
                URI u = new URI(value);
                if (!"https".equalsIgnoreCase(u.getScheme()) || u.getHost() == null || u.getHost().isEmpty() || u.getRawUserInfo() != null || u.getRawQuery() != null || u.getRawFragment() != null) return false;
                String[] parts = Protocol.guestParts(u.getRawPath());
                return parts != null && parts[2].isEmpty();
            } catch (Exception e) { return false; }
        }
    }

    interface Listener {
        void devices(List<Device> list);
        void state(State value);
        void offer(Offer offer);
    }
    interface Done { void done(String error); }

    private static final class Seen {
        BluetoothDevice device; double rssi; long last; String name, platform; long tried, cardAt; boolean shown, near;
    }
    private static final class PendingWrite { final byte[] data; final Done done; PendingWrite(byte[] d, Done c) { data = d; done = c; } }

    private final Context ctx;
    private final Listener listener;
    private final HandlerThread thread = new HandlerThread("아나 Bluetooth");
    private final Handler h;
    private final BluetoothManager manager;
    private final BluetoothAdapter adapter;
    private boolean foreground, advertise, closed;
    private byte[] card = new byte[0];
    private BluetoothLeScanner scanner;
    private ScanCallback scanCallback;
    private BluetoothLeAdvertiser advertiser;
    private AdvertiseCallback advertiseCallback;
    private boolean advertising;
    private BluetoothGattServer gattServer;
    private byte[] serviceCard;
    private final Map<String, Seen> seen = new HashMap<>();
    private final Map<String, BluetoothGatt> gatts = new HashMap<>();
    private final Set<String> connecting = new HashSet<>();
    private final Map<String, PendingWrite> writes = new HashMap<>();
    private final Map<String, ByteArrayOutputStream> inboxBuffers = new HashMap<>();
    /** card를 읽는 중인 연결(같은 응답이 두 콜백으로 올 수 있어 한 번만 처리) */
    private final Set<String> reading = new HashSet<>();
    private boolean pruning, receiverOn;
    private String lastPrint = null;
    private State lastState = null;

    private final BroadcastReceiver stateReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) { h.post(() -> { apply(); publishState(); }); }
    };

    NearbyRadio(Context context, Listener listener) {
        this.ctx = context.getApplicationContext();
        this.listener = listener;
        thread.start();
        h = new Handler(thread.getLooper());
        manager = (BluetoothManager) ctx.getSystemService(Context.BLUETOOTH_SERVICE);
        BluetoothAdapter a = null;
        try { a = manager == null ? null : manager.getAdapter(); } catch (Exception ignored) {}
        adapter = ctx.getPackageManager().hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) ? a : null;
    }

    /** Android 12+: BLUETOOTH_SCAN/ADVERTISE/CONNECT, 그 전: 정밀 위치(BLE 검색에 필요) */
    static String[] permissions() {
        if (Build.VERSION.SDK_INT >= 31) return new String[]{Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT};
        return new String[]{Manifest.permission.ACCESS_FINE_LOCATION};
    }
    static boolean permitted(Context c) {
        for (String p : permissions()) if (c.checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED) return false;
        return true;
    }
    boolean supported() { return adapter != null; }
    /** 이 기기가 광고(받기)를 할 수 있는지. Bluetooth가 꺼져 있으면 알 수 없으니 true로 둡니다. */
    boolean canAdvertise() {
        try { return adapter != null && (!adapter.isEnabled() || adapter.isMultipleAdvertisementSupported()); } catch (Exception e) { return true; }
    }

    /** foreground: 앱이 화면에 있음 · advertise: '10분 동안 모두' · card: 근처에 보일 이름 JSON */
    void update(boolean foreground, boolean advertise, byte[] card) {
        h.post(() -> {
            if (closed) return;
            this.foreground = foreground; this.advertise = advertise; this.card = card;
            if (foreground && !receiverOn) {
                try {
                    IntentFilter f = new IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED);
                    f.addAction(LocationManager.PROVIDERS_CHANGED_ACTION);
                    if (Build.VERSION.SDK_INT >= 33) ctx.registerReceiver(stateReceiver, f, Context.RECEIVER_NOT_EXPORTED);
                    else ctx.registerReceiver(stateReceiver, f);
                    receiverOn = true;
                } catch (Exception ignored) {}
            } else if (!foreground && receiverOn) {
                try { ctx.unregisterReceiver(stateReceiver); } catch (Exception ignored) {}
                receiverOn = false;
            }
            apply(); publishState();
        });
    }
    /** 권한을 받은 뒤 등: 상태를 다시 확인합니다. */
    void refresh() { h.post(() -> { if (!closed) { apply(); publishState(); } }); }

    void close() {
        h.post(() -> {
            foreground = false; advertise = false; apply();
            if (receiverOn) { try { ctx.unregisterReceiver(stateReceiver); } catch (Exception ignored) {} receiverOn = false; }
            closed = true;
            thread.quitSafely();
        });
    }

    State state() {
        if (adapter == null) return State.UNSUPPORTED;
        if (!permitted(ctx)) return State.UNAUTHORIZED;
        boolean enabled;
        try { enabled = adapter.isEnabled(); } catch (Exception e) { return State.UNAUTHORIZED; }
        if (!enabled) return State.OFF;
        if (Build.VERSION.SDK_INT < 31) {
            try { LocationManager lm = (LocationManager) ctx.getSystemService(Context.LOCATION_SERVICE); if (lm != null && !lm.isLocationEnabled()) return State.LOCATION_OFF; } catch (Exception ignored) {}
        }
        return State.ON;
    }
    private void publishState() {
        State value = state();
        if (value == lastState) return;
        lastState = value; listener.state(value);
    }

    /** 근처 기기의 inbox에 제안을 씁니다. done(null)이면 전달 성공, 아니면 안내 문구. */
    void send(byte[] data, String id, Done done) {
        h.post(() -> {
            Seen entry = seen.get(id);
            if (closed || state() != State.ON || entry == null) { done.done("근처에서 그 기기를 찾을 수 없습니다. 상대 아나가 열려 있는지 확인하세요."); return; }
            PendingWrite previous = writes.remove(id);
            if (previous != null) previous.done.done("다시 보내는 중입니다.");
            writes.put(id, new PendingWrite(data, done));
            BluetoothGatt gatt = gatts.get(id);
            if (gatt != null && !connecting.contains(id)) { try { if (!gatt.discoverServices()) disconnect(id); } catch (Exception e) { disconnect(id); } }
            if (!gatts.containsKey(id)) connect(id, true);
            h.postDelayed(() -> {
                if (!writes.containsKey(id)) return;
                finishWrite(id, "상대 기기가 응답하지 않습니다. 더 가까이에서 다시 시도하세요.");
                disconnect(id);
            }, 15000);
        });
    }

    // ---------- 찾기 (central) ----------

    private void apply() {
        boolean on = state() == State.ON;
        applyCentral(on);
        applyPeripheral(on);
    }

    private void applyCentral(boolean on) {
        if (foreground && on && !closed) {
            if (scanCallback == null) {
                try {
                    scanner = adapter.getBluetoothLeScanner();
                    if (scanner != null) {
                        scanCallback = new ScanCallback() {
                            @Override public void onScanResult(int type, ScanResult r) { h.post(() -> discovered(r)); }
                            @Override public void onBatchScanResults(List<ScanResult> list) { h.post(() -> { for (ScanResult r : list) discovered(r); }); }
                            @Override public void onScanFailed(int code) { h.post(() -> { scanCallback = null; h.postDelayed(() -> apply(), 5000); }); }
                        };
                        List<ScanFilter> filters = Collections.singletonList(new ScanFilter.Builder().setServiceUuid(new ParcelUuid(SERVICE)).build());
                        ScanSettings settings = new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES).setReportDelay(0).build();
                        scanner.startScan(filters, settings, scanCallback);
                    }
                } catch (Exception e) { scanCallback = null; }
            }
            schedulePrune();
        } else {
            if (scanCallback != null) { try { if (scanner != null) scanner.stopScan(scanCallback); } catch (Exception ignored) {} scanCallback = null; }
            for (String id : new ArrayList<>(gatts.keySet())) disconnect(id);
            for (String id : new ArrayList<>(writes.keySet())) finishWrite(id, "Bluetooth를 사용할 수 없습니다.");
            seen.clear(); connecting.clear(); reading.clear();
            publishDevices();
        }
    }

    private void schedulePrune() {
        if (pruning) return;
        pruning = true;
        h.postDelayed(() -> {
            pruning = false;
            if (closed || !foreground || scanCallback == null) return;
            long now = System.currentTimeMillis();
            for (Map.Entry<String, Seen> e : new ArrayList<>(seen.entrySet())) {
                if (now - e.getValue().last > 25000 && !writes.containsKey(e.getKey())) { disconnect(e.getKey()); seen.remove(e.getKey()); connecting.remove(e.getKey()); }
            }
            publishDevices(); schedulePrune();
        }, 1000);
    }

    private void publishDevices() {
        // Bluetooth 신호는 몇 dB씩 출렁이므로, 한 번 보인 기기는 -88 아래로 떨어지거나 25초 동안 신호가 없을 때만 뺍니다.
        // (처음 보이는 기준은 그대로 -78 · 최근 10초) 순서도 신호 세기가 아니라 '아주 가까움' → 이름으로 고정합니다.
        long now = System.currentTimeMillis();
        // 같은 기기가 Bluetooth 주소를 바꾸며 광고하면 두 번 보일 수 있어, 이름·기기 종류가 같으면 가장 최근 것 하나만 둡니다.
        Map<String, Device> byName = new java.util.HashMap<>();
        Map<String, Long> lastSeen = new java.util.HashMap<>();
        for (Map.Entry<String, Seen> e : seen.entrySet()) {
            Seen s = e.getValue(); long age = now - s.last;
            boolean keep = s.name != null && (s.shown ? (age < 8000 && s.rssi >= -88) : (age < 10000 && s.rssi >= -78));
            s.shown = keep;
            s.near = keep && (s.near ? s.rssi >= -66 : s.rssi >= -60);
            if (!keep) continue;
            String platform = s.platform == null ? "" : s.platform, key = s.name + "|" + platform;
            Long previous = lastSeen.get(key);
            if (previous != null && previous >= s.last) continue;
            byName.put(key, new Device(e.getKey(), s.name, platform, (int) Math.round(s.rssi), s.near)); lastSeen.put(key, s.last);
        }
        List<Device> list = new ArrayList<>(byName.values());
        list.sort((a, b) -> a.near == b.near ? a.name.compareTo(b.name) : (a.near ? -1 : 1));
        StringBuilder print = new StringBuilder();
        for (Device d : list) print.append('|').append(d.print());
        if (print.toString().equals(lastPrint)) return;
        lastPrint = print.toString();
        listener.devices(list);
    }

    private void discovered(ScanResult r) {
        if (closed || !foreground || r == null || r.getDevice() == null) return;
        int value = r.getRssi();
        if (value >= 0 || value <= -110) return;
        String id = r.getDevice().getAddress();
        Seen s = seen.get(id);
        if (s == null) { s = new Seen(); s.rssi = value; seen.put(id, s); }
        s.device = r.getDevice(); s.rssi = s.rssi * 0.75 + value * 0.25; s.last = System.currentTimeMillis();
        // 이름은 30초마다 다시 읽어, 상대가 이름을 바꾸면 목록에도 반영합니다.
        boolean stale = s.name == null || System.currentTimeMillis() - s.cardAt > 30000;
        if (stale && s.rssi >= -78 && (s.tried == 0 || System.currentTimeMillis() - s.tried > 15000)) connect(id, false);
    }

    private void connect(String id, boolean force) {
        Seen s = seen.get(id);
        if (s == null || s.device == null) return;
        if (!force && (connecting.contains(id) || gatts.containsKey(id) || connecting.size() >= 2)) return;
        connecting.add(id); s.tried = System.currentTimeMillis();
        try {
            BluetoothGatt gatt = s.device.connectGatt(ctx, false, new Client(id), BluetoothDevice.TRANSPORT_LE);
            if (gatt == null) { connecting.remove(id); finishWrite(id, "상대 기기에 연결하지 못했습니다."); return; }
            BluetoothGatt old = gatts.put(id, gatt);
            if (old != null && old != gatt) try { old.close(); } catch (Exception ignored) {}
        } catch (Exception e) { connecting.remove(id); finishWrite(id, "상대 기기에 연결하지 못했습니다."); return; }
        h.postDelayed(() -> {
            if (!connecting.contains(id)) return;
            connecting.remove(id);
            disconnect(id);
            finishWrite(id, "상대 기기에 연결하지 못했습니다. 더 가까이에서 다시 시도하세요.");
        }, 8000);
    }
    private void disconnect(String id) {
        connecting.remove(id); reading.remove(id);
        BluetoothGatt g = gatts.remove(id);
        if (g != null) { try { g.disconnect(); } catch (Exception ignored) {} try { g.close(); } catch (Exception ignored) {} }
    }
    private void finishWrite(String id, String error) {
        PendingWrite w = writes.remove(id);
        if (w != null) {
            w.done.done(error);
            // 보내기에 실패한 기기(받기를 끈 기기 등)는 목록에서 바로 뺍니다. 다시 광고하면 또 보입니다.
            Seen s = seen.get(id);
            if (error != null && s != null) { s.shown = false; s.name = null; s.cardAt = 0; publishDevices(); }
        }
    }
    /** 이번 연결의 일이 끝났을 때: 그 사이 보내기 제안이 생겼으면 이어서 쓰고, 아니면 연결을 끊습니다. */
    private void finished(String id, BluetoothGatt gatt) {
        connecting.remove(id);
        if (writes.containsKey(id) && gatts.get(id) == gatt) { try { if (gatt.discoverServices()) return; } catch (Exception ignored) {} }
        disconnect(id);
    }

    /** 기기 하나와의 GATT 연결 */
    private final class Client extends BluetoothGattCallback {
        final String id;
        Client(String id) { this.id = id; }
        boolean current(BluetoothGatt g) { return gatts.get(id) == g; }
        @Override public void onConnectionStateChange(BluetoothGatt g, int status, int newState) {
            h.post(() -> {
                if (!current(g)) { try { g.close(); } catch (Exception ignored) {} return; }
                if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                    // 512바이트 제안을 한 번에 쓸 수 있게 MTU를 키웁니다(안 되면 서비스 찾기로 바로 넘어감).
                    try { if (!g.requestMtu(517)) g.discoverServices(); } catch (Exception e) { disconnect(id); }
                } else {
                    boolean wasWriting = writes.containsKey(id);
                    disconnect(id);
                    if (wasWriting) finishWrite(id, status == BluetoothGatt.GATT_SUCCESS ? "상대 기기와 연결이 끊겼습니다." : "상대 기기에 연결하지 못했습니다.");
                }
            });
        }
        @Override public void onMtuChanged(BluetoothGatt g, int mtu, int status) {
            h.post(() -> { if (current(g)) try { if (!g.discoverServices()) { finishWrite(id, "상대 기기에 연결하지 못했습니다."); disconnect(id); } } catch (Exception e) { disconnect(id); } });
        }
        @Override public void onServicesDiscovered(BluetoothGatt g, int status) {
            h.post(() -> {
                if (!current(g)) return;
                BluetoothGattService service = status == BluetoothGatt.GATT_SUCCESS ? g.getService(SERVICE) : null;
                if (service == null) { finishWrite(id, "상대 기기에서 아나를 찾지 못했습니다."); finished(id, g); return; }
                PendingWrite w = writes.get(id);
                try {
                    if (w != null) {
                        BluetoothGattCharacteristic inbox = service.getCharacteristic(INBOX);
                        if (inbox == null) { finishWrite(id, "상대 기기가 지금은 받지 않습니다."); finished(id, g); return; }
                        boolean started;
                        if (Build.VERSION.SDK_INT >= 33) started = g.writeCharacteristic(inbox, w.data, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == 0;
                        else { inbox.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT); inbox.setValue(w.data); started = g.writeCharacteristic(inbox); }
                        if (!started) { finishWrite(id, "상대 기기에 전달하지 못했습니다."); finished(id, g); }
                        return;
                    }
                    Seen s = seen.get(id);
                    BluetoothGattCharacteristic c = service.getCharacteristic(CARD);
                    if (s != null && (s.name == null || System.currentTimeMillis() - s.cardAt > 30000) && c != null) { reading.add(id); if (!g.readCharacteristic(c)) { reading.remove(id); finished(id, g); } return; }
                } catch (Exception e) { finishWrite(id, "상대 기기에 전달하지 못했습니다."); }
                finished(id, g);
            });
        }
        // Android 13+는 값이 함께 오는 새 콜백과 예전 콜백을 모두 부릅니다. reading으로 한 번만 처리합니다.
        @Override public void onCharacteristicRead(BluetoothGatt g, BluetoothGattCharacteristic c, byte[] value, int status) {
            byte[] copy = value == null ? null : value.clone();
            h.post(() -> cardRead(g, c, copy, status));
        }
        @SuppressWarnings("deprecation")
        @Override public void onCharacteristicRead(BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
            byte[] v = c.getValue();
            byte[] copy = v == null ? null : v.clone();
            h.post(() -> cardRead(g, c, copy, status));
        }
        void cardRead(BluetoothGatt g, BluetoothGattCharacteristic c, byte[] value, int status) {
            if (!current(g) || !CARD.equals(c.getUuid()) || !reading.remove(id)) return;
            Seen s = seen.get(id);
            if (status == BluetoothGatt.GATT_SUCCESS && value != null && value.length <= 1024 && s != null) {
                try {
                    JSONObject input = new JSONObject(Protocol.strictUTF8(value));
                    if (input.optInt("v", 0) == 1) {
                        s.name = Protocol.cleanName(input.optString("name", ""), "아나 기기");
                        s.platform = Protocol.cleanName(input.optString("platform", ""), "");
                        s.cardAt = System.currentTimeMillis();
                        publishDevices();
                    }
                } catch (Exception ignored) {}
            }
            finished(id, g);
        }
        @Override public void onCharacteristicWrite(BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
            h.post(() -> {
                if (!current(g) || !INBOX.equals(c.getUuid())) return;
                finishWrite(id, status == BluetoothGatt.GATT_SUCCESS ? null : "상대 기기에 전달하지 못했습니다. 상대가 ‘10분 동안 모두’로 받기를 켰는지 확인하세요.");
                finished(id, g);
            });
        }
    }

    // ---------- 받기 광고 (peripheral) ----------

    private void applyPeripheral(boolean on) {
        boolean wanted = foreground && advertise && on && !closed;
        if (wanted) {
            if (gattServer == null || serviceCard == null || !Arrays.equals(serviceCard, card)) {
                stopAdvertising();
                if (gattServer == null) {
                    try { gattServer = manager.openGattServer(ctx, new Server()); } catch (Exception e) { gattServer = null; }
                    if (gattServer == null) return;
                } else {
                    try { gattServer.clearServices(); } catch (Exception ignored) {}
                }
                BluetoothGattService service = new BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY);
                BluetoothGattCharacteristic cardC = new BluetoothGattCharacteristic(CARD, BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ);
                BluetoothGattCharacteristic inboxC = new BluetoothGattCharacteristic(INBOX, BluetoothGattCharacteristic.PROPERTY_WRITE, BluetoothGattCharacteristic.PERMISSION_WRITE);
                service.addCharacteristic(cardC); service.addCharacteristic(inboxC);
                serviceCard = card;
                try { if (!gattServer.addService(service)) serviceCard = null; } catch (Exception e) { serviceCard = null; }
                // 광고는 onServiceAdded에서 시작
            } else if (!advertising) startAdvertising();
        } else {
            stopAdvertising();
            if (gattServer != null) { try { gattServer.clearServices(); gattServer.close(); } catch (Exception ignored) {} gattServer = null; }
            serviceCard = null;
            inboxBuffers.clear();
        }
    }
    private void startAdvertising() {
        if (advertising) return;
        try {
            advertiser = adapter.getBluetoothLeAdvertiser();
            if (advertiser == null) return;
            AdvertiseSettings settings = new AdvertiseSettings.Builder().setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                    .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM).setConnectable(true).setTimeout(0).build();
            // 광고 31바이트: 128비트 서비스 UUID(18) + 플래그(3). 이름은 card로 읽습니다.
            AdvertiseData data = new AdvertiseData.Builder().addServiceUuid(new ParcelUuid(SERVICE)).setIncludeDeviceName(false).setIncludeTxPowerLevel(false).build();
            advertiseCallback = new AdvertiseCallback() {
                @Override public void onStartSuccess(AdvertiseSettings s) {}
                @Override public void onStartFailure(int code) { h.post(() -> { advertising = false; advertiseCallback = null; }); }
            };
            advertiser.startAdvertising(settings, data, advertiseCallback);
            advertising = true;
        } catch (Exception e) { advertising = false; advertiseCallback = null; }
    }
    private void stopAdvertising() {
        if (advertiser != null && advertiseCallback != null) try { advertiser.stopAdvertising(advertiseCallback); } catch (Exception ignored) {}
        advertiseCallback = null; advertising = false;
    }

    private final class Server extends BluetoothGattServerCallback {
        @Override public void onServiceAdded(int status, BluetoothGattService service) {
            h.post(() -> {
                if (status != BluetoothGatt.GATT_SUCCESS) { serviceCard = null; return; }
                if (foreground && advertise && !advertising) startAdvertising();
            });
        }
        @Override public void onCharacteristicReadRequest(BluetoothDevice device, int requestId, int offset, BluetoothGattCharacteristic c) {
            h.post(() -> {
                BluetoothGattServer s = gattServer;
                if (s == null) return;
                byte[] value = card;
                try {
                    if (!CARD.equals(c.getUuid())) s.sendResponse(device, requestId, BluetoothGatt.GATT_READ_NOT_PERMITTED, offset, null);
                    else if (offset > value.length) s.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null);
                    else s.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, Arrays.copyOfRange(value, offset, value.length));
                } catch (Exception ignored) {}
            });
        }
        @Override public void onCharacteristicWriteRequest(BluetoothDevice device, int requestId, BluetoothGattCharacteristic c, boolean prepared, boolean responseNeeded, int offset, byte[] value) {
            byte[] chunk = value == null ? new byte[0] : value.clone();
            h.post(() -> {
                BluetoothGattServer s = gattServer;
                if (s == null) return;
                String key = device.getAddress();
                int status = BluetoothGatt.GATT_SUCCESS;
                Offer complete = null;
                if (!INBOX.equals(c.getUuid()) || !foreground || !advertise) status = BluetoothGatt.GATT_WRITE_NOT_PERMITTED;
                else {
                    // 긴 쓰기(512바이트까지)는 offset 순서대로 이어 붙입니다. 준비 쓰기(prepared)는 실행(execute) 때 처리합니다.
                    ByteArrayOutputStream buffer = offset == 0 ? new ByteArrayOutputStream() : inboxBuffers.get(key);
                    if (buffer == null || buffer.size() != offset) { status = BluetoothGatt.GATT_INVALID_OFFSET; inboxBuffers.remove(key); }
                    else if (buffer.size() + chunk.length > MAX_OFFER) { status = BluetoothGatt.GATT_INVALID_ATTRIBUTE_LENGTH; inboxBuffers.remove(key); }
                    else {
                        buffer.write(chunk, 0, chunk.length);
                        inboxBuffers.put(key, buffer);
                        if (!prepared) { complete = Offer.parse(buffer.toByteArray()); if (complete != null) inboxBuffers.remove(key); }
                    }
                }
                if (responseNeeded) try { s.sendResponse(device, requestId, status, offset, chunk); } catch (Exception ignored) {}
                if (complete != null) listener.offer(complete);
            });
        }
        @Override public void onExecuteWrite(BluetoothDevice device, int requestId, boolean execute) {
            h.post(() -> {
                BluetoothGattServer s = gattServer;
                if (s == null) return;
                String key = device.getAddress();
                ByteArrayOutputStream buffer = inboxBuffers.remove(key);
                Offer complete = execute && buffer != null && foreground && advertise ? Offer.parse(buffer.toByteArray()) : null;
                try { s.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null); } catch (Exception ignored) {}
                if (complete != null) listener.offer(complete);
            });
        }
        @Override public void onConnectionStateChange(BluetoothDevice device, int status, int newState) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) h.post(() -> inboxBuffers.remove(device.getAddress()));
        }
    }
}
