<#PSScriptInfo
.VERSION 2026.08.25
.GUID 42b17423-c407-4384-96bd-8aa338c885ba
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna lab token diagnostic aggregator envelope
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Show, step by step, where a Lab token exchange stops.
.DESCRIPTION
    Set-LabToken reports one sentence when the exchange fails, and for the
    commonest failure that sentence is misleading: it blames a stale code or the
    wrong proxy, which are the two things that produce a clean 403 rather than
    the message it prints. When the aggregator SEALED the reply and the client
    could not open it, the cause is on the client and none of that advice
    applies.

    This script prints every step between the code and the recovered token, so
    the failing one names itself:

      - which runtime and OS are asking, because the client is the half that
        varies across the hosts in a lab;
      - the HTTP status, which separates a refusal (403 -- the code really was
        wrong or expired) from a seal the client then failed to open (200);
      - the raw reply and how this PowerShell parsed it, since the envelope is
        read by key and a parser that returns a different dictionary type is
        the kind of difference that only shows up on one host;
      - the four envelope fields with their lengths, because
        Unprotect-LabTokenEnvelope returns an empty string SILENTLY when any of
        them is missing, which is indistinguishable from a failed decrypt in
        the message the operator sees;
      - the decrypt itself, with the real exception rather than the swallowed
        one.

    Read-only. It redeems a code, which the aggregator counts as an `ok`
    exchange and audits like any other, but stores nothing: no vault write, no
    config change, no token kept. The code stays redeemable until it rotates,
    so running this does not cost the operator the enrollment they were about
    to perform.
.PARAMETER LabToken
    The 6-character code from the Yuruna hosts dashboard's Lab token tile.
.PARAMETER CachingProxyService
    Address of the caching-proxy service whose dashboard showed the code. When
    omitted, the same resolution Set-LabToken uses is applied.
.PARAMETER TimeoutSeconds
    Per-request deadline for the exchange.
.EXAMPLE
    pwsh test/lab/Lab-Diag.ps1 k3v9qa

    Resolves the aggregator this host names and reports every step.
.EXAMPLE
    pwsh test/lab/Lab-Diag.ps1 k3v9qa -CachingProxyService 192.168.7.42

    Names the proxy explicitly, which is what to do when two labs are in reach
    and the question is which one the code belongs to.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$LabToken,
    [Parameter()][string]$CachingProxyService,
    [Parameter()][int]$TimeoutSeconds = 15
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# These four are pinned to the Go side (pool-aggregator-service/main.go,
# labEnvelopeLabel and labEnvelopeIters). They are restated here rather than
# imported so this script keeps reporting when the module that owns them is the
# thing that is wrong.
$EnvelopeLabel      = 'yuruna-lab-token|v1'
$EnvelopeIterations = 600000
$KeyBytes           = 32
$TagBytes           = 16

function Write-Step {
    <#
    .SYNOPSIS
        One aligned diagnostic line.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$Label, [Parameter()][AllowEmptyString()][string]$Value = '')
    Write-Information ("{0,-12}: {1}" -f $Label, $Value) -InformationAction Continue
}

$code = $LabToken.Trim().ToLowerInvariant()
if ($code -notmatch '^[a-z0-9]{6}$') {
    Write-Error "'$LabToken' is not a Lab token: expected the 6-character code (lowercase letters/digits) from the Yuruna hosts dashboard's 'Lab token' tile."
    exit 1
}

# --- REGION: What is asking
# The client is the half that varies. A lab runs one aggregator and many hosts,
# so "which runtime opened it" is the first thing worth knowing when one host
# succeeds and another does not.
Write-Step 'PowerShell' "$($PSVersionTable.PSVersion) on $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription.Trim())"
Write-Step 'AesGcm' "IsSupported=$([System.Security.Cryptography.AesGcm]::IsSupported)"

# --- REGION: Resolve the aggregator
$base = ''
if (-not [string]::IsNullOrWhiteSpace($CachingProxyService)) {
    $address = $CachingProxyService.Trim()
    $urlHost = if ($address.Contains(':') -and -not $address.StartsWith('[')) { "[$address]" } else { $address }
    $base = "https://${urlHost}:9400"
    Write-Step 'aggregator' "$base (from -CachingProxyService)"
} else {
    Import-Module (Join-Path $PSScriptRoot '../modules/Test.CachingProxyService.psm1') -Global -Force -DisableNameChecking
    $base = Get-PoolAggregatorServiceSeedUrl -MaxWaitSeconds 30
    if (-not $base) {
        Write-Error 'No caching-proxy service this host names answered on :9400; pass -CachingProxyService <address>.'
        exit 1
    }
    Write-Step 'aggregator' "$base (resolved from this host's configuration)"
}
$url = "$($base.TrimEnd('/'))/api/v1/lab-token"

