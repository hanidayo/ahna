; 아나 Windows 설치 파일 (Inno Setup 6) — 파일 하나로 설치 · 바로가기 '아나' · 우클릭 메뉴 · 실행
; CI: ISCC /DAppVersion=1.0.2 /DSourceDir=<publish 폴더> windows\installer\Ahna.iss
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\out\app"
#endif

[Setup]
AppId={{9C2F7D44-6A1B-4E83-B5D0-3F8E21C7A6B3}
AppName=아나
AppVerName=아나 {#AppVersion}
AppVersion={#AppVersion}
AppPublisher=Ahna Open
DefaultDirName={localappdata}\Programs\AhnaOpen
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputBaseFilename=Ahna-Setup
SetupIconFile=..\app.ico
UninstallDisplayIcon={app}\AhnaOpen.exe
UninstallDisplayName=아나
Compression=lzma2/max
SolidCompression=yes
CloseApplications=force
RestartApplications=no
WizardStyle=modern

[Languages]
#if FileExists(CompilerPath + "Languages\Korean.isl")
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
#else
Name: "english"; MessagesFile: "compiler:Default.isl"
#endif

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{userdesktop}\아나 Open"; Filename: "{app}\AhnaOpen.exe"; Parameters: "--open"; WorkingDir: "{app}"
Name: "{userprograms}\아나 Open"; Filename: "{app}\AhnaOpen.exe"; Parameters: "--open"; WorkingDir: "{app}"

[Registry]
; 앱이 만드는 항목 — 제거할 때 함께 지웁니다(설치 때 새로 만들지는 않음).
Root: HKCU; Subkey: "Software\Classes\*\shell\AhnaOpen"; Flags: uninsdeletekey dontcreatekey
Root: HKCU; Subkey: "Software\Classes\Directory\shell\AhnaOpen"; Flags: uninsdeletekey dontcreatekey
Root: HKCU; Subkey: "Software\Classes\CLSID\{{9C2F7D44-6A1B-4E83-B5D0-3F8E21C7A6B2}"; Flags: uninsdeletekey dontcreatekey
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "AhnaOpen"; Flags: uninsdeletevalue dontcreatekey

[Run]
Filename: "{app}\AhnaOpen.exe"; Parameters: "--register-explorer"; Flags: runhidden waituntilterminated
Filename: "{app}\AhnaOpen.exe"; Parameters: "--open"; Description: "아나 실행"; Flags: nowait postinstall

[InstallDelete]
; 예전 압축 파일 설치가 만든 영어 이름 바로가기
Type: files; Name: "{userdesktop}\Ahna.lnk"
Type: files; Name: "{userprograms}\Ahna.lnk"
