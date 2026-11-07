package me.ahna;

import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import org.json.JSONArray;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.ArrayList;
import java.util.List;

/** 저장된 연결·세션을 Android Keystore 키로 암호화합니다. 앱 화면과 공유 창이 함께 씁니다. */
final class Vault {
    private Vault() {}
    static final String ALIAS = "Ahna.sessions";

    static SecretKey key() throws Exception {
        KeyStore ks = KeyStore.getInstance("AndroidKeyStore"); ks.load(null);
        if (!ks.containsAlias(ALIAS)) {
            KeyGenerator g = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            g.init(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
            g.generateKey();
        }
        return (SecretKey) ks.getKey(ALIAS, null);
    }

    static synchronized String encrypt(String value) throws Exception {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, key());
        return Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP) + ":" + Base64.encodeToString(cipher.doFinal(value.getBytes(StandardCharsets.UTF_8)), Base64.NO_WRAP);
    }

    static String decrypt(String value) throws Exception {
        if (value == null || value.isEmpty()) return "[]";
        String[] parts = value.split(":", 2);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)));
        return Protocol.strictUTF8(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)));
    }

    /** 이 기기가 추가한 기기(보낼 대상) 목록. */
    static List<Client> clients(SharedPreferences prefs) throws Exception {
        List<Client> result = new ArrayList<>();
        JSONArray saved = new JSONArray(decrypt(prefs.getString("connections", "")));
        for (int i = 0; i < saved.length(); i++) result.add(new Client(saved.getJSONObject(i)));
        return result;
    }
}
