$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$destination = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs\Ahna'))
$expectedParent = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs'))
if ([IO.Path]::GetDirectoryName($destination) -ne $expectedParent -or [IO.Path]::GetFileName($destination) -ne 'Ahna') { throw '안전한 제거 경로가 아닙니다.' }
try {
    if (Get-Process Ahna -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $destination 'Ahna.exe') }) { throw '아나를 트레이에서 종료한 뒤 다시 제거해 주세요.' }
    $answer = [System.Windows.Forms.MessageBox]::Show("아나 프로그램과 바로가기를 제거할까요?`n받은 파일, 저장 경로 설정, 전송 기록은 유지됩니다.", '아나 제거', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { exit 0 }
    $sharePackage=Get-AppxPackage -Name 'Ahna.Desktop'
    if($sharePackage){$sharePackage | Remove-AppxPackage -ErrorAction Stop}
    $thumbFile=Join-Path $destination 'share-certificate-thumbprint.txt'
    if(Test-Path -LiteralPath $thumbFile){
        $thumb=([IO.File]::ReadAllText($thumbFile)).Trim()
        $store=New-Object Security.Cryptography.X509Certificates.X509Store('TrustedPeople','CurrentUser')
        try{
            $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            foreach($certificate in @($store.Certificates | Where-Object {$_.Thumbprint -eq $thumb -and $_.Subject -eq 'CN=AhnaLocal'})){$store.Remove($certificate)}
        }finally{$store.Dispose()}
        $machine=New-Object Security.Cryptography.X509Certificates.X509Store('TrustedPeople','LocalMachine')
        try{
            $machine.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
            $machineTrusted=@($machine.Certificates|Where-Object{$_.Thumbprint -eq $thumb -and $_.Subject -eq 'CN=AhnaLocal'}).Count -gt 0
        }finally{$machine.Dispose()}
        if($machineTrusted){
            $helper=Join-Path $destination 'Set-WindowsShareTrust.ps1'
            $publicCert=Join-Path $destination 'ShareRegistration\Ahna.Public.cer'
            $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$helper+'" -CertificatePath "'+$publicCert+'" -ExpectedThumbprint "'+$thumb+'" -Remove'
            $removed=Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
            if($removed.ExitCode -ne 0){throw '공유 인증서 제거가 완료되지 않았습니다. 관리자 승인을 확인하고 다시 실행해 주세요.'}
        }
    }
    Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Ahna' -ErrorAction SilentlyContinue
    foreach ($key in @('HKCU:\Software\Classes\*\shell\Ahna','HKCU:\Software\Classes\Directory\shell\Ahna','HKCU:\Software\Classes\CLSID\{5B8E2A61-3D47-4C19-A0F2-9E64C7D1B3A8}')) {
        if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force }
    }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
        $link = Join-Path $folder '아나.lnk'
        if ((Test-Path -LiteralPath $link) -and $shell.CreateShortcut($link).TargetPath -eq (Join-Path $destination 'Ahna.exe')) { Remove-Item -LiteralPath $link -Force }
    }
    if (Test-Path -LiteralPath $destination) {
        $item = Get-Item -LiteralPath $destination
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '연결 폴더는 자동 제거하지 않습니다.' }
        Remove-Item -LiteralPath $destination -Recurse -Force
    }
    [System.Windows.Forms.MessageBox]::Show('아나 제거가 완료되었습니다. 받은 파일은 유지됩니다.', '아나') | Out-Null
} catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '아나 제거 실패') | Out-Null
    exit 1
}
