package me.ahna;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.*;
import java.util.concurrent.*;

import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * 같은 네트워크(같은 공유기)면 서버를 거치지 않고 기기끼리 바로 주고받기.
 * Windows·Mac src/DirectChannel.cs, iPhone ios/Shared/DirectLink.swift 와 같은 방식입니다.
 *
 * 받는 기기가 서버를 거친(=인증된) /api/state?direct=1 응답에 키·포트·주소를 알려 주면,
 * 보내는 기기는 그 주소로 TCP 연결해 요청 하나를 AES-256-GCM으로 암호화해 보냅니다.
 *   → "AHNADR01" + 키 id(16) + salt(16), 이후 레코드 [길이 u32 BE][암호문+태그16] (본문 최대 1 MiB)
 *   키: 보내는 쪽 HMAC-SHA256(key, "c2s"+salt), 받는 쪽 HMAC-SHA256(key, "s2c"+salt), nonce = 0×4 + 레코드 번호 u64 BE
 *   첫 레코드 {"m","p","l","t"} → 본문 / 응답 첫 레코드 {"s","l"} → 본문
 */
final class DirectLink {
    static final int PORT = 45853;
    static final int RECORD = 1 << 20;
    static final byte[] MAGIC = "AHNADR01".getBytes(StandardCharsets.US_ASCII);
    private static final SecureRandom RANDOM = new SecureRandom();

    /** 직접 연결이 안 되거나 도중에 끊김: 서버를 거쳐 다시 보내면 됩니다. */
    static final class Unavailable extends IOException { Unavailable(String m, Throwable cause) { super(m, cause); } Unavailable(String m) { super(m); } }

