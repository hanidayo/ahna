# 아나 (Ahna) — 작업 안내

- 답은 한국어로. 사용자는 Hanidayo(형님). 이 저장소는 **공개**입니다. 개인 서버 주소·초대 코드·키는 절대 소스나 문서에 넣지 않습니다(예시는 example.synology.me).
- 이름·코드·통신(X-Ahna-*, /_ahna/*)은 모두 Ahna로 씁니다.
- 서버 주소: 소스에는 예시 주소만 있고, CI가 비밀값 `AHNA_SERVER`로 `scripts/set_server.py`를 실행해 Brand(C# 2곳·Swift 2곳·Java 1곳)에 넣습니다.
- 공개 저장소이므로 빌드한 앱 파일을 Actions 아티팩트로 남기지 않습니다(정식 배포 때 서버로만 올림).
- `windows/Ahna/TransferServer.cs` 와 `src/TransferServer.cs` 는 같은 파일이어야 합니다.
- 화면 색: 바로드롭과 같은 파랑(라이트 #005FB8 · 다크 #4CC2FF, 바탕 #EEF1F5 · #1C1C1C), 근처 기기는 보라(#7C3AED · #A78BFA).
- 빌드는 GitHub Actions(release.yml). 로컬에는 .NET/Xcode가 없으니 CI 결과(annotations)로 확인합니다.
- 커밋 작성자는 Claude <noreply@anthropic.com>.
