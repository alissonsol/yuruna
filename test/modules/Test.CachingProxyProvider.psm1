<#PSScriptInfo
.VERSION 2026.05.29
.GUID 426ae2d1-f52e-4da6-8218-5613c30a54e6
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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

# Caching-proxy health + recovery registry. #
# Today Test-CachingProxyAvailable in each Yuruna.Host driver checks
# whether the local squid VM is reachable. The legacy code path warns
# and continues on miss -- a downed proxy turns the cycle into a slow,
# 60-min-of-timeout run because every Get-Image / dnf install reaches
# for the cache first.
#
# This registry's recovery primitive Restart-CachingProxyVM stops the
# squid VM, removes its volatile disk, re-clones from the base image,
# starts it, and waits for the port to accept TCP. Invoked from a
# health-check that observes proxy-unreachable for N consecutive
# steps. Test-CachingProxyTlsBumpingEnabled gates the cycle on the
# squid TLS-bump configuration being present -- without it, HTTPS
# downloads bypass the cache and the test surface for "is the cache
# actually doing its job?" silently degrades to TCP-only.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Cross-module-eviction-safe anchor.')]
param()

if (-not $global:YurunaCachingProxyProviders) {
    $global:YurunaCachingProxyProviders = [ordered]@{}
}
$script:Providers = $global:YurunaCachingProxyProviders

function Register-CachingProxyProvider {
    <#
    .SYNOPSIS
        Register a caching-proxy provider for $HostType.
    .DESCRIPTION
        Stores the HealthCheck and optional Restart scriptblocks in the
        cross-module-eviction-safe global registry so
        Test-CachingProxyAvailableViaRegistry and Restart-CachingProxyVM
        can dispatch by HostType.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter',
        '', Justification = 'Parameters land in the registry, not used by the function body.')]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][scriptblock]$HealthCheck,
        [scriptblock]$Restart
    )
    $script:Providers[$HostType] = @{ HealthCheck = $HealthCheck; Restart = $Restart }
}

function Test-CachingProxyAvailableViaRegistry {
    <#
    .SYNOPSIS
        Run the registered health-check for $HostType. Returns
        @{ available; errorMessage } so the caller can pass the message
        through to the cycle log.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$HostType)
    if (-not $script:Providers.Contains($HostType)) {
        return @{ available = $false; errorMessage = "no caching-proxy provider registered for '$HostType'" }
    }
    try { return [hashtable](& $script:Providers[$HostType].HealthCheck) }
    catch { return @{ available = $false; errorMessage = $_.Exception.Message } }
}

function Restart-CachingProxyVM {
    <#
    .SYNOPSIS
        Self-healing primitive: run the registered Restart scriptblock
        for $HostType. Used by a future recovery coordinator when N
        consecutive cycles fail proxy probes.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$HostType)
    if (-not $script:Providers.Contains($HostType)) {
        Write-Warning "Restart-CachingProxyVM: no provider registered for '$HostType'."
        return $false
    }
    $restart = $script:Providers[$HostType].Restart
    if (-not $restart) {
        Write-Warning "Restart-CachingProxyVM: provider for '$HostType' has no Restart scriptblock."
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($HostType, 'Restart caching-proxy VM')) { return $true }
    try { return [bool](& $restart) }
    catch { Write-Warning "Restart-CachingProxyVM threw: $($_.Exception.Message)"; return $false }
}

function Test-CachingProxyTlsBumpingEnabled {
    <#
    .SYNOPSIS
        TLS-bumping compliance guard. Reads the local squid configuration file
        (when accessible) and returns $true if `ssl_bump` or
        `http_port ... ssl-bump` directives are active.
    .DESCRIPTION
        Default-conservative: $false on file-not-found, parse error,
        or any access failure -- the harness should only WARN when
        bumping is positively detected, never fail-closed on a missing
        file (the operator may legitimately have no proxy installed).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$SquidConfPath)
    if (-not $SquidConfPath) {
        # Default to the location the caching-proxy VM cloud-init writes to.
        # When called from the host (not inside the VM), the file is not
        # accessible -- we return $false so the gate logs an informational
        # "could not verify" rather than blocking the cycle.
        $SquidConfPath = if ($IsLinux) { '/etc/squid/squid.conf' } else { $null }
    }
    if (-not $SquidConfPath -or -not (Test-Path -LiteralPath $SquidConfPath)) { return $false }
    try {
        $text = Get-Content -Raw -LiteralPath $SquidConfPath -ErrorAction Stop
        # Match `ssl_bump` directives that are NOT commented out. Also
        # match `http_port ... ssl-bump` (the shorthand that enables
        # bumping on a listener directly).
        return [bool]($text -match '(?m)^\s*ssl_bump\s+\S+' -or `
                      $text -match '(?m)^\s*http_port\s+[^\r\n]*ssl-bump')
    } catch {
        Write-Verbose "Test-CachingProxyTlsBumpingEnabled: $($_.Exception.Message)"
        return $false
    }
}

function Clear-CachingProxyProvider {
    <#
    .SYNOPSIS
        Drop every registered caching-proxy provider.
    .DESCRIPTION
        Tests-only: production code relies on -Force re-import to
        refresh registrations. Resets both the script-local and global
        anchor so the registry is observably empty.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('Test.CachingProxyProvider registry', 'Clear all providers')) {
        $script:Providers = [ordered]@{}
        $global:YurunaCachingProxyProviders = $script:Providers
    }
}

Export-ModuleMember -Function Register-CachingProxyProvider, Test-CachingProxyAvailableViaRegistry, Restart-CachingProxyVM, Test-CachingProxyTlsBumpingEnabled, Clear-CachingProxyProvider
