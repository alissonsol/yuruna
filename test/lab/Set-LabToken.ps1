<#PSScriptInfo
.VERSION 2026.10.18
.GUID 42267d15-1bc0-481c-b068-2bb6d74f5ffb
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool lab auth admin
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Enroll THIS host in the lab: redeem the dashboard's Lab token for the
    internal authentication key and store it in the host vault (idempotent).
.DESCRIPTION
    See https://yuruna.link/42010605-0003.
.PARAMETER LabToken
    The 6-character code currently shown on the dashboard's "Lab token" tile
    (lowercase letters and digits; case and surrounding spaces are
    forgiven). It rotates every minute and stays redeemable for about three,
    so read it right before running.
.PARAMETER CachingProxyService
    Address (IP or name) of the caching-proxy service whose dashboard shows the Lab
    token. Only needed when this host's configuration does not already name
    one; when given (or prompted), it is persisted to vmStart.cachingProxyIp
    if this host has a test.config.yml to persist it into.
.PARAMETER BounceStatusService
    Restart the status service after storing, so the change is live now
    rather than at the next cycle.
.PARAMETER NonInteractive
    Never prompt; fail instead when the caching-proxy-service address cannot be
    resolved.
.EXAMPLE
    pwsh test/lab/Set-LabToken.ps1 -LabToken k3v9qa -BounceStatusService
.EXAMPLE
    pwsh test/lab/Set-LabToken.ps1 -LabToken k3v9qa -CachingProxyService 192.168.7.229
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)][string]$LabToken,
    [Parameter()][string]$CachingProxyService,
    [switch]$BounceStatusService,
    [switch]$NonInteractive,
    # Skip seeding pool.enabled / pool.configurationGitUrl into test.config.yml.
    # Enrollment is the natural moment to do it -- the operator is present and has
    # just named the proxy -- but a host that must stay standalone can opt out.
    [switch]$NoPoolConfig
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# --- REGION: Log level from environment
# See https://yuruna.link/42010605-0003
Import-Module (Join-Path $PSScriptRoot '../modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv
$InformationPreference = $global:InformationPreference

$elapsed = [System.Diagnostics.Stopwatch]::StartNew()

$code = $LabToken.Trim().ToLowerInvariant()
if ($code -notmatch '^[a-z0-9]{6}$') {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_cfb961598a0d955c' -Arguments @{ labToken = "$LabToken" })
    exit 1
}

# The authentication extension supplies Set-Password / Set-UserVaultKey /
# Test-VaultEntry; Test.ConfigServiceSync supplies the exchange client and the
# Set-InternalAuthKey orchestrator; Test.CachingProxyService resolves the aggregator
# address. -Global -Force mirrors Import-Extension so a nested import does
# not evict the module from the global scope.
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_48980b6f808557b6') -InformationAction Continue
Import-Module (Join-Path $PSScriptRoot '../extension/authentication/default.psm1') -Global -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../modules/Test.ConfigServiceSync.psm1') -Global -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../modules/Test.CachingProxyService.psm1') -Global -Force -DisableNameChecking

# --- REGION: Resolve the aggregator base URL
# See https://yuruna.link/42010605-0003
$addressSource = ''
$proxyAddress  = ''
$baseUrl       = ''
if (-not [string]::IsNullOrWhiteSpace($CachingProxyService)) {
    $proxyAddress  = $CachingProxyService.Trim()
    $addressSource = 'parameter'
} else {
    # -WhatIf is forwarded by hand because it does not cross into a module's
    # session state on its own, and resolving repairs a stored address that
    # loses its probe -- a write, and so not something a preview may do.
    $baseUrl = Get-PoolAggregatorServiceSeedUrl -MaxWaitSeconds 120 -WhatIf:$WhatIfPreference
    if ($baseUrl) { $addressSource = 'config' }
}
if (-not $proxyAddress -and -not $baseUrl) {
    if ($NonInteractive -or $WhatIfPreference) {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_e5743a075034e8df')
        exit 1
    }
    $proxyAddress = (Read-Host (Format-YurunaOperatorMessage -Key 'runner.operator_cb9b171ea807c530')).Trim()
    if (-not $proxyAddress) {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_b718a7ce08dcb47b')
        exit 1
    }
    $addressSource = 'prompt'
}
if ($proxyAddress -and $proxyAddress -match "['\s]") {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_0755a0db79e510eb' -Arguments @{ proxyAddress = "$proxyAddress" })
    exit 1
}

