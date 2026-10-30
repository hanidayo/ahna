# 아나 (Ahna)

> 경상도 말로 "아나~" — 옛다, 받아라. 툭 건네듯 주고받는 앱입니다.

**한국어** · [English](#english)

Windows · Mac · iPhone/iPad · Android 사이에서 파일과 글자(클립보드)를 주고받습니다.
모두 **내 서버 하나**(Synology NAS 등의 Docker)에 초대 코드로 연결하고,

- 등록한 기기끼리는 서버를 거쳐 어디서나,
- 등록하지 않은 사람과는 **근처 기기(Bluetooth)** 로 확인 숫자를 보고,
- 앱이 없는 사람과는 **QR(브라우저)** 로 주고받습니다.

파일은 서버에 저장되지 않고 지나가기만 합니다(공유 메뉴에서 근처 기기로 보낼 때만 잠깐 맡겼다가, 다 받거나 10분 뒤 지웁니다).

## 내 서버로 쓰기

1. 이 저장소를 포크합니다.
2. 서버(NAS)에 [`server/compose.yaml`](server/compose.yaml)로 컨테이너를 띄웁니다 — [서버 설치 안내](server/서버-설치안내.md).
3. 포크한 저장소 Settings › Secrets › Actions에 비밀값을 넣습니다.
   - `AHNA_SERVER` : 서버 주소 (예: `https://example.synology.me`)
   - `AHNA_PUBLISH_KEY` : 서버 `.env`의 `AHNA_PUBLISH_KEY`와 같은 값
   - `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEY_PASSWORD` : 안드로이드 서명 키(별칭 `ahna`)
   - `RELEASES_TOKEN` : 앱 파일을 올릴 공개 배포 저장소(Releases)에 쓰기 권한이 있는 토큰. 저장소 이름은 `release.yml`의 `RELEASES_REPO`
4. Actions › **release** › Run workflow (`version`: 1.0 처럼, `publish: true`) — 앱 파일은 배포 저장소의 Releases에, 업데이트 정보(latest.json)는 서버에 올라가고, 앱들은 6시간마다 업데이트를 확인합니다.
5. 내려받기 화면 `https://내서버/d` 주소와 초대 코드를 지인에게 알려 주세요.
6. 서버 `.env`에 `AHNA_ADMIN_PASSWORD`를 넣으면 관리자 페이지 `https://내서버/_ahna/admin` 에서 연결된 기기와 사용량을 보고, 기기별로 알림·초기화·차단하거나 하루 사용량 한도를 정할 수 있습니다.

| 폴더 | 내용 |
|---|---|
| `server/` | 서버(중계 · 초대 코드 연결 · 앱 업데이트 보관 · 내려받기 화면), Docker 이미지 `ghcr.io/hanidayo/ahna-relay` |
| `windows/` | Windows 앱 (.NET, 트레이 + 웹 화면, 설치 파일 하나) |
| `mac/` | Mac 앱 (SwiftUI + .NET 수신 구성요소) |
| `ios/` | iPhone · iPad 앱 + 공유 확장 (Sideloadly 등으로 설치) |
| `android/` | Android 앱 |

<a id="english"></a>
## English

[한국어](#아나-ahna)

Ahna ("here, catch!" in the Gyeongsang dialect of Korean) sends files and clipboard text between Windows, Mac, iPhone/iPad and Android.
Every device joins **your own server** (a Docker container, e.g. on a Synology NAS) with an invite code. Registered devices talk through the server from anywhere; unregistered people nearby are reached over **Bluetooth LE** with a 2-digit confirmation code; people without the app use a **QR code** in the browser. Files pass through the server and are not stored (except a short hand-off of up to 10 minutes when sending to a nearby device from a share sheet).

To run your own: fork, start the server with `server/compose.yaml`, set the repository secrets `AHNA_SERVER`, `AHNA_PUBLISH_KEY`, `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEY_PASSWORD`, `RELEASES_TOKEN` (write access to your public releases repository, see `RELEASES_REPO` in `release.yml`), then run the **release** workflow with `publish: true`. Apps check `{server}/_ahna/update/latest.json` every 6 hours; the download page is `{server}/d`. Set `AHNA_ADMIN_PASSWORD` in the server `.env` to enable the admin page at `{server}/_ahna/admin`: see connected devices and their traffic, send a notice, reset or block a device, and set a daily traffic limit.
