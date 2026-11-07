$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$destination = Join-Path $env:LOCALAPPDATA 'Programs\Ahna'
$exe = Join-Path $destination 'Ahna.exe'
try {
    $session = (Get-Process -Id $PID).SessionId
    $running = Get-Process Ahna -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session }
    if ($running) { throw '다른 폴더의 구버전을 포함해 실행 중인 아나를 모두 트레이에서 종료한 뒤 다시 설치해 주세요.' }
    $fresh = -not (Test-Path -LiteralPath (Join-Path $destination 'Ahna.exe'))
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Copy-Item -Path (Join-Path $PSScriptRoot 'app\*') -Destination $destination -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Uninstall.ps1') -Destination (Join-Path $destination 'Uninstall.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '제거.cmd') -Destination (Join-Path $destination '제거.cmd') -Force
    # Files extracted from a downloaded ZIP carry a 'downloaded from the internet' mark that makes Windows
    # show a hidden security prompt (reported as 'operation canceled by the user'). Clear it.
    Get-ChildItem -LiteralPath $destination -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
    $shell = New-Object -ComObject WScript.Shell
    foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
        # 예전 시험판의 영어 이름 바로가기는 지웁니다.
        $old = Join-Path $folder 'Ahna.lnk'
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
        $shortcut = $shell.CreateShortcut((Join-Path $folder '아나.lnk'))
        $shortcut.TargetPath = $exe
        $shortcut.Arguments = '--open'
        $shortcut.WorkingDirectory = $destination
        $shortcut.Save()
    }
    # Keep previously enabled integrations attached to the installed executable.
    $run = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run', $true)
    if ($run) {
        try { if ($run.GetValue('Ahna')) { $run.SetValue('Ahna', ('"' + $exe + '" --background')) } }
        finally { $run.Dispose() }
    }
    $fileMenu = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Classes\*\shell\Ahna')
    $folderMenu = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Classes\Directory\shell\Ahna')
    # 처음 설치하면 탐색기 우클릭 메뉴 '아나로 보내기'를 켭니다.
    $updateMenu = $fresh -or $null -ne $fileMenu -or $null -ne $folderMenu
    if ($fileMenu) { $fileMenu.Dispose() }; if ($folderMenu) { $folderMenu.Dispose() }
    if ($updateMenu) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = '--register-explorer'
        $psi.WorkingDirectory = $destination
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $registered = [System.Diagnostics.Process]::Start($psi)
        $registered.WaitForExit()
        if ($registered.ExitCode -ne 0) { throw '아나 우클릭 메뉴 등록에 실패했습니다.' }
    }
    [System.Windows.Forms.MessageBox]::Show("설치가 완료되었습니다.`n바탕 화면의 아나 바로가기를 실행하세요.", '아나') | Out-Null
} catch {
    $detail = $_.Exception.Message + "`n`n[진단] 줄 " + $_.InvocationInfo.ScriptLineNumber + ": " + $_.InvocationInfo.Line.Trim() + "`n형식: " + $_.Exception.GetType().FullName + "`n위치: " + $_.InvocationInfo.ScriptName
    try { Set-Content -LiteralPath (Join-Path $env:TEMP 'Ahna-install-error.txt') -Value ($detail + "`n`n" + ($_ | Out-String)) -Encoding UTF8 } catch {}
    [System.Windows.Forms.MessageBox]::Show($detail, '아나 설치 실패') | Out-Null
    exit 1
}
