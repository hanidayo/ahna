package me.ahna;

/** 아나 서버(고정)와 서버가 발급하는 기기 토큰 형식. 서버 주소를 바꿀 때는 Wire.cs · Brand.swift 와 함께 바꿉니다. */
final class Brand {
    static final String SERVER = "https://example.synology.me";
    private Brand() {}
    /** ahna.{기기 ID 32자}.{64자} */
    static boolean isMemberToken(String key) {
        return key != null && key.matches("ahna\\.[0-9a-fA-F]{32}\\.[0-9a-fA-F]{64}");
    }
}
