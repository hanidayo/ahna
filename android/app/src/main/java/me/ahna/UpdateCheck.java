package me.ahna;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.net.Uri;
import android.widget.Toast;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

/** GitHub Releases(latest.json)에서 새 버전을 확인하고, 있으면 APK 내려받기를 안내합니다. 6시간에 한 번 확인합니다. */
final class UpdateCheck {
    static final String MANIFEST = Brand.SERVER + "/_ahna/update/latest.json";
    private UpdateCheck() {}

    static void run(Activity activity, SharedPreferences prefs, boolean force) {
        long now = System.currentTimeMillis();
        if (!force && now - prefs.getLong("updateChecked", 0) < 6L * 3600 * 1000) return;
        new Thread(() -> {
            try {
                HttpURLConnection c = (HttpURLConnection) new URL(MANIFEST).openConnection();
                c.setInstanceFollowRedirects(true); c.setConnectTimeout(15000); c.setReadTimeout(20000);
                if (c.getResponseCode() != 200) return;
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                try (InputStream in = c.getInputStream()) { byte[] b = new byte[8192]; int n; while ((n = in.read(b)) > 0 && out.size() < 65536) out.write(b, 0, n); }
                JSONObject m = new JSONObject(new String(out.toByteArray(), StandardCharsets.UTF_8));
                prefs.edit().putLong("updateChecked", now).apply();
                JSONObject apk = m.getJSONObject("platforms").optJSONObject("android");
                String latest = m.getString("version");
                PackageInfo info = activity.getPackageManager().getPackageInfo(activity.getPackageName(), 0);
                // 옵션 화면의 "최신 버전입니다 / 새 버전 있음" 표시용 (Android용 파일이 없으면 현재 버전을 최신으로 봅니다).
                prefs.edit().putString("updateLatest", apk == null ? info.versionName : latest).apply();
                if (apk == null || !newer(latest, info.versionName)) {
                    if (force) activity.runOnUiThread(() -> { if (!activity.isFinishing()) new AlertDialog.Builder(activity).setMessage("최신 버전입니다. (v" + info.versionName + ")").setPositiveButton("확인", null).show(); });
                    return;
                }
                String url = apk.getString("url");
                activity.runOnUiThread(() -> {
                    if (activity.isFinishing()) return;
                    new AlertDialog.Builder(activity)
                        .setTitle("아나 업데이트")
                        .setMessage("새 버전 v" + latest + "이 있습니다. (현재 v" + info.versionName + ")\n내려받은 APK를 열어 설치하면 기존 설정과 연결이 유지됩니다.")
                        .setPositiveButton("내려받기", (d, w) -> { try { activity.startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url))); } catch (Exception e) { Toast.makeText(activity, url, Toast.LENGTH_LONG).show(); } })
                        .setNegativeButton("나중에", null).show();
                });
            } catch (Exception e) {
                if (force) activity.runOnUiThread(() -> { if (!activity.isFinishing()) new AlertDialog.Builder(activity).setMessage("업데이트 확인 실패: " + e.getMessage()).setPositiveButton("확인", null).show(); });
            }
        }).start();
    }

    static boolean newer(String a, String b) {
        int[] x = parts(a), y = parts(b);
        for (int i = 0; i < 3; i++) if (x[i] != y[i]) return x[i] > y[i];
        return false;
    }
    private static int[] parts(String s) {
        int[] r = new int[3]; String[] p = (s == null ? "0" : s.replaceAll("^[vV]", "").split("[-+]")[0]).split("\\.");
        for (int i = 0; i < 3 && i < p.length; i++) try { r[i] = Integer.parseInt(p[i]); } catch (NumberFormatException ignored) { }
        return r;
    }
}