    static byte[] derive(byte[] key, String label, byte[] salt) throws IOException {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(key, "HmacSHA256"));
            mac.update(label.getBytes(StandardCharsets.US_ASCII));
            return mac.doFinal(salt);
        } catch (Exception e) { throw new IOException("암호 준비 실패", e); }
    }

    static final class Cipher {
        private final SecretKeySpec key;
        private long counter;
        Cipher(byte[] secret, String label, byte[] salt) throws IOException { key = new SecretKeySpec(derive(secret, label, salt), "AES"); }
        private GCMParameterSpec nonce() {
            byte[] n = new byte[12];
            long c = counter++;
            for (int i = 0; i < 8; i++) n[11 - i] = (byte) (c >>> (8 * i));
            return new GCMParameterSpec(128, n);
        }
        void write(OutputStream out, byte[] plain, int offset, int length) throws IOException {
            byte[] sealed;
            try {
                javax.crypto.Cipher aes = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding");
                aes.init(javax.crypto.Cipher.ENCRYPT_MODE, key, nonce());
                sealed = aes.doFinal(plain, offset, length);
            } catch (Exception e) { throw new IOException("암호화 실패", e); }
            int n = sealed.length;
            out.write(new byte[]{(byte) (n >>> 24), (byte) (n >>> 16), (byte) (n >>> 8), (byte) n});
            out.write(sealed);
        }
        byte[] read(InputStream in) throws IOException {
            byte[] head = exactly(in, 4);
            int n = ((head[0] & 0xff) << 24) | ((head[1] & 0xff) << 16) | ((head[2] & 0xff) << 8) | (head[3] & 0xff);
            if (n < 16 || n > RECORD + 16) throw new IOException("올바르지 않은 직접 전송 데이터입니다.");
            byte[] frame = exactly(in, n);
            try {
                javax.crypto.Cipher aes = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding");
                aes.init(javax.crypto.Cipher.DECRYPT_MODE, key, nonce());
                return aes.doFinal(frame);
            } catch (Exception e) { throw new IOException("직접 전송 데이터를 확인하지 못했습니다.", e); }
        }
    }

    static byte[] exactly(InputStream in, int count) throws IOException {
        byte[] result = new byte[count];
        int got = 0;
        while (got < count) { int n = in.read(result, got, count - got); if (n < 0) throw new EOFException(); got += n; }
        return result;
    }

    /** 정해진 길이만큼 레코드를 풀어 읽는 스트림. */
    static final class OpenStream extends InputStream {
        private final InputStream in; private final Cipher cipher; private long left;
        private byte[] current = new byte[0]; private int offset;
        OpenStream(InputStream in, Cipher cipher, long length) { this.in = in; this.cipher = cipher; this.left = length; }
        @Override public int read() throws IOException { byte[] one = new byte[1]; int n = read(one, 0, 1); return n < 0 ? -1 : one[0] & 0xff; }
        @Override public int read(byte[] b, int off, int len) throws IOException {
            if (len == 0) return 0;
            if (offset == current.length) {
                if (left == 0) return -1;
                current = cipher.read(in); offset = 0;
                if (current.length == 0 || current.length > left) throw new IOException("올바르지 않은 직접 전송 데이터입니다.");
                left -= current.length;
            }
            int n = Math.min(len, current.length - offset);
            System.arraycopy(current, offset, b, off, n); offset += n;
            return n;
        }
    }

    /** 쓰는 내용을 1 MiB 레코드로 암호화해 내보내는 스트림. finish()로 남은 것을 보냅니다. */
    static final class SealStream extends OutputStream {
        private final OutputStream out; private final Cipher cipher; private final byte[] buffer = new byte[RECORD]; private int filled; private long written; private final long length;
        SealStream(OutputStream out, Cipher cipher, long length) { this.out = out; this.cipher = cipher; this.length = length; }
        @Override public void write(int b) throws IOException { write(new byte[]{(byte) b}, 0, 1); }
        @Override public void write(byte[] b, int off, int len) throws IOException {
            if (written + len > length) throw new IOException("보낼 파일 크기가 바뀌었습니다.");
            written += len;
            while (len > 0) {
                int n = Math.min(len, buffer.length - filled);
                System.arraycopy(b, off, buffer, filled, n); filled += n; off += n; len -= n;
                if (filled == buffer.length) { cipher.write(out, buffer, 0, filled); filled = 0; }
            }
        }
        void finish() throws IOException {
            if (written != length) throw new IOException("보낼 파일 크기가 바뀌었습니다.");
            if (filled > 0) { cipher.write(out, buffer, 0, filled); filled = 0; }
            out.flush();
        }
    }

    // ---------------------------------------------------------------------------------
    // 보내는 쪽
    // ---------------------------------------------------------------------------------

    interface Body { void write(OutputStream out) throws IOException; }

    static final class Response implements Closeable {
        final int status; final long length; final InputStream body; private final Socket socket;
        Response(int status, long length, InputStream body, Socket socket) { this.status = status; this.length = length; this.body = body; this.socket = socket; }
        @Override public void close() { try { socket.close(); } catch (IOException ignored) {} }
    }

    /** 상태 확인 응답의 "direct" 값이 쓸 만한지. */
    static boolean usable(JSONObject info) {
        if (info == null) return false;
        String id = info.optString("id", ""); int port = info.optInt("port", 0); JSONArray addrs = info.optJSONArray("addrs");
        byte[] key; try { key = android.util.Base64.decode(info.optString("key", ""), android.util.Base64.NO_WRAP); } catch (IllegalArgumentException e) { return false; }
        return id.matches("[a-f0-9]{32}") && key.length == 32 && port > 0 && port < 65536 && addrs != null && addrs.length() > 0;
    }

    /** 알려 준 주소들에 동시에 연결해 보고 먼저 된 것을 씁니다(0.9초 안에 안 되면 실패). */
    private static Socket connect(JSONObject info) throws IOException {
        int port = info.optInt("port");
        JSONArray addrs = info.optJSONArray("addrs");
        List<String> list = new ArrayList<>();
        for (int i = 0; addrs != null && i < addrs.length() && list.size() < 8; i++) { String a = addrs.optString(i, ""); if (a.matches("\\d{1,3}(\\.\\d{1,3}){3}")) list.add(a); }
        if (list.isEmpty()) throw new Unavailable("주소 없음");
        ExecutorService pool = Executors.newFixedThreadPool(list.size());
        ExecutorCompletionService<Socket> race = new ExecutorCompletionService<>(pool);
        for (String address : list) race.submit(() -> { Socket s = new Socket(); try { s.setTcpNoDelay(true); s.connect(new InetSocketAddress(InetAddress.getByName(address), port), 900); return s; } catch (IOException e) { s.close(); throw e; } });
        Socket winner = null;
        try {
            for (int i = 0; i < list.size(); i++) {
                Future<Socket> done = race.poll(1200, TimeUnit.MILLISECONDS);
                if (done == null) break;
                try { Socket s = done.get(); if (winner == null) winner = s; else s.close(); } catch (ExecutionException ignored) {}
                if (winner != null) break;
            }
        } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        finally {
            pool.shutdownNow();
            final Socket kept = winner;
            // 늦게 연결된 나머지는 닫습니다.
            new Thread(() -> { for (;;) { try { Future<Socket> late = race.poll(1500, TimeUnit.MILLISECONDS); if (late == null) return; Socket s = late.get(); if (s != kept) s.close(); } catch (Exception ignored) { } } }).start();
        }
        if (winner == null) throw new Unavailable("같은 네트워크에서 상대 기기에 바로 연결하지 못했습니다.");
        return winner;
    }

    /** 요청 하나를 보내고 응답 머리까지 받습니다. 실패는 모두 Unavailable(서버로 다시 보내면 됨). */
    static Response request(JSONObject info, String method, String path, long length, String type, Body body) throws IOException {
        Socket socket = connect(info);
        boolean delivered = false;
        try {
            socket.setSoTimeout(60000);
            byte[] secret = android.util.Base64.decode(info.getString("key"), android.util.Base64.NO_WRAP);
            byte[] id = new byte[16]; String hex = info.getString("id");
            for (int i = 0; i < 16; i++) id[i] = (byte) Integer.parseInt(hex.substring(i * 2, i * 2 + 2), 16);
            byte[] salt = new byte[16]; RANDOM.nextBytes(salt);
            OutputStream out = new BufferedOutputStream(socket.getOutputStream(), 1 << 16);
            InputStream in = new BufferedInputStream(socket.getInputStream(), 1 << 16);
            out.write(MAGIC); out.write(id); out.write(salt);
            Cipher outbound = new Cipher(secret, "c2s", salt);
            JSONObject head = new JSONObject().put("m", method).put("p", path).put("l", length);
            if (type != null) head.put("t", type);
            byte[] headBytes = head.toString().getBytes(StandardCharsets.UTF_8);
            outbound.write(out, headBytes, 0, headBytes.length);
            if (body != null) { SealStream seal = new SealStream(out, outbound, length); body.write(seal); seal.finish(); }
            out.flush();
            // 파일 본문을 다 보낸 뒤에는 상대가 이미 저장했을 수 있어 서버로 다시 보내지 않습니다(같은 파일이 두 번 생기지 않게).
            delivered = length > 0;
            socket.setSoTimeout(45 * 60000);
            Cipher inbound = new Cipher(secret, "s2c", salt);
            JSONObject reply = new JSONObject(new String(inbound.read(in), StandardCharsets.UTF_8));
            socket.setSoTimeout(60000);
            int status = reply.getInt("s"); long bodyLength = reply.getLong("l");
            if (status < 100 || status > 599 || bodyLength < 0 || bodyLength > Protocol.MAX) throw new IOException("올바르지 않은 응답");
            // 401: 연결 정보가 바뀌었을 수 있으니(저장되지 않음) 서버를 거쳐 다시 확인합니다.
            if (status == 401) { delivered = false; throw new Unavailable("직접 연결 인증이 바뀌었습니다."); }
            return new Response(status, bodyLength, new OpenStream(in, inbound, bodyLength), socket);
        } catch (Exception e) {
            try { socket.close(); } catch (IOException ignored) {}
            if (delivered) throw new IOException("상대 기기의 저장 결과를 받지 못했습니다. 상대 기기에서 파일을 확인하세요.", e);
            throw e instanceof Unavailable ? (Unavailable) e : new Unavailable("직접 전송이 끊겼습니다.", e);
        }
    }

    // ---------------------------------------------------------------------------------
    // 받는 쪽: 공유기 안에서 들어오는 직접 연결을 받아 이 기기의 아나(127.0.0.1)로 넘깁니다.
    // ---------------------------------------------------------------------------------

    static final class Host implements Closeable {
        private static final class Key { final Set<String> seen = new HashSet<>(); final String id; final byte[] secret; final String token; final long created; Key(String id, byte[] secret, String token, long created) { this.id = id; this.secret = secret; this.token = token; this.created = created; } }
        private final Map<String, Key> keys = new ConcurrentHashMap<>();
        private final Map<String, String> byToken = new ConcurrentHashMap<>();
        private final ThreadPoolExecutor workers = new ThreadPoolExecutor(0, 8, 30, TimeUnit.SECONDS, new SynchronousQueue<>());
        private final int localPort;
        private volatile ServerSocket server;
        Host(int localPort) { this.localPort = localPort; }

        synchronized void start() {
            if (server != null) return;
            try {
                ServerSocket s = new ServerSocket(); s.setReuseAddress(true); s.bind(new InetSocketAddress(PORT), 16);
                server = s;
                Thread thread = new Thread(() -> {
                    while (!s.isClosed()) try {
                        Socket client = s.accept();
                        try { workers.execute(() -> serve(client)); } catch (RejectedExecutionException e) { try { client.close(); } catch (IOException ignored) {} }
                    } catch (IOException ignored) {}
                }, "아나 direct");
                thread.setDaemon(true); thread.start();
            } catch (IOException e) { server = null; }
        }

        /** /api/state?direct=1 응답에 넣을 값. 같은 세션이면 30분 동안 같은 키(1시간 뒤 만료). */
        synchronized JSONObject offer(String token) {
            try {
                if (server == null || token == null || token.isEmpty()) return null;
                long now = System.currentTimeMillis();
                for (Key k : new ArrayList<>(keys.values())) if (now - k.created > 3600_000L) { keys.remove(k.id); byToken.remove(k.token, k.id); }
                String existingId = byToken.get(token); Key key = existingId == null ? null : keys.get(existingId);
                if (key == null || now - key.created > 1800_000L) {
                    if (keys.size() > 1000) return null;
                    byte[] raw = new byte[16]; RANDOM.nextBytes(raw); byte[] secret = new byte[32]; RANDOM.nextBytes(secret);
                    StringBuilder id = new StringBuilder(); for (byte b : raw) id.append(String.format(Locale.ROOT, "%02x", b));
                    key = new Key(id.toString(), secret, token, now); keys.put(key.id, key); byToken.put(token, key.id);
                }
                JSONArray addrs = new JSONArray(); for (String a : addresses()) addrs.put(a);
                if (addrs.length() == 0) return null;
                return new JSONObject().put("id", key.id).put("key", android.util.Base64.encodeToString(key.secret, android.util.Base64.NO_WRAP)).put("port", PORT).put("addrs", addrs);
            } catch (Exception e) { return null; }
        }

        static List<String> addresses() {
            List<String> result = new ArrayList<>();
            try {
                for (NetworkInterface n : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                    if (!n.isUp() || n.isLoopback()) continue;
                    for (InetAddress a : Collections.list(n.getInetAddresses())) {
                        if (!(a instanceof Inet4Address) || a.isLoopbackAddress() || a.isLinkLocalAddress()) continue;
                        String text = a.getHostAddress();
                        if (text != null && !result.contains(text) && result.size() < 8) result.add(text);
                    }
                }
            } catch (Exception ignored) {}
            return result;
        }

        private static boolean allowed(String method, String path, long length) {
            if (path.length() > 4096 || !path.startsWith("/api/") || path.contains("#") || path.contains("\\") || path.contains("//") || path.contains("\r") || path.contains("\n") || path.contains(" ")) return false;
            String route = path.split("\\?", 2)[0];
            if (method.equals("GET")) return length == 0 && (route.equals("/api/state") || route.startsWith("/api/download/"));
            if (!method.equals("POST") || length < 0) return false;
            if (route.equals("/api/upload")) return length <= Protocol.MAX;
            return route.startsWith("/api/received/") && length <= 16384;
        }

        private void serve(Socket client) {
            try (Socket s = client) {
                s.setTcpNoDelay(true); s.setSoTimeout(15000);
                InputStream in = new BufferedInputStream(s.getInputStream(), 1 << 16);
                OutputStream out = new BufferedOutputStream(s.getOutputStream(), 1 << 16);
                byte[] hello = exactly(in, 40);
                if (!Arrays.equals(Arrays.copyOfRange(hello, 0, 8), MAGIC)) return;
                StringBuilder hex = new StringBuilder(); for (int i = 8; i < 24; i++) hex.append(String.format(Locale.ROOT, "%02x", hello[i]));
                Key key = keys.get(hex.toString());
                if (key == null || System.currentTimeMillis() - key.created > 3600_000L) return;
                byte[] salt = Arrays.copyOfRange(hello, 24, 40);
                // 같은 연결 내용을 다시 보내는(재전송) 것을 막습니다.
                synchronized (key.seen) { if (key.seen.size() > 20000 || !key.seen.add(Arrays.toString(salt))) return; }
                Cipher inbound = new Cipher(key.secret, "c2s", salt), outbound = new Cipher(key.secret, "s2c", salt);
                JSONObject head = new JSONObject(new String(inbound.read(in), StandardCharsets.UTF_8));
                String method = head.getString("m"), path = head.getString("p"); long length = head.getLong("l"); String type = head.isNull("t") ? "" : head.optString("t", "");
                s.setSoTimeout(60000);
                if (!allowed(method, path, length)) { respond(out, outbound, 400, new byte[0]); return; }
                // 이 기기의 아나(127.0.0.1)로 넘깁니다. 받는 쪽 Protocol은 늘 Content-Length로 답합니다.
                try (Socket local = new Socket()) {
                    local.connect(new InetSocketAddress(InetAddress.getByAddress(new byte[]{127, 0, 0, 1}), localPort), 5000);
                    local.setSoTimeout(45 * 60000);
                    OutputStream lo = new BufferedOutputStream(local.getOutputStream(), 1 << 16);
                    InputStream li = new BufferedInputStream(local.getInputStream(), 1 << 16);
                    String request = method + " " + path + " HTTP/1.1\r\nHost: 127.0.0.1:" + localPort + "\r\nCookie: ahna=" + key.token + "\r\nContent-Length: " + length + "\r\n"
                            + (type.isEmpty() || type.contains("\r") || type.contains("\n") ? "" : "Content-Type: " + type + "\r\n") + "Connection: close\r\n\r\n";
                    lo.write(request.getBytes(StandardCharsets.UTF_8));
                    if (length > 0) Protocol.copy(new OpenStream(in, inbound, length), lo, length);
                    lo.flush();
                    String status = line(li);
                    String[] parts = status.split(" ", 3);
                    if (parts.length < 2 || !parts[0].startsWith("HTTP/1.")) return;
                    int code = Integer.parseInt(parts[1]); long bodyLength = -1;
                    for (;;) { String h = line(li); if (h.isEmpty()) break; int p = h.indexOf(':'); if (p > 0 && h.substring(0, p).trim().equalsIgnoreCase("content-length")) bodyLength = Long.parseLong(h.substring(p + 1).trim()); }
                    if (bodyLength < 0 || bodyLength > Protocol.MAX) return;
                    byte[] headBytes = new JSONObject().put("s", code).put("l", bodyLength).toString().getBytes(StandardCharsets.UTF_8);
                    outbound.write(out, headBytes, 0, headBytes.length);
                    SealStream seal = new SealStream(out, outbound, bodyLength);
                    Protocol.copy(li, seal, bodyLength);
                    seal.finish();
                }
            } catch (Exception ignored) {}
        }

        private static void respond(OutputStream out, Cipher cipher, int status, byte[] body) throws Exception {
            byte[] head = new JSONObject().put("s", status).put("l", body.length).toString().getBytes(StandardCharsets.UTF_8);
            cipher.write(out, head, 0, head.length);
            if (body.length > 0) cipher.write(out, body, 0, body.length);
            out.flush();
        }

        private static String line(InputStream in) throws IOException {
            ByteArrayOutputStream b = new ByteArrayOutputStream();
            for (;;) { int c = in.read(); if (c < 0) throw new EOFException(); if (c == '\n') break; if (c != '\r') b.write(c); if (b.size() > 8192) throw new IOException("헤더가 너무 깁니다."); }
            return b.toString("UTF-8");
        }

        @Override public synchronized void close() { try { if (server != null) server.close(); } catch (IOException ignored) {} server = null; workers.shutdownNow(); }
    }
}
