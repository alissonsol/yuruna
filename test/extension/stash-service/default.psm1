<#PSScriptInfo
.VERSION 2026.06.05
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

# Default stash-service extension. v1 ships a placeholder Get-StashServiceInfo
# that returns a uniform hashtable so future automation (daemon install +
# launch -- see https://yuruna.link/stash-service §4.6) can be swapped in
# without changing caller sites.
#
# The Go daemon source (SCP wire-protocol handler, SQLite metadata store,
# storage layout per §6) will land under [server/](server/) when the
# implementation moves past the cloud-init-only stage. Today the folder
# carries only a README explaining the layout to come.

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
        message       = 'stash-service daemon: not yet implemented. See https://yuruna.link/stash-service.'
        daemonVersion = $null
    }
}

Export-ModuleMember -Function Get-StashServiceInfo
