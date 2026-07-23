<#PSScriptInfo
.VERSION 2026.07.22
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
# block consumes via ${ext:stash-service.ResolveHost(<vm>)}, so the stash IP is
# a discovered artifact instead of a hard-coded literal -- the same live
# Get-VMIp lookup the caching-proxy/edge discovery uses.

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
        Resolves the current IPv4 address of the stash-service VM, for a
        sequence's `variables:` block to consume via
        ${ext:stash-service.ResolveHost(<vm>)}.
    .DESCRIPTION
        Live host-contract lookup (Get-VMIp) -- the same mechanism the
        caching-proxy and edge VMs are discovered by -- so the stash
        address is a runtime-discovered artifact, never a hard-coded
        literal. On a host whose driver has no Get-VMIp, or when the VM
        has no IPv4 yet, returns '' and warns: the consuming guest script
        keeps a degraded-mode default (STASH_HOST="${STASH_HOST:-...}"),
        so an empty expansion falls back rather than failing the step.
    .PARAMETER VMName
        Stash VM name. Defaults to 'yuruna-stash-service' (the name
        Start-StashServer.ps1 creates).
    .OUTPUTS
        [string] IPv4 address, or '' when it cannot be resolved.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$VMName = 'yuruna-stash-service')
    if (-not (Get-Command Get-VMIp -ErrorAction SilentlyContinue)) {
        Write-Warning "stash-service.ResolveHost: host contract has no Get-VMIp; cannot discover '$VMName'."
        return ''
    }
    $ip = ''
    try { $ip = [string](Get-VMIp -VMName $VMName) } catch {
        Write-Warning "stash-service.ResolveHost: Get-VMIp '$VMName' failed: $($_.Exception.Message)"
        return ''
    }
    if (-not $ip) {
        Write-Warning "stash-service.ResolveHost: no IPv4 for '$VMName' yet (is it running?)."
    }
    return $ip
}

Export-ModuleMember -Function Get-StashServiceInfo, Resolve-Host
