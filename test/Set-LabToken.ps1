<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42b7c3f8-9a1d-4e62-8c05-6d4f2a1b9e37
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
    shared lab-auth-token and store it in the host vault (idempotent).
.DESCRIPTION
    The Yuruna hosts dashboard (Grafana on the caching-proxy service) shows a "Lab
    token" tile with a 6-character code that rotates about once a minute.
    This script redeems that code at the pool-aggregator service's
    POST /api/v1/lab-token, receives the shared lab-auth-token, and stores it
    in this host's vault -- enabling the status-service control routes (the
    Grafana deep-link control proofs) and cross-host config-sync. The secret
    itself never has to be read off the proxy or typed by the operator.

    The reply is sealed under the code that was typed, so only this host can
    open it: a host being enrolled cannot yet verify the aggregator's TLS
    leaf (the proxy's own CA signs it), and the seal is what keeps anything
    else on the network from answering the exchange and planting a token.

    The caching-proxy service is found from this host's configuration (the persisted
    caching-proxy-service state, $env:YURUNA_CACHING_PROXY_SERVICE_IP, or
    vmStart.cachingProxyIp in test.config.yml). Each is probed on the
    aggregator port and the first that answers is used, so an address left
    behind by a proxy that has since moved is passed over instead of
    swallowing the enrollment; when none answers, the probing continues for
    up to two minutes before giving up, so a momentary outage does not cost
    the operator a code. When no address answers at all, pass -CachingProxyService
    or answer the prompt. That address is written to
    vmStart.cachingProxyIp when test.config.yml exists, binding the host to
    this lab's proxy for later runs; on a machine with no config file yet it
    serves this enrollment only, and Sync-HostConfiguration.ps1 brings over
    the config that binds it.

    Safe to re-run at any time: a lost or rotated token, a rebuilt proxy, or
    a doubtful host state is fixed by reading the current code off the
    dashboard and running this again.
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
    pwsh test/Set-LabToken.ps1 -LabToken k3v9qa -BounceStatusService
.EXAMPLE
    pwsh test/Set-LabToken.ps1 -LabToken k3v9qa -CachingProxyService 192.168.7.229
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)][string]$LabToken,
    [Parameter()][string]$CachingProxyService,
    [switch]$BounceStatusService,
    [switch]$NonInteractive,
    # Skip seeding pool.enabled / pool.intentGitUrl into test.config.yml.
    # Enrolment is the natural moment to do it -- the operator is present and has
    # just named the proxy -- but a host that must stay standalone can opt out.
    [switch]$NoPoolConfig
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# Honor the caller's logLevel, published as $env:YURUNA_LOG_LEVEL by whatever
# entry point started this script (install/setup.ps1, a runner cycle). After the
# line above on purpose: an explicit level is the operator's choice and replaces
# this script's own default. $InformationPreference is then re-read from the
# global the cascade writes, because the script-scoped assignment above shadows
# it for the rest of this file. See docs/loglevels.md.
Import-Module (Join-Path $PSScriptRoot 'modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv
$InformationPreference = $global:InformationPreference

$elapsed = [System.Diagnostics.Stopwatch]::StartNew()

$code = $LabToken.Trim().ToLowerInvariant()
if ($code -notmatch '^[a-z0-9]{6}$') {
    Write-Error "'$LabToken' is not a Lab token: expected the 6-character code (lowercase letters/digits) from the Yuruna hosts dashboard's 'Lab token' tile."
    exit 1
}

# The authentication extension supplies Set-Password / Set-UserVaultKey /
# Test-VaultEntry; Test.ConfigServiceSync supplies the exchange client and the
# Set-LabAuthToken orchestrator; Test.CachingProxyService resolves the aggregator
# address. -Global -Force mirrors Import-Extension so a nested import does
# not evict the module from the global scope.
Write-Information 'Importing the authentication extension and the config-sync module ...' -InformationAction Continue
Import-Module (Join-Path $PSScriptRoot 'extension/authentication/default.psm1') -Global -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules/Test.ConfigServiceSync.psm1') -Global -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'modules/Test.CachingProxyService.psm1') -Global -Force -DisableNameChecking

# --- REGION: Resolve the aggregator base URL
# An explicit -CachingProxyService wins; else the host's own configuration (the
# probe-and-discard resolution Get-PoolAggregatorServiceSeedUrl owns, which believes
# a stored address only once it answers); else ask. $addressSource records
# where the address came from so only an operator-supplied one is persisted
# below.
#
# The wait budget is what separates this caller from a seed render: an
# operator is holding a code that stays redeemable for about three minutes,
# so riding out a momentary outage costs a wait they would spend anyway,
# while resolving '' costs them the enrollment and a trip back to the
# dashboard for a fresh code.
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
        Write-Error 'No caching-proxy service this host names answered on :9400 (and prompting is disabled); pass -CachingProxyService <address>.'
        exit 1
    }
    $proxyAddress = (Read-Host 'Caching-proxy service address (the machine whose dashboard shows the Lab token)').Trim()
    if (-not $proxyAddress) {
        Write-Error 'No caching-proxy-service address given; cannot reach the lab.'
        exit 1
    }
    $addressSource = 'prompt'
}
if ($proxyAddress -and $proxyAddress -match "['\s]") {
    Write-Error "Caching-proxy address '$proxyAddress' contains a quote or whitespace; give a bare IP or host name."
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
    Write-Information "What if: would redeem Lab token '$code' at $($candidates[0])/api/v1/lab-token and store the returned lab-auth-token in this host's vault." -InformationAction Continue
    exit 0
}

