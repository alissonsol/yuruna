<#PSScriptInfo
.VERSION 2026.07.10
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
# handler, SQLite metadata index, storage layout per https://yuruna.link/stash-service §6)
# lives under [server/](server/). Get-StashServiceInfo is a status stub that
# returns a uniform hashtable in the host-side cmdlet vocabulary; host-side
# status probing (querying a running stash VM) is not wired yet, so the flags
# stay $false until that lands.

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

Export-ModuleMember -Function Get-StashServiceInfo
