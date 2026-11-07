; 아나 Windows 설치 파일 (Inno Setup 6) — 파일 하나로 설치 · 바로가기 '아나' · 우클릭 메뉴 · 실행
; CI: ISCC /DAppVersion=1.0.2 /DSourceDir=<publish 폴더> windows\installer\Ahna.iss
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\out\app"
#endif

[Setup]
AppId={{5B8E2A61-3D47-4C19-A0F2-9E64C7D1B3A9}
AppName=아나
AppVerName=아나 {#AppVersion}
AppVersion={#AppVersion}
AppPublisher=Hanidayo
DefaultDirName={localappdata}\Programs\Ahna
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputBaseFilename=Ahna-Setup
SetupIconFile=..\app.ico
UninstallDisplayIcon={app}\Ahna.exe
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
Name: "{userdesktop}\아나"; Filename: "{app}\Ahna.exe"; Parameters: "--open"; WorkingDir: "{app}"
Name: "{userprograms}\아나"; Filename: "{app}\Ahna.exe"; Parameters: "--open"; WorkingDir: "{app}"

[Registry]
; 앱이 만드는 항목 — 제거할 때 함께 지웁니다(설치 때 새로 만들지는 않음).
Root: HKCU; Subkey: "Software\Classes\*\shell\Ahna"; Flags: uninsdeletekey dontcreatekey
Root: HKCU; Subkey: "Software\Classes\Directory\shell\Ahna"; Flags: uninsdeletekey dontcreatekey
Root: HKCU; Subkey: "Software\Classes\CLSID\{{5B8E2A61-3D47-4C19-A0F2-9E64C7D1B3A8}"; Flags: uninsdeletekey dontcreatekey
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "Ahna"; Flags: uninsdeletevalue dontcreatekey

[Run]
Filename: "{app}\Ahna.exe"; Parameters: "--register-explorer"; Flags: runhidden waituntilterminated
Filename: "{app}\Ahna.exe"; Parameters: "--open"; Description: "아나 실행"; Flags: nowait postinstall

[InstallDelete]
; 예전 압축 파일 설치가 만든 영어 이름 바로가기
Type: files; Name: "{userdesktop}\Ahna.lnk"
Type: files; Name: "{userprograms}\Ahna.lnk"
