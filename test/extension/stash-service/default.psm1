<#PSScriptInfo
.VERSION 2026.07.24
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456820
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

# Default stash-service extension. The Go daemon (SCP sink-mode wire-protocol
# handler, SQLite metadata index, storage layout per https://yuruna.link/stash-service sec 6)
# lives under [server/](server/). Get-StashServiceInfo is a status stub that
# returns a uniform hashtable in the host-side cmdlet vocabulary; host-side
# status probing (querying a running stash VM) is not wired yet, so the flags
# stay $false until that lands.
#
# Resolve-Host is the runtime stash-address discovery a sequence's `variables:`
# block consumes via ${ext:stash-service.ResolveHost(<vm>)}, so the stash
# address is a discovered artifact instead of a hard-coded literal. It resolves
# through the POOL first (Test.PoolDiscovery -> the aggregator's advertised
# extension target, the same value the Grafana pool dashboard links to) and
# falls back to the local Get-VMIp lookup.
#
# Test.PoolDiscovery is imported here rather than relied on from an entry point's
# module set: this extension is loaded by the inner runner AND by a standalone
# Test-Sequence.ps1 guest build (which is where the stash lookup actually runs),
# and those bootstrap different module lists. Best-effort -- a framework too old
# to carry the module must still load the extension and use the local fallback.
$script:PoolDiscoveryModule = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'modules', 'Test.PoolDiscovery.psm1'
if (Test-Path -LiteralPath $script:PoolDiscoveryModule) {
    Import-Module $script:PoolDiscoveryModule -Global -Force -DisableNameChecking -ErrorAction SilentlyContinue
}

function Get-StashServiceInfo {
    <#
    .SYNOPSIS
        Returns the stash-service extension's current status as a
        uniform hashtable, matching the host-side cmdlet vocabulary
        shape used elsewhere in the extension areas.
    .OUTPUTS
        @{ supported = $false; installed = $false; running = $false;
           message = '...'; daemonVersion = $null }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        supported     = $false
        installed     = $false
        running       = $false
        message       = 'stash-service: daemon source under server/; host-side status probing not wired yet. See https://yuruna.link/stash-service.'
        daemonVersion = $null
    }
}

function Resolve-Host {
    <#
    .SYNOPSIS
        Resolves the address of the stash service that is ACTIVE right now, for
        a sequence's `variables:` block to consume via
        ${ext:stash-service.ResolveHost(<vm>)}.
    .DESCRIPTION
        Two sources, in this order:

          1. THE POOL (official path). Get-PoolExtensionTarget asks the pool
             aggregator which host is advertising an active 'stash-service' and
             returns the address it advertised -- the exact value behind the
             Grafana pool dashboard's "Extension hosts" table, whose Extension
             column links to that hidden `target` field. Host-agnostic: it
             answers whether the stash VM runs here, on another pool host, or
             on a host whose status server is currently down (the service's own
             announce backs the registration record).

          2. THE LOCAL HYPERVISOR (fallback). The original Get-VMIp lookup by VM
             name, which is all a single-host operator running no aggregator
             has. This used to be the ONLY source, which is why a perfectly
             healthy stash service running elsewhere in the pool reported "no
             IPv4 ... (is it running?)" -- the local hypervisor had simply never
             heard of it.

        Returns '' when neither answers, and warns once with both reasons: the
        consuming guest script keeps a degraded-mode default
        (STASH_HOST="${STASH_HOST:-...}"), so an empty expansion falls back
        rather than failing the step.

        A bare host is returned, not a URL -- consumers put it in an scp target
        (amisad-poc@<host>:/...) and build their own URLs from it.
    .PARAMETER VMName
        Stash VM name for the LOCAL fallback only. Defaults to
        'yuruna-stash-service' (the name Start-StashVM.ps1 creates). The pool
        path needs no VM name: it resolves by extension area.
    .OUTPUTS
        [string] host/IPv4 address, or '' when it cannot be resolved.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$VMName = 'yuruna-stash-service')

    # 1) Pool discovery -- the official, host-agnostic path.
    if (Get-Command Get-PoolExtensionTarget -ErrorAction SilentlyContinue) {
        $fromPool = ''
        try { $fromPool = [string](Get-PoolExtensionTarget -Area 'stash-service' -AsHost) } catch {
            Write-Verbose "stash-service.ResolveHost: pool discovery failed ($($_.Exception.Message)); trying the local hypervisor."
        }
        if (-not [string]::IsNullOrWhiteSpace($fromPool)) {
            Write-Verbose "stash-service.ResolveHost: pool reports the active stash service at '$fromPool'."
            return $fromPool
        }
    } else {
        Write-Verbose 'stash-service.ResolveHost: Test.PoolDiscovery not loaded; local lookup only.'
    }

    # 2) Local hypervisor fallback -- correct only when the stash VM runs here.
    if (-not (Get-Command Get-VMIp -ErrorAction SilentlyContinue)) {
        Write-Warning "stash-service.ResolveHost: the pool reports no active stash service, and this host contract has no Get-VMIp to look up '$VMName' locally."
        return ''
    }
    $ip = ''
    try { $ip = [string](Get-VMIp -VMName $VMName) } catch {
        Write-Warning "stash-service.ResolveHost: the pool reports no active stash service, and the local Get-VMIp '$VMName' failed: $($_.Exception.Message)"
        return ''
    }
    if (-not $ip) {
        Write-Warning "stash-service.ResolveHost: no stash service found -- the pool aggregator advertises none, and '$VMName' has no IPv4 on this host (is it running here?)."
    }
    return $ip
}

Export-ModuleMember -Function Get-StashServiceInfo, Resolve-Host
