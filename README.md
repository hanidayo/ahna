# 아나 (Ahna)

> 경상도 말로 "아나~" — 옛다, 받아라. 툭 건네듯 주고받는 앱입니다.

**한국어** · [English](#english)

Windows · Mac · iPhone/iPad · Android 사이에서 **파일과 글자(클립보드)**를 주고받는 앱입니다.
직접 운영하는 **내 서버 하나**에 기기들을 초대 코드로 연결해서 씁니다. 다른 회사 서버를 거치지 않습니다.

## 이렇게 주고받습니다

| 상황 | 방법 |
|---|---|
| 내 기기끼리 (같은 Wi-Fi) | 서버를 거치지 않고 **기기끼리 바로**, 암호화해서 보냅니다 |
| 내 기기끼리 (다른 곳) | 내 서버를 거쳐 보냅니다. 파일은 서버에 저장되지 않고 지나가기만 합니다 |
| 등록하지 않은 사람 (옆에 있을 때) | **근처 기기(Bluetooth)**로 찾아서, 양쪽 화면의 확인 숫자를 보고 보냅니다 |
| 앱이 없는 사람 | **QR 코드**를 찍으면 브라우저에서 바로 받거나 보냅니다(글자도 됩니다) |

그 밖에
- 탐색기·Finder·공유 메뉴에서 바로 보내기
- 받은 글자 기록, 보낸·받은 내역
- 관리자 페이지: 연결된 기기·사용량 보기, 공지 보내기, 기기 차단·초기화, 하루 사용량 한도
- 새 버전 알림(이 저장소의 Releases를 확인)

## 시작하기

**1. 서버 만들기** — 한 사람(관리자)이 한 번만 합니다.
- 리눅스(우분투) 컴퓨터: [docs/서버-우분투.md](docs/서버-우분투.md)
- 시놀로지 NAS: [docs/서버-시놀로지.md](docs/서버-시놀로지.md)

서버를 만들면 **서버 주소**(예: `https://ahna.example.com`)와 **초대 코드**가 생깁니다. 함께 쓸 사람에게 이 두 가지를 알려 주세요.

**2. 앱 설치하고 연결하기** — 쓰는 사람 모두
- [docs/앱-설치.md](docs/앱-설치.md)
- 설치 파일: 이 저장소의 **Releases**에 있습니다.
- 앱을 처음 열면 **서버 주소와 초대 코드**를 묻습니다. 넣으면 바로 시작합니다.

**3. (선택) 직접 빌드해서 배포하기**
- 이 저장소를 내 계정으로 복사(fork)해서 GitHub Actions로 설치 파일을 만들 수 있습니다: [docs/직접-빌드하기.md](docs/직접-빌드하기.md)

## 폴더

| 폴더 | 내용 |
|---|---|
| `server/` | 서버(중계 · 초대 코드 가입 · 관리자 페이지 · 내려받기 화면). Docker로 실행 |
| `windows/` | Windows 앱 (.NET, 트레이 + 화면, 설치 파일) |
| `mac/` | Mac 앱 (SwiftUI + .NET 수신 구성요소) |
| `ios/` | iPhone · iPad 앱 + 공유 확장 |
| `android/` | Android 앱 |
| `docs/` | 설치·운영 안내 |

## 개인정보

- 파일은 서버에 저장되지 않습니다. 단, 공유 메뉴에서 근처 기기로 보낼 때만 서버에 잠깐 맡겼다가 상대가 받거나 10분이 지나면 지웁니다.
- 서버에는 연결한 기기 이름·플랫폼·마지막 접속 시각·IP·하루 사용량만 남습니다(관리자 페이지에서 보입니다).
- 같은 Wi-Fi 직접 전송은 연결마다 새 키로 AES-256-GCM 암호화하며, 키는 서버(HTTPS)로만 주고받습니다.

---

<a id="english"></a>
## English

[한국어](#아나-ahna)

Ahna ("here, catch!" in the Gyeongsang dialect of Korean) sends files and clipboard text between Windows, Mac, iPhone/iPad and Android through **a server you run yourself**. Devices join the server with its address and an invite code.

- Your devices on the same Wi-Fi talk **directly** (encrypted, AES-256-GCM, keys exchanged over the server's HTTPS); elsewhere they go through your server, which streams files without storing them.
- People nearby without an account are reached over **Bluetooth LE** with a confirmation number; people without the app use a **QR code** in the browser.
- Admin page: connected devices and traffic, notices, block/reset a device, daily traffic limit.

Getting started
1. Run the server — Ubuntu: [docs/서버-우분투.md](docs/서버-우분투.md), Synology NAS: [docs/서버-시놀로지.md](docs/서버-시놀로지.md) (Korean). You get a **server address** and an **invite code**.
2. Install the apps from this repository's **Releases** and enter the server address and invite code on first launch ([docs/앱-설치.md](docs/앱-설치.md)).
3. To build your own releases, fork and run the **release** workflow in GitHub Actions ([docs/직접-빌드하기.md](docs/직접-빌드하기.md)). Apps check the forked repository's latest release for updates.
