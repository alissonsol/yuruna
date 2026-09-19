<#PSScriptInfo
.VERSION 2026.09.18
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
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
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_cfb961598a0d955c' -Arguments @{ labToken = "$LabToken" })
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
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_d451371262f4e3e2')
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
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_6cc6790657c7d400') -InformationAction Continue
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
        403 { Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_928f54451845a095') -InformationAction Continue }
        429 { Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_c99eebdec002d085') -InformationAction Continue }
        503 { Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b8f7937cfa63542e') -InformationAction Continue }
        default { Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_ceb9c8d34ff7be5a' -Arguments @{ status = "$status" }) -InformationAction Continue }
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
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_4372d93586546ebc' -Arguments @{ join = "$($missing -join ', ')" }) -InformationAction Continue
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
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_76a64f58ea384d2f') -InformationAction Continue
} catch {
    # The one line the operator never sees otherwise: the module swallows this
    # into a Write-Verbose and returns ''.
    Write-Step 'UNSEAL' "FAILED -- $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    Write-Information '' -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_767a42e435b5f2c7' -Arguments @{ envelopeIterations = "$EnvelopeIterations"; envelopeLabel = "$EnvelopeLabel" }) -InformationAction Continue
    exit 1
}
