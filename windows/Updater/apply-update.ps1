# 아나 자동 업데이트 적용 스크립트 (UpdateService가 %TEMP%에서 실행)
param(
    [Parameter(Mandatory)][int]$ProcessId,
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][string]$Version
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $env:TEMP 'Ahna-update.log'
function Log($m) { Add-Content -LiteralPath $log -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) -Encoding UTF8 }

try {
    Log "v$Version 업데이트 시작: $Source -> $Destination"
    $expectedParent = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs'))
    $dest = [IO.Path]::GetFullPath($Destination)
    if ([IO.Path]::GetDirectoryName($dest) -ne $expectedParent) { throw "설치 폴더가 예상 위치가 아닙니다: $dest" }
    if (-not (Test-Path -LiteralPath (Join-Path $Source 'Ahna.exe'))) { throw '새 패키지에 Ahna.exe가 없습니다.' }

    # 1) 실행 중인 아나가 종료되기를 최대 60초 기다립니다.
    try { Wait-Process -Id $ProcessId -Timeout 60 -ErrorAction SilentlyContinue } catch {}
    $exe = Join-Path $dest 'Ahna.exe'
    $others = Get-Process Ahna -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }
    if ($others) { $others | Stop-Process -Force; Start-Sleep -Seconds 2 }

    # 2) 현재 설치본을 백업한 뒤 새 파일을 복사합니다. 실패하면 백업에서 복원합니다.
    $backup = Join-Path $env:TEMP ("Ahna-backup-" + (Get-Date -Format 'yyyyMMddHHmmss'))
    Copy-Item -LiteralPath $dest -Destination $backup -Recurse -Force
    try {
        Copy-Item -Path (Join-Path $Source '*') -Destination $dest -Recurse -Force
        Get-ChildItem -LiteralPath $dest -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
    } catch {
        Log "복사 실패, 복원합니다: $($_.Exception.Message)"
        Copy-Item -Path (Join-Path $backup '*') -Destination $dest -Recurse -Force
        throw
    }

    # 3) 탐색기 우클릭 메뉴가 등록돼 있으면 새 실행 파일로 다시 등록합니다.
    if ((Test-Path -LiteralPath 'HKCU:\Software\Classes\*\shell\Ahna') -or (Test-Path -LiteralPath 'HKCU:\Software\Classes\Directory\shell\Ahna')) {
        $p = Start-Process -FilePath $exe -ArgumentList '--register-explorer' -WorkingDirectory $dest -WindowStyle Hidden -Wait -PassThru
        Log "우클릭 메뉴 재등록 종료 코드: $($p.ExitCode)"
    }

    # 4) 다시 실행
    Start-Process -FilePath $exe -ArgumentList '--background' -WorkingDirectory $dest
    Log "v$Version 업데이트 완료"
    Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
} catch {
    Log ("업데이트 실패: " + $_.Exception.Message)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("아나 업데이트에 실패했습니다.`n$($_.Exception.Message)`n`n기존 버전을 다시 실행합니다. 로그: $log", '아나 업데이트') | Out-Null
        $old = Join-Path $Destination 'Ahna.exe'
        if (Test-Path -LiteralPath $old) { Start-Process -FilePath $old -ArgumentList '--background' }
    } catch {}
    exit 1
}