# https first (a provisioned proxy mints the aggregator's TLS leaf in
# cloud-init), plain http as the transport-failure fallback -- the same
# candidate order the stash beacon uses against an older plain-HTTP proxy.
$candidates = if ($baseUrl) {
    @($baseUrl, ($baseUrl -replace '^https:', 'http:'))
} else {
    $urlHost = if ($proxyAddress.Contains(':') -and -not $proxyAddress.StartsWith('[')) { "[$proxyAddress]" } else { $proxyAddress }
    @("https://${urlHost}:9400", "http://${urlHost}:9400")
}

if ($WhatIfPreference) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_3af27ce65b56ffe2' -Arguments @{ code = "$code"; candidates = "$($candidates[0])" }) -InformationAction Continue
    exit 0
}

# --- REGION: Redeem the code for the internal authentication key
$verdict = $null
foreach ($base in $candidates) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_d21c646000412c32' -Arguments @{ base = "$base" }) -InformationAction Continue
    $verdict = Request-LabTokenExchange -AggregatorBaseUrl $base -LabToken $code
    # Only a transport failure falls through to the next scheme; an answered
    # refusal (403/429/503) is the aggregator's verdict and retrying the same
    # code over plain HTTP would just burn another audited attempt.
    if ($verdict.Ok -or $verdict.Status -ne 0) { break }
}
if (-not $verdict -or -not $verdict.Ok) {
    Write-Error $verdict.Error
    exit 1
}
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_316bf9d86a026e18') -InformationAction Continue

# --- REGION: Store + verify (the vault provisioning Set-InternalAuthKey owns)
$persistArgs = @{ Token = $verdict.Token; BounceStatusService = [bool]$BounceStatusService }
if ($PSBoundParameters.ContainsKey('Confirm')) { $persistArgs['Confirm'] = $PSBoundParameters['Confirm'] }
$provision = Set-InternalAuthKey @persistArgs

# --- REGION: Bind this host to the lab proxy
# Persist an operator-supplied address into vmStart.cachingProxyIp -- the key
# every aggregator-address consumer resolves last -- so the enrollment is the
# one-time step and later runs (and the runner itself) find the proxy on
# their own. A config-sourced address is already persistent; nothing to do.
if ($provision.ok -and $proxyAddress -and ($addressSource -in @('parameter', 'prompt'))) {
    $configPath = Join-Path $PSScriptRoot '../test.config.yml'
    try {
        Import-Module powershell-yaml -ErrorAction Stop
        Import-Module (Join-Path $PSScriptRoot '../modules/Test.StateFile.psm1')  -Global -Force -DisableNameChecking
        Import-Module (Join-Path $PSScriptRoot '../modules/Test.ConfigSync.psm1') -Force -DisableNameChecking
        if (Test-Path -LiteralPath $configPath) {
            $cfg = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Yaml -Ordered
            if ($null -eq $cfg) { $cfg = [ordered]@{} }
            if (-not ($cfg['vmStart'] -is [System.Collections.IDictionary])) { $cfg['vmStart'] = [ordered]@{} }
            $current = "$($cfg['vmStart']['cachingProxyIp'])".Trim()
            if ($current -eq $proxyAddress) {
                Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_d24bb1160e14f86a' -Arguments @{ proxyAddress = "$proxyAddress" }) -InformationAction Continue
            } else {
                $cfg['vmStart']['cachingProxyIp'] = $proxyAddress
                if (-not (Write-DocumentedTestConfig -ConfigPath $configPath -Config $cfg -Confirm:$false)) { throw 'Configuration update could not be written.' }
                Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_a7167078df8a485b' -Arguments @{ proxyAddress = "$proxyAddress" }) -InformationAction Continue
            }
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_4e417088d8a65a6f' -Arguments @{ proxyAddress = "$proxyAddress" })
        }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d2c7267220080f85' -Arguments @{ message = "$($_.Exception.Message)" })
    }
}