# --- REGION: The exchange
# -NoProxy deliberately: routing the request for the proxy's own aggregator
# through that proxy is how a lab ends up debugging squid instead of the token.
$body = @{ labToken = $code } | ConvertTo-Json -Compress
try {
    $resp = Invoke-WebRequest -Uri $url -Method Post -Body $body -ContentType 'application/json' `
        -TimeoutSec $TimeoutSeconds -SkipCertificateCheck -SkipHttpErrorCheck -MaximumRedirection 0 -NoProxy
} catch {
    Write-Step 'HTTP' "no answer -- $($_.Exception.Message)"
    Write-Information 'The aggregator did not answer. Check the address and that pool-aggregator-service is running on it.' -InformationAction Continue
    exit 1
}
$status = [int]$resp.StatusCode
Write-Step 'HTTP' $status
Write-Step 'raw body' "$($resp.Content)"

if ($status -ne 200) {
    # 403 is the honest "wrong or expired code" the top-level message describes;
    # everything else names itself in the body.
    Write-Information '' -InformationAction Continue
    switch ($status) {
        403 { Write-Information 'The aggregator REFUSED the code: it is unknown or expired. Re-read the tile and retry -- this is the case Set-LabToken''s message is written for.' -InformationAction Continue }
        429 { Write-Information 'This address burned its failed-attempt budget. Wait for the window to pass rather than retrying.' -InformationAction Continue }
        503 { Write-Information 'The exchange is disabled on that aggregator: rotation is off, or the proxy holds no internal authentication key to hand out.' -InformationAction Continue }
        default { Write-Information "Unexpected status $status; the body above is the aggregator's own account." -InformationAction Continue }
    }
    exit 1
}

# --- REGION: How this runtime parsed the envelope
$doc = $null
try {
    $doc = $resp.Content | ConvertFrom-Json -AsHashtable
} catch {
    Write-Step 'parsed as' "FAILED -- $($_.Exception.Message)"
    exit 1
}
Write-Step 'parsed as' $doc.GetType().FullName
Write-Step 'keys' (($doc.Keys | Sort-Object) -join ', ')

# The four fields the unseal needs. A missing one is why
# Unprotect-LabTokenEnvelope can return '' without ever attempting a decrypt --
# the silent path behind the "did not unseal" message.
$missing = @()
foreach ($field in @('salt', 'nonce', 'ciphertext', 'tag')) {
    $value = $doc[$field]
    if (-not $value) { $missing += $field }
    Write-Step "  $field" ("present={0} len={1}" -f [bool]$value, $(if ($value) { "$value".Length } else { 0 }))
}
if ($missing.Count) {
    Write-Information '' -InformationAction Continue
    Write-Information "The reply is missing $($missing -join ', '), so the client returns an empty token WITHOUT attempting a decrypt. The aggregator answered 200 and sealed something, so this is a shape mismatch between that daemon's reply and this client -- not a wrong code." -InformationAction Continue
    exit 1
}

# --- REGION: The decrypt, with the exception surfaced
try {
    $salt   = [Convert]::FromBase64String([string]$doc['salt'])
    $nonce  = [Convert]::FromBase64String([string]$doc['nonce'])
    $cipher = [Convert]::FromBase64String([string]$doc['ciphertext'])
    $tag    = [Convert]::FromBase64String([string]$doc['tag'])
} catch {
    Write-Step 'base64' "FAILED -- $($_.Exception.Message)"
    exit 1
}
Write-Step 'byte lens' ("salt={0} nonce={1} ciphertext={2} tag={3}" -f $salt.Length, $nonce.Length, $cipher.Length, $tag.Length)

try {
    $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
        $code, $salt, $EnvelopeIterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try { $key = $kdf.GetBytes($KeyBytes) } finally { $kdf.Dispose() }

    # The same two-constructor shim the module uses: the (key, tagSize) form is
    # the current one, and an older runtime has only the single-argument form.
    $aes = try { [System.Security.Cryptography.AesGcm]::new($key, $TagBytes) }
           catch [System.Management.Automation.MethodException] { [System.Security.Cryptography.AesGcm]::new($key) }
    $plain = [byte[]]::new($cipher.Length)
    try {
        $aes.Decrypt($nonce, $cipher, $tag, $plain, [System.Text.Encoding]::UTF8.GetBytes($EnvelopeLabel))
    } finally { $aes.Dispose(); [Array]::Clear($key, 0, $key.Length) }
    $length = $plain.Length
    [Array]::Clear($plain, 0, $plain.Length)
    Write-Step 'UNSEAL' "OK -- recovered $length bytes"
    Write-Information '' -InformationAction Continue
    Write-Information 'The exchange works from this host. If Set-LabToken still fails here, the difference is in what it does AFTER the exchange -- run it with -Verbose and compare.' -InformationAction Continue
} catch {
    # The one line the operator never sees otherwise: the module swallows this
    # into a Write-Verbose and returns ''.
    Write-Step 'UNSEAL' "FAILED -- $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    Write-Information '' -InformationAction Continue
    Write-Information "The aggregator sealed a reply this client cannot open. The code was accepted, so re-reading the tile will not help. Compare the PowerShell and OS line above against a host where the exchange succeeds; a CryptographicException here means the derived key differs, which means the two sides disagree on the code, the iteration count ($EnvelopeIterations) or the label ('$EnvelopeLabel')." -InformationAction Continue
    exit 1
}
