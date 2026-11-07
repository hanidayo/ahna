package me.ahna;

/** 아나 앱 정보. 서버 주소는 앱을 처음 실행할 때 초대 코드와 함께 사용자가 넣고, 설정(prefs "server")에 저장됩니다. */
final class Brand {
    /** 지금 쓰는 서버 주소(https://호스트[:포트]). 앱이 시작할 때 설정에서 읽어 둡니다. 없으면 빈 문자열. */
    static volatile String server = "";
    /** 업데이트를 확인할 GitHub 저장소(소유자/이름). 빌드할 때 scripts/set_repo.py가 넣습니다. 그대로면 업데이트 확인을 하지 않습니다. */
    static final String UPDATE_REPO = "OWNER/REPO";
    static boolean updates() { return !UPDATE_REPO.startsWith("OWNER/"); }
    private Brand() {}
    /** 설정에서 서버 주소를 읽어 둡니다. */
    static void load(android.content.SharedPreferences prefs) { server = prefs.getString("server", ""); }
    /** 사용자가 넣은 주소를 https://호스트[:포트] 꼴로 맞춥니다. 올바르지 않으면 null. */
    static String normalize(String input) {
        String text = input == null ? "" : input.trim();
        while (text.endsWith("/")) text = text.substring(0, text.length() - 1);
        if (text.isEmpty()) return null;
        if (!text.contains("://")) text = "https://" + text;
        try {
            java.net.URI uri = new java.net.URI(text);
            if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null || uri.getHost().isEmpty() || uri.getRawUserInfo() != null || uri.getRawQuery() != null || uri.getRawFragment() != null) return null;
            String path = uri.getRawPath();
            if (path != null && !path.isEmpty() && !path.equals("/")) return null;
            return "https://" + uri.getHost().toLowerCase(java.util.Locale.ROOT) + (uri.getPort() > 0 ? ":" + uri.getPort() : "");
        } catch (java.net.URISyntaxException e) { return null; }
    }
    /** ahna.{기기 ID 32자}.{64자} */
    static boolean isMemberToken(String key) {
        return key != null && key.matches("ahna\\.[0-9a-fA-F]{32}\\.[0-9a-fA-F]{64}");
    }
}