# --- REGION: Seed the pool configuration store binding
# See https://yuruna.link/42010605-0003
$poolHost = if ($proxyAddress) { $proxyAddress } elseif ($baseUrl) { ([uri]$baseUrl).Host } else { '' }
if ($provision.ok -and $poolHost -and -not $NoPoolConfig) {
    $configPath = Join-Path $PSScriptRoot '../test.config.yml'
    try {
        Import-Module powershell-yaml -ErrorAction Stop
        Import-Module (Join-Path $PSScriptRoot '../modules/Test.StateFile.psm1')  -Global -Force -DisableNameChecking
        Import-Module (Join-Path $PSScriptRoot '../modules/Test.ConfigSync.psm1') -Force -DisableNameChecking
        if (-not (Test-Path -LiteralPath $configPath)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_8e8fecb6ffc7d3d6')
        } else {
            $cfg = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Yaml -Ordered
            if ($null -eq $cfg) { $cfg = [ordered]@{} }
            if (-not ($cfg['pool'] -is [System.Collections.IDictionary])) { $cfg['pool'] = [ordered]@{} }
            $existingUrl = "$($cfg['pool']['configurationGitUrl'])".Trim()
            # The READ-ONLY http url. The writable path (a file:// or local
            # path to the bare repo) is for admin commands run ON the proxy;
            # a runner must never hold a writable remote.
            $configurationUrl = "http://$poolHost/pool-configuration.git"
            # See https://yuruna.link/42010605-0003
            $isOwnStaleSeed = $existingUrl -and
                              ($existingUrl -ne $configurationUrl) -and
                              ($existingUrl -match '^http://[^/]+/pool-configuration\.git$')
            if ($existingUrl -and -not $isOwnStaleSeed) {
                Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_416973ff9c4b82f2' -Arguments @{ existingUrl = "$existingUrl" }) -InformationAction Continue
            } else {
                if ($isOwnStaleSeed) {
                    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b5e4a53c200e2211' -Arguments @{ existingUrl = "$existingUrl"; configurationUrl = "$configurationUrl" }) -InformationAction Continue
                }
                $cfg['pool']['configurationGitUrl'] = $configurationUrl
                # enabled goes WITH the url: configurationGitUrl alone is inert, so
                # seeding one without the other would look configured and do
                # nothing.
                $cfg['pool']['enabled'] = $true
                if (-not (Write-DocumentedTestConfig -ConfigPath $configPath -Config $cfg -Confirm:$false)) { throw 'Configuration update could not be written.' }
                Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_e178d69f96491585' -Arguments @{ configurationUrl = "$configurationUrl" }) -InformationAction Continue
            }
        }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_413f257dbbf2120b' -Arguments @{ message = "$($_.Exception.Message)" })
    }
}

$took = "{0:N1}s" -f $elapsed.Elapsed.TotalSeconds
if ($provision.ok) {
    $msg = "Done in ${took}: internal authentication key stored and verified (vaultKey '$($provision.vaultKey)')."
    if ($provision.bounced) {
        $msg += ' Status service restarted, so the token is live now.'
    } elseif ($BounceStatusService) {
        $msg += ' Status-server bounce did not complete; the token takes effect at the next cycle.'
    } else {
        $msg += ' Re-run with -BounceStatusService (or wait for the next cycle) to make the running status service pick it up.'
    }
    Write-Information $msg -InformationAction Continue
    exit 0
}

Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_37b93ebce9b2bfe4' -Arguments @{ took = "${took}"; keyChanged = "$($provision.keyChanged)"; verified = "$($provision.verified)" })
exit 1
