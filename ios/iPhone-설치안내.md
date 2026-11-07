0.4.0 업데이트: 자동 저장과 Sideloadly용 IPA 생성은 시작하기-자동저장-Sideloadly.txt를 먼저 확인하세요.

# iPhone 공유 메뉴 앱

이 폴더는 **iOS/iPadOS 17 이상, Xcode 16 이상**용 네이티브 앱과 공유 확장 프로젝트입니다. Safari 없이 사진·파일 앱의 **공유 → 아나 → Windows 이름 선택**으로 파일을 보냅니다. Apple AirDrop의 기기 목록에 Windows를 추가하는 앱은 아닙니다.

완성된 소스와 Xcode 프로젝트를 제공합니다. **현재 Windows 환경에서는 Xcode 빌드·코드 서명·실제 iPhone 공유 메뉴 실행을 검증할 수 없었습니다.** 서명된 IPA나 App Store 앱으로 배포된 상태가 아닙니다.

## Mac에서 설치

1. Mac에 Xcode를 설치하고 한 번 실행합니다.
2. 배포본 전체를 Mac으로 복사한 뒤 `ios/Ahna.xcodeproj`를 엽니다. 별도 라이브러리, CocoaPods, XcodeGen은 필요 없습니다.
3. Xcode → Settings → Accounts에서 본인의 Apple 계정을 추가합니다. 비밀번호·인증은 직접 입력합니다.
4. 왼쪽 프로젝트를 선택하고 **아나, AhnaShare 두 타깃 모두** Signing & Capabilities에서 Automatically manage signing을 켜고 같은 Personal Team을 선택합니다.
5. Bundle Identifier는 본인만 쓰는 값으로 지정합니다. 예: 앱 `com.hanidayo.ahna`, 공유 확장 `com.hanidayo.ahna.share`. 확장 ID는 반드시 앱 ID에 `.share`를 붙인 형태여야 합니다. 이미 등록된 ID 오류가 나면 둘 모두 본인 고유 값으로 바꿉니다.
6. USB로 iPhone을 연결하고 필요한 기기 신뢰·개발자 모드 안내를 직접 승인합니다.
7. 실행 대상을 iPhone으로, Scheme을 **아나**로 선택하고 ▶ Run을 누릅니다. 앱 안에 공유 확장이 함께 설치됩니다.

무료 Personal Team은 실제 기기 테스트에 사용할 수 있지만 프로비저닝이 7일 후 만료됩니다. 만료되면 같은 Xcode 프로젝트에서 다시 빌드·설치해야 합니다. [Apple 계정 안내](https://developer.apple.com/help/account/basics/about-your-developer-account).

## 첫 연결

서버는 `../server/서버-설치안내.md`대로 설치하고 Windows의 서버 연결을 먼저 켭니다.

1. iPhone의 아나 앱을 엽니다.
2. 주소 `https://example.synology.me`와 Windows 아나 화면의 6자리 연결 코드를 입력합니다.
3. 연결되면 Windows 컴퓨터 이름과 도착한 파일이 표시됩니다. 연결 코드는 서버 관리자 암호와 다릅니다.
4. 같은 Wi-Fi에서 서버 없이 사용할 때는 Windows의 `http://192.168.…:45851` 주소로 연결할 수도 있습니다. 첫 로컬 네트워크 권한 요청은 **아나 본체 앱에서 먼저** 허용합니다. 공유 확장만 먼저 열면 iOS가 로컬 연결을 차단할 수 있습니다.

0.4.4 소스는 본체와 공유 확장이 같은 Keychain 접근 그룹을 사용합니다. **본체에서 컴퓨터와 기기 이름을 설정하고 공유 메뉴에서는 같은 목록을 읽습니다.** 먼저 본체를 열어 기존 연결을 이전하세요. 두 타깃이 동일 그룹 권한으로 서명돼야 하며, 실제 무료 계정 서명과 기기 접근은 Mac에서 확인해야 합니다. 자세한 내용은 `본체공유통합-0.4.4.txt`에 있습니다. 네이티브 연결은 마지막 사용 후 최대 30일 유지되며 Windows의 기기 해제로 취소할 수 있습니다.

## iPhone → Windows

1. 사진 또는 파일 앱에서 사진·문서·동영상을 선택하고 공유를 누릅니다.
2. 가로 앱 목록에서 **아나**를 선택합니다. 안 보이면 ‘더 보기’에서 아나를 즐겨찾기에 추가합니다.
3. 처음에는 주소와 연결 코드를 입력합니다. 이후 켜져 있는 Windows 이름이 표시됩니다.
4. 해당 Windows를 누르면 전송합니다. 전송 완료 뒤 ‘완료’를 누릅니다. 전송 중 공유 창을 닫으면 중단됩니다.

파일 앱의 실제 파일과 사진의 파일 표현을 읽습니다. 텍스트·웹 주소만 공유하는 화면에는 표시하지 않습니다. 제공 앱이 파일 표현을 내주지 못하는 항목은 파일 앱에 저장한 뒤 다시 공유합니다. 공유 확장에서는 한 번에 최대 256개 최상위 항목, 파일당 4 GiB, 폴더 안 최대 10,000개 항목·깊이 64를 검사합니다. iOS 확장의 실행 시간·메모리 제한 때문에 매우 큰 전송은 본체 앱의 파일 선택을 권장합니다. 빈 폴더만 보내는 것은 지원하지 않습니다.

Windows에는 날짜·임의 코드의 전송별 폴더 없이 받은 파일이 설정 폴더 바로 아래에 저장됩니다. 폴더를 선택한 경우에만 원래 하위 경로를 보존하고, 같은 이름은 `(1)`처럼 구분합니다.

## Windows → iPhone

1. iPhone **아나 앱을 열어 둡니다.** Safari는 필요 없습니다.
2. Windows에서 파일 우클릭 → 아나로 보내기, 또는 Windows 공유 → 아나를 선택합니다.
3. 기기 목록의 **나의 iPhone · 앱**을 선택합니다.
4. 파일 앱의 아나 폴더에 자동 저장합니다. 사진·동영상은 사진 추가 권한을 허용하면 사진 앱에도 추가합니다. 폴더는 ZIP으로 받습니다.

iPhone 앱이 닫히거나 오랫동안 연결이 끊기면 Windows 목록에서 사라집니다. 푸시·백그라운드 자동 수신은 이번 버전에 포함하지 않았습니다. 파일은 준비 후 최대 24시간 또는 Windows 앱이 종료될 때까지 제공됩니다.

## Mac 검증

Xcode에서 Product → Build로 두 타깃의 컴파일을 확인합니다. 터미널에서 소스 폴더 기준 다음 명령으로 서명 없이 시뮬레이터용 빌드를 검사할 수도 있습니다.

```sh
xcodebuild -project Ahna.xcodeproj -scheme 아나 -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

`Mac에서빌드.command`에도 같은 명령이 있습니다. 실행 권한이 없으면 Mac 터미널에서 `bash Mac에서빌드.command`로 실행합니다. 마지막에는 실제 iPhone에서 사진·파일 공유, Windows 온라인/오프라인, 양방향 파일 저장과 취소를 시험해야 합니다.

참고: [Apple 공유 확장](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Share.html), [공유 파일 임시 URL의 수명](https://developer.apple.com/documentation/foundation/nsitemprovider/loadfilerepresentation(fortypeidentifier:completionhandler:)), [로컬 네트워크 권한](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).