# --- REGION: Redeem the code for the shared token
$verdict = $null
foreach ($base in $candidates) {
    Write-Information "Redeeming the Lab token at $base/api/v1/lab-token ..." -InformationAction Continue
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
Write-Information 'Lab token accepted; storing the shared lab-auth-token in this host''s vault.' -InformationAction Continue

# --- REGION: Store + verify (the vault provisioning Set-LabAuthToken owns)
$persistArgs = @{ Token = $verdict.Token; BounceStatusService = [bool]$BounceStatusService }
if ($PSBoundParameters.ContainsKey('Confirm')) { $persistArgs['Confirm'] = $PSBoundParameters['Confirm'] }
$provision = Set-LabAuthToken @persistArgs

# --- REGION: Bind this host to the lab proxy
# Persist an operator-supplied address into vmStart.cachingProxyIp -- the key
# every aggregator-address consumer resolves last -- so the enrollment is the
# one-time step and later runs (and the runner itself) find the proxy on
# their own. A config-sourced address is already persistent; nothing to do.
if ($provision.ok -and $proxyAddress -and ($addressSource -in @('parameter', 'prompt'))) {
    $configPath = Join-Path $PSScriptRoot 'test.config.yml'
    try {
        Import-Module powershell-yaml -ErrorAction Stop
        Import-Module (Join-Path $PSScriptRoot 'modules/Test.StateFile.psm1')  -Global -Force -DisableNameChecking
        Import-Module (Join-Path $PSScriptRoot 'modules/Test.ConfigSync.psm1') -Force -DisableNameChecking
        if (Test-Path -LiteralPath $configPath) {
            $cfg = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Yaml -Ordered
            if ($null -eq $cfg) { $cfg = [ordered]@{} }
            if (-not ($cfg['vmStart'] -is [System.Collections.IDictionary])) { $cfg['vmStart'] = [ordered]@{} }
            $current = "$($cfg['vmStart']['cachingProxyIp'])".Trim()
            if ($current -eq $proxyAddress) {
                Write-Information "vmStart.cachingProxyIp already names $proxyAddress; binding unchanged." -InformationAction Continue
            } else {
                $cfg['vmStart']['cachingProxyIp'] = $proxyAddress
                $yaml = (ConvertTo-SortedConfig $cfg) | ConvertTo-Yaml
                $null = Write-YurunaStateFile -Path $configPath -Content $yaml -Confirm:$false
                Write-Information "Bound this host to the lab proxy: vmStart.cachingProxyIp = $proxyAddress." -InformationAction Continue
            }
        } else {
            Write-Warning "test.config.yml not found; the proxy address was not persisted. Run Sync-HostConfiguration.ps1 (or create the config) and re-run with -CachingProxyService $proxyAddress to bind."
        }
    } catch {
        Write-Warning "Could not persist vmStart.cachingProxyIp ($($_.Exception.Message)); the token is stored, but later runs must pass -CachingProxyService again."
    }
}

# --- REGION: Seed the pool intent store binding
# A host that has just enrolled its lab token is a host the operator intends to
# manage from the lab. The intent store it should pull from is served by the very
# proxy they just named, so bind it now: enrolment is the one moment an operator
# is present, authenticated, and has already supplied the address.
#
# Runs for EVERY resolved address, not only an operator-supplied one -- a host
# whose cachingProxyIp was already in config still needs the pool binding, and
# that is the common case on a re-enrolment.
#
# Idempotent and non-destructive: an existing non-empty intentGitUrl is left
# exactly as it is, so an operator pointing a host at a different intent store is
# never overwritten. Best-effort throughout -- the token is already stored, and
# failing to seed an optional binding must not fail the enrolment.
if ($provision.ok -and $proxyAddress -and -not $NoPoolConfig) {
    $configPath = Join-Path $PSScriptRoot 'test.config.yml'
    try {
        Import-Module powershell-yaml -ErrorAction Stop
        Import-Module (Join-Path $PSScriptRoot 'modules/Test.StateFile.psm1')  -Global -Force -DisableNameChecking
        Import-Module (Join-Path $PSScriptRoot 'modules/Test.ConfigSync.psm1') -Force -DisableNameChecking
        if (-not (Test-Path -LiteralPath $configPath)) {
            Write-Warning "test.config.yml not found; pool.intentGitUrl was not seeded. Re-run after Sync-HostConfiguration.ps1 to join the lab pool."
        } else {
            $cfg = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Yaml -Ordered
            if ($null -eq $cfg) { $cfg = [ordered]@{} }
            if (-not ($cfg['pool'] -is [System.Collections.IDictionary])) { $cfg['pool'] = [ordered]@{} }
            $existingUrl = "$($cfg['pool']['intentGitUrl'])".Trim()
            # The READ-ONLY http url. The writable path (a file:// or local
            # path to the bare repo) is for admin commands run ON the proxy;
            # a runner must never hold a writable remote.
            $intentUrl = "http://$proxyAddress/pool-intent.git"
            # An existing value is normally the operator's and is never touched.
            # The exception is a value THIS block wrote on an earlier run: the
            # proxy is addressed by a DHCP lease, so its address moves, and a
            # url pinned to the address it held last time points at nothing --
            # or worse, at whatever guest now holds that lease. That is not an
            # operator decision to preserve, and left alone it never self-heals:
            # every later run sees a non-empty value and skips. Recognize only
            # the exact shape this block emits (scheme, host, repo name), so
            # anything the operator actually chose still wins.
            $isOwnStaleSeed = $existingUrl -and
                              ($existingUrl -ne $intentUrl) -and
                              ($existingUrl -match '^http://[^/]+/pool-intent\.git$')
            if ($existingUrl -and -not $isOwnStaleSeed) {
                Write-Information "pool.intentGitUrl already set ($existingUrl); leaving it unchanged." -InformationAction Continue
            } else {
                if ($isOwnStaleSeed) {
                    Write-Information "pool.intentGitUrl pointed at a previous caching-proxy address ($existingUrl); re-pointing it at $intentUrl." -InformationAction Continue
                }
                $cfg['pool']['intentGitUrl'] = $intentUrl
                # enabled goes WITH the url: intentGitUrl alone is inert, so
                # seeding one without the other would look configured and do
                # nothing.
                $cfg['pool']['enabled'] = $true
                $yaml = (ConvertTo-SortedConfig $cfg) | ConvertTo-Yaml
                $null = Write-YurunaStateFile -Path $configPath -Content $yaml -Confirm:$false
                Write-Information "Joined the lab pool: pool.enabled = true, pool.intentGitUrl = $intentUrl. This host now pulls pool intent read-only each cycle." -InformationAction Continue
            }
        }
    } catch {
        Write-Warning "Could not seed pool.intentGitUrl ($($_.Exception.Message)); the token is stored. Set pool.enabled/pool.intentGitUrl by hand to join the pool."
    }
}

$took = "{0:N1}s" -f $elapsed.Elapsed.TotalSeconds
if ($provision.ok) {
    $msg = "Done in ${took}: lab-auth-token stored and verified (vaultKey '$($provision.vaultKey)')."
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

Write-Error "lab-auth-token provisioning did not verify after ${took} (keyChanged=$($provision.keyChanged), verified=$($provision.verified)). The token is not usable for control proofs on this host."
exit 1
